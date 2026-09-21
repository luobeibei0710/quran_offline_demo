/// 古兰经离线识别器：封装「音频 → 经文章节」的完整流程，并提供流式识别会话。
///
/// 流程：16 kHz float32 音频 → ONNX 推理（原生）→ 贪心 CTC 解码 →
/// 文本召回 → CTC 约束精排 → 章节结果。
///
/// 流式策略（工程化简版，便于在移动端稳定运行）：
/// - 累积音频缓冲，按触发间隔对「最近窗口」重复识别；
/// - 连续若干轮识别到同一节才提交稳定结果，避免逐帧抖动；
/// - 同时输出候选列表、词进度与原始文本，供 UI 展示。
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'ctc_decoder.dart';
import 'ort_runner.dart';
import 'quran_assets.dart';
import 'quran_matcher.dart';
import 'quran_word_progress.dart';
import 'timed_transcript.dart';

/// 一次识别的输出事件。
class QuranRecognitionEvent {
  /// 构造事件。
  const QuranRecognitionEvent({
    required this.match,
    required this.decodedText,
    required this.stable,
    required this.isFinal,
    required this.audioSeconds,
    this.words = const <String>[],
    this.readWords = 0,
    this.committedSequence = const <String>[],
    this.justCommitted = false,
    this.advancedSeconds = 0,
    this.transcriptWords = const <String>[],
  });

  /// 匹配结果（含冠军与候选）。
  final VerseMatchResult match;

  /// 本轮识别文本。
  final String decodedText;

  /// 是否已连续多轮稳定命中同一节。
  final bool stable;

  /// 是否为收尾（静音超时或手动结束）时的事件。
  final bool isFinal;

  /// 本轮参与识别的音频时长（秒）。
  final double audioSeconds;

  /// 当前冠军（可能为 null）。
  VerseMatchCandidate? get champion => match.champion;

  /// 提词器用：当前候选跨度的经文词列表。
  final List<String> words;

  /// 提词器用：已读词数（0..[words].length）。
  final int readWords;

  /// 已确认的章节序列（稳定命中且读满阈值后提交，按提交顺序）。
  ///
  /// 流式会话每轮都对窗口重新识别，界面若只跟「本轮冠军」会在同一节内来回跳；
  /// 该序列给出单调推进的「已确认读到哪几节」，供界面展示与日志核对。
  final List<String> committedSequence;

  /// 本次事件是否刚刚提交了新的一节。
  final bool justCommitted;

  /// 本次事件因提交而裁掉的窗口时长（秒，0 表示未推进）。
  ///
  /// 便于观察「识别随进度前移」：窗口不再一直堆到 15 s，而是裁掉已读部分。
  final double advancedSeconds;

  /// 按音频时间合并的实际 ASR 词；不查经文、不使用期望章节。
  final List<String> transcriptWords;

  /// 最近一次确认的章节；尚未提交过时返回 null。
  String? get committedRef => committedSequence.isEmpty ? null : committedSequence.last;
}

/// 流式识别配置。
class QuranStreamingConfig {
  /// 构造配置。
  const QuranStreamingConfig({
    this.triggerSeconds = 0.75,
    this.maxWindowSeconds = 15.0,
    this.minWindowSeconds = 1.2,
    this.stableRounds = 2,
    this.silenceRmsThreshold = 0.012,
    this.finalSilenceSeconds = 1.5,
    this.speechRmsThreshold = 0.004,
    this.speechSnrRatio = 2.5,
    this.speechQuietFloorRatio = 2.0,
    this.commitWordRatio = 0.6,
    this.advanceWindowOnCommit = true,
    this.windowOverlapSeconds = 1.0,
    this.assumeSpeech = false,
    this.topK = QuranMatcher.defaultTopK,
    this.maxSpan = QuranMatcher.defaultMaxSpan,
    this.spanPenalty = QuranMatcher.defaultSpanPenalty,
  });

  /// 每累积多少秒音频触发一次识别。
  final double triggerSeconds;

  /// 单次识别窗口上限（秒），避免窗外内容干扰。
  final double maxWindowSeconds;

  /// 触发识别所需的最短音频长度（秒）。
  final double minWindowSeconds;

  /// 连续多少轮命中同一节才标记为稳定。
  final int stableRounds;

