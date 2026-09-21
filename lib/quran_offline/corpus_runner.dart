/// 语料灌音：把一段音频按实时节奏喂入流式会话（**不经麦克风**）。
///
/// 用途是把「引擎 + 算法」与「抓音质量」解耦：真机实测中麦克风外放收音的
/// RMS 常常接近底噪、被 VAD 挡掉，导致比对结果反映的是收音而不是算法；
/// 灌音路径直接把已知原文的音频交给同一套流式链路（含匹配、进度、窗口推进）。
///
/// 三个关键处理：
/// 1. **按「已知是朗读」建会话**：语料是连续朗读，帧能量均匀（实测峰值/中位数
///    1.3~2.0），达不到 VAD 信噪比判据的 2.5 倍，否则整段会被挡掉、一个字都识别不出；
/// 2. **转写稿取「稳定命中章节的标准经文」**：流式窗口会反复覆盖同一段音频
///    （159 s 语料被切成上百轮），逐词 ASR 输出的重叠去重必然失效、累积重复内容
///    （实测 47 词的语料拼出 150+ 词），无法作为长音频的转写。转写稿改为按识别顺序
///    拼接稳定命中章节的标准经文（同节全局去重）：漏节体现为缺失词、错节体现为错配词；
/// 3. **逐词 ASR 原始输出仍保留**（[CorpusRunResult.rawTranscriptWords]）作为诊断参考，
///    段内取最长解码以削弱「没念完的半截词」影响。
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'quran_recognizer.dart';
import 'transcript_stitcher.dart';

/// 灌音进度回调载荷。
class CorpusRunProgress {
  /// 构造进度。
  ///
  /// @param fedSeconds 已喂入时长（秒）
  /// @param totalSeconds 语料总时长（秒）
  /// @param event 本次喂入触发的最新识别事件（未触发时为 null）
  const CorpusRunProgress({required this.fedSeconds, required this.totalSeconds, this.event});

  /// 已喂入时长（秒）。
  final double fedSeconds;

  /// 语料总时长（秒）。
  final double totalSeconds;

  /// 最新识别事件。
  final QuranRecognitionEvent? event;

  /// 进度（0..1）。
  double get fraction => totalSeconds <= 0 ? 1 : (fedSeconds / totalSeconds).clamp(0, 1);
}

/// 一次灌音的结果。
class CorpusRunResult {
  /// 构造结果。
  const CorpusRunResult({
    required this.expectedRefs,
    required this.transcriptRefs,
    required this.transcriptWords,
    required this.rawTranscriptWords,
    required this.seenRefs,
    required this.stableRefs,
    required this.committedRefs,
    required this.eventCount,
    required this.elapsed,
    required this.advancedSeconds,
    this.isOffline = false,
  });

  /// 期望章节（语料原文对应区间内的节，有序；自定义原文时为空）。
  final List<String> expectedRefs;

  /// 转写稿来源章节：稳定命中且全局去重（识别顺序）。
  final List<String> transcriptRefs;

  /// 离线模式为实际 ASR；流式诊断为 [transcriptRefs] 对应的标准经文重建。
  final List<String> transcriptWords;

  /// 逐词 ASR 原始输出（重叠去重后），仅作诊断参考。
  final List<String> rawTranscriptWords;

  /// 识别到的章节序列（相邻去重，含未稳定命中的）。
  final List<String> seenRefs;

  /// 稳定命中的章节序列（相邻去重）。
  final List<String> stableRefs;

  /// 已确认章节序列（末次事件）。
  final List<String> committedRefs;

  /// 流式事件数；[isOffline] 时为离线推理分段数。
  final int eventCount;

  /// 灌音耗时（含推理）。
  final Duration elapsed;

  /// 本轮窗口前移总时长（秒）。
  final double advancedSeconds;

  /// 离线校核使用实际 ASR 转写，不产生流式章节轨迹。
  final bool isOffline;

