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
  /// @param assets 已加载的数据资产
  /// @param runner 推理桥实现
  /// @param config 流式配置
  QuranRecognizer({
    required this.assets,
    required this.runner,
    this.config = const QuranStreamingConfig(),
  })  : decoder = TextCtcDecoder(assets.vocab, blankId: assets.blankId),
        matcher = QuranMatcher(assets);

  /// 数据资产。
  final QuranAssets assets;

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
  QuranStreamingSession createSession() => QuranStreamingSession(this);
}

/// 流式识别会话：持续喂入音频分块，异步产出识别事件。
class QuranStreamingSession {
  QuranStreamingSession(this._recognizer);

  final QuranRecognizer _recognizer;

  final StreamController<QuranRecognitionEvent> _controller =
      StreamController<QuranRecognitionEvent>.broadcast();

  Float32List _accumulated = Float32List(0);
  double _secondsSinceTrigger = 0;
  double _silenceSeconds = 0;
  bool _running = true;
  bool _busy = false;
  String? _lastStableRef;
  int _stableCount = 0;

  /// 会话内「最安静的窗口本底」（各窗口中位数的最小值），用于自适应语音门控。
  ///
  /// 只降不升：一旦出现过安静段就以它作为环境本底，避免被一段朗读抬高门槛。
  /// 不随 [reset] 清零（这是环境属性，而非单次诵读的状态）。
  double _quietBaseline = 0;

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

    final merged = Float32List(_accumulated.length + chunk.length)
      ..setAll(0, _accumulated)
      ..setAll(_accumulated.length, chunk);
    _accumulated = merged;

    final chunkSeconds = chunk.length / QuranRecognizer.sampleRate;
    _secondsSinceTrigger += chunkSeconds;
    _silenceSeconds = _rms(chunk) < _recognizer.config.silenceRmsThreshold ? _silenceSeconds + chunkSeconds : 0;

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
    _committedRefs.clear();
    _lastCommittedRef = null;
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

      final evidence = await _recognizer.runner.run(audio);
      final decoded = _recognizer.decoder.decode(evidence.logprobs, evidence.timeSteps, evidence.vocabSize);
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
      if (champion != null) {
        final (spanWords, groups) = QuranWordProgress.alignedWords(
          _recognizer.assets,
          champion.surah,
          champion.ayahStart,
          champion.ayahEnd,
        );
        spanWordCount = spanWords.length;
        readWords = QuranWordProgress.estimateReadWords(evidence, groups);
        // 提词器前瞻：附带下一节，保证界面始终存在「未读」区域可供对比
        final nextVerse = _recognizer.assets.verse(champion.surah, champion.ayahEnd + 1);
        words = nextVerse == null ? spanWords : [...spanWords, ...nextVerse.words];
      }

      // 已确认进度：稳定命中且读满阈值时提交一次（同一节不重复提交，序列单调推进）
      var justCommitted = false;
      if (stable &&
          champion != null &&
          spanWordCount > 0 &&
          readWords / spanWordCount >= config.commitWordRatio &&
          _lastCommittedRef != champion.ref) {
        _lastCommittedRef = champion.ref;
        _committedRefs.add(champion.ref);
        justCommitted = true;
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

    // 会话级本底：只降不升，作为「这个环境最安静能有多安静」的估计
    _quietBaseline = _quietBaseline == 0 ? median : math.min(_quietBaseline, median);

    // 三层判据（与绝对电平解耦，适应远场 / 低音量收音）：
    // 1. 音频内信噪比：峰值 ≥ 最近 2 s 本底 × snrRatio；
    // 2. 会话级本底倍数：峰值 ≥ 会话最安静本底 × quietFloorRatio；
    // 3. 极低电平兜底：排除纯数值噪声。
    final config = _recognizer.config;
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