  /// 静音判定阈值（RMS）。
  ///
  /// 环境底噪（空调、风扇等）通常在 0.01 以上，阈值过低会导致静音永远
  /// 判定不出来，从而持续对噪声做识别。
  final double silenceRmsThreshold;

  /// 极低电平兜底（RMS）：峰值低于该值一定不判为语音。
  ///
  /// 只用于排除「纯数值噪声」，不承担环境底噪判别（那是 [speechSnrRatio] 与
  /// [speechQuietFloorRatio] 的职责）。原取 0.03 的固定下限会把远场 / 低音量收音
  /// 整段挡掉 —— 实测「Mac 外放 + 手机收音」时 RMS 仅 0.003~0.026，导致多数窗口
  /// 被跳过、比对指标失真，故下调为 0.004。
  final double speechRmsThreshold;

  /// 语音信噪比判据：窗内 20 ms 帧能量的 90 分位需高于中位数的该倍数。
  ///
  /// 语音有明显音节起伏（峰值远高于本底），稳态噪声则峰值接近本底。
  /// 用比值而非固定阈值，才能适应不同环境的底噪差异。
  final double speechSnrRatio;

  /// 会话级本底判据：峰值还需 ≥ 会话内「最安静的窗口本底」× 该系数。
  ///
  /// 与 [speechSnrRatio]（最近 2 s 内部比较）互补：本项是会话级比较，
  /// 保证「此刻明显比这个环境最安静的时候响」，从而与绝对电平解耦。
  final double speechQuietFloorRatio;

  /// 提交「已确认章节」所需的已读词比例。
  ///
  /// 稳定命中且已读词达到该比例时把该节计入 [QuranRecognitionEvent.committedSequence]，
  /// 使长诵读的进度单调推进（不再随窗口重识别来回跳）。
  final double commitWordRatio;

  /// 已知输入必为朗读时，跳过多层能量判据（只保留极低电平兜底）。
  ///
  /// 语料灌音用：官方/自定义语料是**连续朗读**，帧能量均匀（实测峰值/中位数仅
  /// 1.3~2.0），达不到 [speechSnrRatio] 要求的 2.5 倍，会被整段挡掉而识别不出任何内容。
  /// 实时采集路径保持 `false`（那里的判据是用来挡空调声/风扇声的）。
  final bool assumeSpeech;

  /// 提交已确认章节后，是否把窗口前部已读的音频裁掉（让识别随进度前移）。
  ///
  /// 打开后窗口不会一直保留 15 s 历史音频：识别始终围绕「当前读到哪」进行，
  /// 既减少已读内容对跨度/进度的干扰，也让长诵读的窗口长度保持稳定。
  /// 裁剪量按帧级对齐的已读结束位置计算，并保留 [windowOverlapSeconds] 重叠。
  final bool advanceWindowOnCommit;

  /// 窗口推进时保留的重叠时长（秒）。
  ///
  /// 避免把音频切在词中间：重叠区内仍包含上一个已读词的完整发音。
  final double windowOverlapSeconds;

  /// 静音多久后判定一次诵读结束。
  final double finalSilenceSeconds;

  /// 参与 CTC 精排的候选数。
  final int topK;

  /// 最大连读跨度（节）。
  final int maxSpan;

  /// 连读跨度惩罚系数（详见 [QuranMatcher.defaultSpanPenalty]）。
  final double spanPenalty;
}

/// 一次性识别 + 流式识别的统一入口。
class QuranRecognizer {
  /// 构造识别器。
  ///
  /// @param assets 已加载的数据资产（提供词表与 blank id）
  /// @param runner 推理桥实现
  /// @param config 流式配置
  /// @param index 匹配所用的经文索引；省略时使用 [assets] 指向的旧经文库。
  ///   广播功能传入独立新库索引，匹配与上下文都不会查询旧库。
  QuranRecognizer({
    required this.assets,
    required this.runner,
    this.config = const QuranStreamingConfig(),
    VerseIndex? index,
  }) : index = index ?? assets,
       decoder = TextCtcDecoder(assets.vocab, blankId: assets.blankId),
       matcher = QuranMatcher(index ?? assets);

  /// 数据资产（词表、blank id 与旧经文库）。
  final QuranAssets assets;

  /// 本条链路实际检索的经文索引。
  ///
  /// 旧功能等于 [assets]；广播功能等于独立三章新库。匹配与上下文查询一律
  /// 走本字段，保证不会出现「新库展示、旧库检索」或未匹配时的隐式回退。
  final VerseIndex index;