  /// 期望区间内被识别到的节。
  List<String> get matchedRefs => <String>[
    for (final ref in expectedRefs)
      if (seenRefs.contains(ref)) ref,
  ];

  /// 期望区间内曾稳定命中的节。
  List<String> get stableMatchedRefs => <String>[
    for (final ref in expectedRefs)
      if (stableRefs.contains(ref)) ref,
  ];

  /// 区间内的节是否**全部**识别到（自定义原文时为 null）。
  bool? get hit => expectedRefs.isEmpty ? null : matchedRefs.length == expectedRefs.length;

  /// 区间内的节是否全部曾稳定命中（自定义原文时为 null）。
  bool? get stableHit =>
      expectedRefs.isEmpty ? null : stableMatchedRefs.length == expectedRefs.length;

  /// 转写全文。
  String get transcriptText => transcriptWords.join(' ');

  /// 逐词 ASR 原始输出的全文（诊断）。
  String get rawTranscriptText => rawTranscriptWords.join(' ');
}

/// 语料灌音器。
class CorpusRunner {
  /// 构造灌音器。
  ///
  /// @param recognizer 已加载模型与资产的识别器（沿用其流式配置）
  /// @param samples 语料采样（16 kHz 单声道 float32）
  /// @param expectedRefs 期望章节（区间内有序；自定义原文传空表示不做命中判定）
  /// @param chunkMs 每块时长（毫秒），默认 20 ms（与实时采集一致）
  CorpusRunner({
    required this.recognizer,
    required this.samples,
    this.expectedRefs = const <String>[],
    this.chunkMs = 20,
  });

  /// 识别器。
  final QuranRecognizer recognizer;

  /// 语料采样。
  final Float32List samples;

  /// 期望章节。
  final List<String> expectedRefs;

  /// 每块时长（毫秒）。
  final int chunkMs;

  bool _cancelled = false;

  /// 取消灌音（用于页面退出）。
  void cancel() => _cancelled = true;

