/// 语料灌音：把一段音频按实时节奏喂入流式会话（**不经麦克风**）。
///
/// 用途是把「引擎 + 算法」与「抓音质量」解耦：真机实测中麦克风外放收音的
/// RMS 常常接近底噪、被 VAD 挡掉，导致比对结果反映的是收音而不是算法；
/// 灌音路径直接把已知原文的音频交给同一套流式链路（含 VAD、匹配、进度、
/// 窗口推进），跑完即可与原文逐词比对。
///
/// 节奏：每 [chunkMs] 毫秒喂一块，与实时采集一致；若单次推理耗时超过
/// 触发间隔，会话自身的 `_busy` 保护会跳过该轮（真实链路同样如此）。
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
  const CorpusRunProgress({
    required this.fedSeconds,
    required this.totalSeconds,
    this.event,
  });

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
    required this.expectedRef,
    required this.transcriptWords,
    required this.seenRefs,
    required this.stableRefs,
    required this.committedRefs,
    required this.eventCount,
    required this.elapsed,
    required this.advancedSeconds,
  });

  /// 期望章节（自定义语料为 null，此时无法自动判定命中）。
  final String? expectedRef;

  /// 拼接后的转写词序列。
  final List<String> transcriptWords;

  /// 识别到的章节序列（相邻去重）。
  final List<String> seenRefs;

  /// 稳定命中的章节序列（相邻去重）。
  final List<String> stableRefs;

  /// 已确认章节序列（末次事件）。
  final List<String> committedRefs;

  /// 产生识别事件的窗口数。
  final int eventCount;

  /// 灌音耗时（含推理）。
  final Duration elapsed;

  /// 本轮窗口前移总时长（秒）。
  final double advancedSeconds;

  /// 是否识别到期望章节（自定义语料为 null）。
  bool? get hit => expectedRef == null ? null : seenRefs.contains(expectedRef);

  /// 期望章节是否曾**稳定**命中（自定义语料为 null）。
  bool? get stableHit => expectedRef == null ? null : stableRefs.contains(expectedRef);

  /// 转写全文。
  String get transcriptText => transcriptWords.join(' ');
}

/// 语料灌音器。
class CorpusRunner {
  /// 构造灌音器。
  ///
  /// @param recognizer 已加载模型与资产的识别器（沿用其流式配置）
  /// @param samples 语料采样（16 kHz 单声道 float32）
  /// @param expectedRef 期望章节（`surah:ayah`；自定义语料传 null 表示无法自动判定）
  /// @param chunkMs 每块时长（毫秒），默认 20 ms（与实时采集一致）
  CorpusRunner({
    required this.recognizer,
    required this.samples,
    this.expectedRef,
    this.chunkMs = 20,
  });

  /// 识别器。
  final QuranRecognizer recognizer;

  /// 语料采样。
  final Float32List samples;

  /// 期望章节（null 表示自定义语料，不做命中判定）。
  final String? expectedRef;

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
    final stitcher = TranscriptStitcher();
    final seenRefs = <String>[];
    final stableRefs = <String>[];
    var committedRefs = const <String>[];
    var eventCount = 0;
    var advancedSeconds = 0.0;
    var fedSeconds = 0.0;
    final totalSeconds = samples.length / QuranRecognizer.sampleRate;
    final stopwatch = Stopwatch()..start();

    final subscription = session.events.listen((event) {
      eventCount++;
      advancedSeconds += event.advancedSeconds;
      committedRefs = event.committedSequence;
      stitcher.add(event.decodedText);
      final ref = event.match.champion?.ref;
      if (ref != null && (seenRefs.isEmpty || seenRefs.last != ref)) {
        seenRefs.add(ref);
      }
      if (ref != null && event.stable && (stableRefs.isEmpty || stableRefs.last != ref)) {
        stableRefs.add(ref);
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
        onProgress?.call(
          CorpusRunProgress(fedSeconds: fedSeconds, totalSeconds: totalSeconds),
        );
        if (_cancelled) break;
        await Future<void>.delayed(Duration(milliseconds: chunkMs));
      }
      if (!_cancelled) {
        // 收尾识别：与实时「静音结束」等价的一次最终 flush
        await session.finish();
      }
    } finally {
      // 流订阅的收尾（cancel / dispose）只是释放资源，不影响已收集到的结果：
      // 不等它们完成就返回，否则调用方会被资源回收的时序拖住。
      unawaited(subscription.cancel());
      unawaited(session.dispose());
      stopwatch.stop();
    }

    return CorpusRunResult(
      expectedRef: expectedRef,
      transcriptWords: stitcher.words,
      seenRefs: seenRefs,
      stableRefs: stableRefs,
      committedRefs: committedRefs,
      eventCount: eventCount,
      elapsed: stopwatch.elapsed,
      advancedSeconds: advancedSeconds,
    );
  }
}