  /// 推理桥。
  final OrtRunner runner;

  /// 流式配置。
  final QuranStreamingConfig config;

  /// CTC 解码器。
  final TextCtcDecoder decoder;

  /// 经文匹配器。
  final QuranMatcher matcher;

  /// 采样率。
  static const int sampleRate = 16000;

  /// 对一段完整音频做一次性识别。
  ///
  /// @param samples 16 kHz 单声道 float32 音频
  /// @return 匹配结果
  Future<VerseMatchResult> recognizeOnce(Float32List samples) async {
    final evidence = await runner.run(samples);
    final decoded = decoder.decode(evidence.logprobs, evidence.timeSteps, evidence.vocabSize);
    return matcher.match(
      evidence,
      decoded.text,
      topK: config.topK,
      maxSpan: config.maxSpan,
      spanPenalty: config.spanPenalty,
    );
  }

  /// 创建一个流式识别会话。
  /// 新建流式会话。
  ///
  /// @param assumeSpeech 按「已知是朗读」处理（语料灌音用，见
  ///   [QuranStreamingConfig.assumeSpeech]）
  /// @return 新的会话实例
  QuranStreamingSession createSession({bool assumeSpeech = false}) =>
      QuranStreamingSession(this, assumeSpeech: assumeSpeech);
}

/// 流式识别会话：持续喂入音频分块，异步产出识别事件。
class QuranStreamingSession {
  /// 构造会话。
  ///
  /// @param recognizer 识别器
  /// @param assumeSpeech 强制按「已知是朗读」处理（覆盖配置里的同名开关）
  QuranStreamingSession(this._recognizer, {bool assumeSpeech = false})
    : _assumeSpeech = assumeSpeech || _recognizer.config.assumeSpeech;

  final QuranRecognizer _recognizer;

  /// 是否跳过多层能量判据（见 [QuranStreamingConfig.assumeSpeech]）。
  final bool _assumeSpeech;

  final StreamController<QuranRecognitionEvent> _controller =
      StreamController<QuranRecognitionEvent>.broadcast();

  Float32List _accumulated = Float32List(0);
  double _secondsSinceTrigger = 0;
  double _silenceSeconds = 0;
  bool _running = true;
  bool _busy = false;
  String? _lastStableRef;
  int _stableCount = 0;
  int _totalSamples = 0;
  final TimedTranscript _transcript = TimedTranscript();

  /// 会话内「最安静的窗口本底」，用于自适应语音门控。
  ///
  /// 更新规则：向下立即跟随（取较小者），向上每轮最多回升 [_quietBaselineRise] ——
  /// 既跟随环境噪声缓慢上升，又不会被一段朗读把门槛立刻抬高。
  /// 不随 [reset] 清零（这是环境属性，而非单次诵读的状态）。
  double _quietBaseline = 0;

  /// 本底每轮最多回升比例（2%，约对应一分钟量级的跟随时间常数）。
  static const double _quietBaselineRise = 1.02;

  /// 已确认章节序列（稳定命中且读满阈值后提交，同一节只提交一次）。
  final List<String> _committedRefs = <String>[];
  String? _lastCommittedRef;

  /// 会话内估计的安静本底（RMS），可用于界面提示收音强度。
  double get quietBaseline => _quietBaseline;

  /// 已确认章节序列（只读视图）。
  List<String> get committedSequence => List<String>.unmodifiable(_committedRefs);

  /// 识别事件流。
  Stream<QuranRecognitionEvent> get events => _controller.stream;

  /// 已累积的音频时长（秒）。
  double get accumulatedSeconds => _accumulated.length / QuranRecognizer.sampleRate;

  /// 最近一次稳定命中的引用（`surah:ayah`）。
  String? get lastStableRef => _lastStableRef;