  /// 执行一次灌音：喂完全部音频后收尾识别并汇总结果。
  ///
  /// @param onProgress 进度回调（可选）
  /// @return 灌音结果
  Future<CorpusRunResult> run({void Function(CorpusRunProgress progress)? onProgress}) async {
    // 语料是连续朗读：按「已知是朗读」建会话，否则能量门控会把整段挡掉
    final session = recognizer.createSession(assumeSpeech: true);
    final rawStitcher = TranscriptStitcher();
    final seenRefs = <String>[];
    final stableRefs = <String>[];
    final transcriptRefs = <String>[];
    final coveredAyahs = <String>{};
    var committedRefs = const <String>[];
    var eventCount = 0;
    var advancedSeconds = 0.0;
    var fedSeconds = 0.0;
    var pendingSegment = '';
    var pendingWords = 0;
    final totalSeconds = samples.length / QuranRecognizer.sampleRate;
    final fullWindowSeconds = recognizer.config.maxWindowSeconds;
    final stopwatch = Stopwatch()..start();

    final subscription = session.events.listen((event) {
      eventCount++;
      advancedSeconds += event.advancedSeconds;
      committedRefs = event.committedSequence;
      final ref = event.match.champion?.ref;
      if (ref != null && (seenRefs.isEmpty || seenRefs.last != ref)) {
        seenRefs.add(ref);
      }
      if (ref != null && event.stable) {
        if (stableRefs.isEmpty || stableRefs.last != ref) {
          stableRefs.add(ref);
        }
        // 转写稿按「新覆盖到的节」累加：同一节只记一次，跨度引用（如 36:1-2）
        // 与单节引用（36:1、36:2）重叠时也不会重复计入
        for (final ayahRef in _ayahRefsOf(ref)) {
          if (coveredAyahs.add(ayahRef)) transcriptRefs.add(ayahRef);
        }
      }

      // 诊断用的逐词输出：只采纳稳定窗口，段内取最长解码，
      // 窗口被前移（提交后裁剪）或已到滑窗上限时结算一段
      if (event.stable) {
        final words = _wordCount(event.decodedText);
        if (words >= pendingWords) {
          pendingSegment = event.decodedText;
          pendingWords = words;
        }
      }
      final windowFull = event.audioSeconds >= fullWindowSeconds - 0.05;
      if ((event.advancedSeconds > 0 || windowFull) && pendingSegment.isNotEmpty) {
        rawStitcher.add(pendingSegment);
        pendingSegment = '';
        pendingWords = 0;
      }

      onProgress?.call(
        CorpusRunProgress(fedSeconds: fedSeconds, totalSeconds: totalSeconds, event: event),
      );
    });

    try {
      final chunk = math.max(1, (QuranRecognizer.sampleRate * chunkMs / 1000).round());
      for (var offset = 0; offset < samples.length && !_cancelled; offset += chunk) {
        final end = math.min(offset + chunk, samples.length);
        await session.feed(Float32List.sublistView(samples, offset, end));
        fedSeconds = end / QuranRecognizer.sampleRate;
        onProgress?.call(CorpusRunProgress(fedSeconds: fedSeconds, totalSeconds: totalSeconds));
        if (_cancelled) break;
        await Future<void>.delayed(Duration(milliseconds: chunkMs));
      }
      if (!_cancelled) {
        // 收尾识别：与实时「静音结束」等价的一次最终 flush
        await session.finish();
        if (pendingSegment.isNotEmpty) rawStitcher.add(pendingSegment);
      }
    } finally {
      // 流订阅的收尾（cancel / dispose）只是释放资源，不影响已收集到的结果：
      // 不等它们完成就返回，否则调用方会被资源回收的时序拖住。
      unawaited(subscription.cancel());
      unawaited(session.dispose());
      stopwatch.stop();
    }

    return CorpusRunResult(
      expectedRefs: expectedRefs,
      transcriptRefs: transcriptRefs,
      transcriptWords: <String>[for (final ref in transcriptRefs) ..._wordsOfRef(ref)],
      rawTranscriptWords: rawStitcher.words,
      seenRefs: seenRefs,
      stableRefs: stableRefs,
      committedRefs: committedRefs,
      eventCount: eventCount,
      elapsed: stopwatch.elapsed,
      advancedSeconds: advancedSeconds,
    );
  }

  /// 展开引用覆盖的节（`surah:ayah` 或 `surah:start-end`）。
  ///
  /// @param ref 章节引用
  /// @return 逐节引用列表；不可解析时为空
  static List<String> _ayahRefsOf(String ref) {
    final parts = ref.split(':');
    if (parts.length != 2) return const <String>[];
    final surah = int.tryParse(parts[0]);
    if (surah == null) return const <String>[];
    final range = parts[1].split('-');
    final start = int.tryParse(range.first);
    final end = int.tryParse(range.last);
    if (start == null || end == null) return const <String>[];
    return <String>[for (var ayah = start; ayah <= end; ayah++) '$surah:$ayah'];
  }

  /// 取某引用对应的标准经文词序列（支持 `surah:ayah` 与 `surah:start-end`）。
  ///
  /// @param ref 章节引用
  /// @return 词序列；引用不可解析或经文缺失时为空
  List<String> _wordsOfRef(String ref) {
    final parts = ref.split(':');
    if (parts.length != 2) return const <String>[];
    final surah = int.tryParse(parts[0]);
    if (surah == null) return const <String>[];
    final range = parts[1].split('-');
    final start = int.tryParse(range.first);
    final end = int.tryParse(range.last);
    if (start == null || end == null) return const <String>[];
    final words = <String>[];
    for (var ayah = start; ayah <= end; ayah++) {
      final verse = recognizer.assets.verse(surah, ayah);
      if (verse != null) words.addAll(verse.words);
    }
    return words;
  }

  /// 统计文本词数（以空白切分）。
  static int _wordCount(String text) =>
      text.trim().isEmpty ? 0 : text.trim().split(RegExp(r'\s+')).length;
}