  /// 喂入一段音频（16 kHz 单声道 float32）。
  ///
  /// @param chunk 音频分块
  Future<void> feed(Float32List chunk) async {
    if (!_running || chunk.isEmpty) return;
    _totalSamples += chunk.length;

    final merged = Float32List(_accumulated.length + chunk.length)
      ..setAll(0, _accumulated)
      ..setAll(_accumulated.length, chunk);
    _accumulated = merged;

    final chunkSeconds = chunk.length / QuranRecognizer.sampleRate;
    _secondsSinceTrigger += chunkSeconds;
    _silenceSeconds = _rms(chunk) < _recognizer.config.silenceRmsThreshold
        ? _silenceSeconds + chunkSeconds
        : 0;

    if (_silenceSeconds >= _recognizer.config.finalSilenceSeconds) {
      await _flush(finalEvent: true);
      return;
    }
    if (_secondsSinceTrigger >= _recognizer.config.triggerSeconds) {
      // 语音门控：最近没有足够语音就跳过本轮，避免对噪声产生臆测结果
      if (_hasSpeech(_accumulated)) {
        await _flush(finalEvent: false);
      } else {
        _secondsSinceTrigger = 0;
      }
    }
  }

  /// 结束会话并发起一次收尾识别。
  Future<void> finish() async {
    if (!_running) return;
    await _flush(finalEvent: true);
    _running = false;
    await _controller.close();
  }

  /// 重置会话状态（开始新一次诵读）：清空音频缓冲、稳定计数与已确认序列。
  void reset() {
    _resetBuffers();
    _totalSamples = 0;
    _transcript.clear();
    _committedRefs.clear();
    _lastCommittedRef = null;
  }

  /// 判断 `nextRef` 是否是 `previousRef` 的**合法延续**。
  ///
  /// 给窗口推进设闸用：只有「同一节」或「往后 1~3 节（同章）」「下一章开头几节」
  /// 才认为匹配可信到可以裁剪窗口；匹配跳到别处（很可能是片段误匹配）时不推进，
  /// 免得把真正没念到的音频裁掉。
  ///
  /// @param previousRef 上一节已确认引用（`surah:ayah` 或 `surah:ayahStart-ayahEnd`）
  /// @param nextRef 本次冠军引用
  /// @return 是否算延续（任一侧无法解析时按延续处理，保持宽松）
  static bool isContinuation(String? previousRef, String? nextRef) {
    if (previousRef == null || nextRef == null) return true;
    final previous = _parseRef(previousRef, last: true);
    final next = _parseRef(nextRef, last: false);
    if (previous == null || next == null) return true;
    final (previousSurah, previousAyah) = previous;
    final (nextSurah, nextAyah) = next;
    if (nextSurah == previousSurah) {
      return nextAyah >= previousAyah && nextAyah <= previousAyah + 3;
    }
    return nextSurah == previousSurah + 1 && nextAyah <= 3;
  }

  /// 解析引用：`surah:ayah` 或 `surah:start-end`。
  ///
  /// @param ref 引用文本
  /// @param last true 取区间末节，false 取区间首节
  /// @return `(章号, 节号)`；解析失败时为 null
  static (int, int)? _parseRef(String ref, {required bool last}) {
    final parts = ref.split(':');
    if (parts.length != 2) return null;
    final surah = int.tryParse(parts[0]);
    final range = parts[1].split('-');
    final ayah = int.tryParse(last ? range.last : range.first);
    if (surah == null || ayah == null) return null;
    return (surah, ayah);
  }

  /// 清空音频缓冲与稳定计数。
  ///
  /// 收尾识别后由会话内部调用：一次诵读结束但**不清空已确认序列与本底估计**，
  /// 这样「一节一节念、中间停顿」时进度仍能跨段累加。
  void _resetBuffers() {
    _accumulated = Float32List(0);
    _secondsSinceTrigger = 0;
    _silenceSeconds = 0;
    _lastStableRef = null;
    _stableCount = 0;
  }

  /// 按已读进度裁掉窗口前部（保留 [QuranStreamingConfig.windowOverlapSeconds] 重叠）。
  ///
  /// 帧 → 采样点的换算用「本次窗口采样点数 ÷ 证据帧数」，自动跟随模型帧率，
  /// 不写死 hop 长度；窗口是累积音频的尾部切片时按窗口起点换算，避免错位。
  ///
  /// @param endFrame 已读内容在证据中的最后一帧（-1 表示不可用，不裁剪）
  /// @param frames 证据总帧数
  /// @param windowSamples 本次识别窗口的采样点数
  /// @return 实际裁掉的时长（秒）；未裁剪时为 0
  double _advanceWindow({required int endFrame, required int frames, required int windowSamples}) {
    if (endFrame < 0 || frames <= 0 || windowSamples <= 0) return 0;
    final samplesPerFrame = windowSamples / frames;
    final keep =
        (endFrame + 1) * samplesPerFrame -
        _recognizer.config.windowOverlapSeconds * QuranRecognizer.sampleRate;
    if (keep <= 0) return 0;
    // 单次最多裁掉 60%：即使已读位置判定有偏差，也不至于把窗口内容裁光
    final bounded = math.min(keep, windowSamples * 0.6);
    final trimAt = _accumulated.length - windowSamples + bounded.round();
    if (trimAt <= 0 || trimAt >= _accumulated.length) return 0;
    _accumulated = _accumulated.sublist(trimAt);
    return trimAt / QuranRecognizer.sampleRate;
  }

  Future<void> _flush({required bool finalEvent}) async {
    if (_busy) return;
    final config = _recognizer.config;
    if (_accumulated.length / QuranRecognizer.sampleRate < config.minWindowSeconds) {
      if (!finalEvent) return;
      if (_accumulated.isEmpty) return;
    }
    _busy = true;
    _secondsSinceTrigger = 0;
    try {
      // 静音收尾且窗口内无语音时不上报，避免把噪声匹配结果当成识别结果
      if (finalEvent && !_hasSpeech(_accumulated)) {
        return;
      }
      final windowSamples = (config.maxWindowSeconds * QuranRecognizer.sampleRate).round();
      final audio = _accumulated.length > windowSamples
          ? Float32List.sublistView(_accumulated, _accumulated.length - windowSamples)
          : _accumulated;

      final audioEndSample = _totalSamples;
      final evidence = await _recognizer.runner.run(audio);
      final decoded = _recognizer.decoder.decode(
        evidence.logprobs,
        evidence.timeSteps,
        evidence.vocabSize,
      );
      _transcript.update(
        decoded: decoded,
        vocab: _recognizer.assets.vocab,
        frames: evidence.timeSteps,
        windowStart: (audioEndSample - audio.length) / QuranRecognizer.sampleRate,
        windowEnd: audioEndSample / QuranRecognizer.sampleRate,
        isFinal: finalEvent,
      );
      final match = _recognizer.matcher.match(
        evidence,
        decoded.text,
        topK: config.topK,
        maxSpan: config.maxSpan,
        spanPenalty: config.spanPenalty,
      );

      final champion = match.champion;
      var stable = false;
      if (champion != null) {
        if (_lastStableRef == champion.ref) {
          _stableCount++;
        } else {
          _lastStableRef = champion.ref;
          _stableCount = 1;
        }
        stable = _stableCount >= config.stableRounds;
      }

      // 提词器跟随：对齐出「已读到第几个词」（前缀可达性，见 QuranWordProgress）
      var words = const <String>[];
      var readWords = 0;
      var spanWordCount = 0;
      QuranReadProgress? readProgress;
      if (champion != null) {
        final (spanWords, groups) = QuranWordProgress.alignedWords(
          _recognizer.index,
          champion.surah,
          champion.ayahStart,
          champion.ayahEnd,
        );
        spanWordCount = spanWords.length;
        readProgress = QuranWordProgress.estimateReadProgress(evidence, groups);
        readWords = readProgress.readWords;
        // 提词器前瞻：附带下一节，保证界面始终存在「未读」区域可供对比
        final nextVerse = _recognizer.index.verse(champion.surah, champion.ayahEnd + 1);
        words = nextVerse == null ? spanWords : [...spanWords, ...nextVerse.words];
      }

      // 已确认进度：稳定命中且读满阈值时提交一次（同一节不重复提交，序列单调推进）
      var justCommitted = false;
      final previousCommittedRef = _lastCommittedRef;
      if (stable &&
          champion != null &&
          spanWordCount > 0 &&
          readWords / spanWordCount >= config.commitWordRatio &&
          _lastCommittedRef != champion.ref) {
        _lastCommittedRef = champion.ref;
        _committedRefs.add(champion.ref);
        justCommitted = true;
      }

      // 窗口推进：提交后裁掉已读部分的音频，让下一轮识别围绕当前位置进行。
      //
      // 只有冠军是「已确认序列的延续」时才推进：匹配错了还裁剪窗口，会把真正没念到的
      // 音频一起裁掉，后面越错越多（实测 159 s 语料被前移掉 155 s）。
      var advancedSeconds = 0.0;
      if (justCommitted &&
          champion != null &&
          config.advanceWindowOnCommit &&
          readProgress != null &&
          isContinuation(previousCommittedRef, champion.ref)) {
        advancedSeconds = _advanceWindow(
          endFrame: readProgress.endFrame,
          frames: evidence.timeSteps,
          windowSamples: audio.length,
        );
      }

      _controller.add(
        QuranRecognitionEvent(
          match: match,
          decodedText: decoded.text,
          stable: stable,
          isFinal: finalEvent,
          audioSeconds: audio.length / QuranRecognizer.sampleRate,
          words: words,
          readWords: readWords,
          committedSequence: List<String>.unmodifiable(_committedRefs),
          justCommitted: justCommitted,
          advancedSeconds: advancedSeconds,
          transcriptWords: List<String>.unmodifiable(_transcript.words),
        ),
      );
    } catch (error, stackTrace) {
      _controller.addError(error, stackTrace);
    } finally {
      _busy = false;
      if (finalEvent) {
        _resetBuffers();
      }
    }
  }

  /// 简单能量 VAD：判断最近一段音频里是否存在语音。
  ///
  /// 不用固定能量阈值 —— 不同环境底噪差异极大（实测本机底噪 RMS 0.012~0.035，
  /// 与轻声朗读的量级重叠）。改用「峰值 / 本底」信噪比判据：语音有明显音节
  /// 起伏，峰值显著高于本底；稳态噪声（空调、风扇）的峰值与前段接近。
  /// 同时要求峰值达到绝对下限，避免极安静环境被细微起伏触发。
  ///
  /// 只看最近 2 秒，符合「此刻是否在说话」的语义，计算量也是小常数级。
  ///
  /// @param samples 累积音频
  /// @return 判定存在语音时返回 true
  bool _hasSpeech(Float32List samples) {
    final config = _recognizer.config;
    if (_assumeSpeech) {
      // 已知是朗读（语料灌音）：只保留极低电平兜底，避免纯静音窗口产出臆测结果
      return _rms(samples) >= config.speechRmsThreshold;
    }
    const speechWindowSeconds = 2.0;
    final frameLength = (0.02 * QuranRecognizer.sampleRate).round();
    final windowSamples = (speechWindowSeconds * QuranRecognizer.sampleRate).round();
    final start = samples.length > windowSamples ? samples.length - windowSamples : 0;
    if (frameLength <= 0 || samples.length - start < frameLength * 8) return false;

    final frames = <double>[];
    for (var i = start; i + frameLength <= samples.length; i += frameLength) {
      var sum = 0.0;
      for (var j = i; j < i + frameLength; j++) {
        sum += samples[j] * samples[j];
      }
      frames.add(math.sqrt(sum / frameLength));
    }
    if (frames.length < 8) return false;

    frames.sort();
    final median = frames[frames.length ~/ 2];
    final peak = frames[((frames.length - 1) * 0.9).round()];

    // 会话级本底：向下立即跟随，向上每轮最多回升 2%
    //（跟随环境噪声缓慢上升，又不会被一段朗读把门槛立刻抬高）
    final risen = _quietBaseline == 0 ? median : _quietBaseline * _quietBaselineRise;
    _quietBaseline = math.min(median, risen);

    // 三层判据（与绝对电平解耦，适应远场 / 低音量收音）：
    // 1. 音频内信噪比：峰值 ≥ 最近 2 s 本底 × snrRatio；
    // 2. 会话级本底倍数：峰值 ≥ 会话最安静本底 × quietFloorRatio；
    // 3. 极低电平兜底：排除纯数值噪声。
    final required = math.max(
      math.max(median * config.speechSnrRatio, _quietBaseline * config.speechQuietFloorRatio),
      config.speechRmsThreshold,
    );
    return peak >= required;
  }

  /// 计算分块 RMS，用于静音检测。
  double _rms(Float32List samples) {
    if (samples.isEmpty) return 0.0;
    var sum = 0.0;
    final step = math.max(1, samples.length ~/ 512);
    var count = 0;
    for (var i = 0; i < samples.length; i += step) {
      sum += samples[i] * samples[i];
      count++;
    }
    return count == 0 ? 0.0 : math.sqrt(sum / count);
  }

  /// 释放会话资源。
  Future<void> dispose() async {
    _running = false;
    if (!_controller.isClosed) {
      await _controller.close();
    }
  }
}
