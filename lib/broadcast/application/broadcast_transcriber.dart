/// 片段级实际 ASR：在**不查询任何参考文本**的前提下转写一段音频，并保留
/// 每段的声学证据，供后续经文匹配复用同一次推理。
///
/// 与旧功能的 [OfflineTranscriber] 的分工：
///
/// - 旧功能面向「整段语料准确度校核」，只需要最终转写与时间；
/// - 广播功能面向「一句一记录」，除了转写还必须保留 `AcousticEvidence`，
///   否则匹配阶段会重复执行完全相同的模型推理。
///
/// 两者共用同一套分段与拼接实现（[OfflineTranscriber.audioSegmentBounds] 与
/// [TimedTranscript]），不复制算法。
library;

import 'dart:typed_data';

import '../../quran_offline/ctc_decoder.dart';
import '../../quran_offline/ctc_scorer.dart';
import '../../quran_offline/offline_transcriber.dart';
import '../../quran_offline/ort_runner.dart';
import '../../quran_offline/timed_transcript.dart';

/// 一段有界推理的结果（含声学证据）。
class BroadcastSegment {
  /// 构造分段结果。
  ///
  /// @param startSample 片段起始采样（会话绝对位置）
  /// @param endSample 片段结束采样（会话绝对位置）
  /// @param evidence 本次前向推理的完整 log 概率
  /// @param decoded 本次贪心解码结果
  /// @param forcedBoundary 是否因超长被强制切分（而非停在自然停顿处）
  const BroadcastSegment({
    required this.startSample,
    required this.endSample,
    required this.evidence,
    required this.decoded,
    required this.forcedBoundary,
  });

  /// 起始采样。
  final int startSample;

  /// 结束采样。
  final int endSample;

  /// 声学证据。
  final AcousticEvidence evidence;

  /// 解码结果。
  final TextCtcResult decoded;

  /// 是否因达到最大片段长度被强制切分。
  final bool forcedBoundary;

  /// 片段时长（秒）。
  double seconds(int sampleRate) => (endSample - startSample) / sampleRate;
}

/// 一个语音片段的转写结果。
class BroadcastFragment {
  /// 构造片段结果。
  ///
  /// @param words 按音频时间合并后的实际 ASR 词
  /// @param timedWords 带绝对时间的词
  /// @param segments 逐段推理结果（含声学证据）
  /// @param sampleRate 采样率
  const BroadcastFragment({
    required this.words,
    required this.timedWords,
    required this.segments,
    required this.sampleRate,
  });

  /// 实际 ASR 词。
  final List<String> words;

  /// 带绝对时间的词。
  final List<TimedWord> timedWords;

  /// 逐段推理结果。
  final List<BroadcastSegment> segments;

  /// 采样率。
  final int sampleRate;

  /// 转写文本（空格拼接）。
  String get text => words.join(' ');

  /// 是否没有任何内容（整段静音或全部 blank）。
  bool get isEmpty => words.isEmpty || segments.isEmpty;

  /// 片段结束采样。
  int get endSample => segments.isEmpty ? 0 : segments.last.endSample;
}

/// 广播片段转写器。
class BroadcastTranscriber {
  /// 构造转写器。
  ///
  /// @param runner 推理桥
  /// @param decoder CTC 解码器
  /// @param vocab 词表
  /// @param sampleRate 采样率
  /// @param windowSeconds 无停顿时的最大窗口（秒）
  /// @param overlapSeconds 窗口重叠（秒）
  /// @param lookaheadSeconds 尾词延迟提交量（秒）
  BroadcastTranscriber({
    required this.runner,
    required this.decoder,
    required this.vocab,
    this.sampleRate = 16000,
    this.windowSeconds = 30,
    this.overlapSeconds = 8,
    this.lookaheadSeconds = 8,
  }) : _segmenter = OfflineTranscriber(
         runner: runner,
         decoder: decoder,
         vocab: vocab,
         sampleRate: sampleRate,
         windowSeconds: windowSeconds,
         overlapSeconds: overlapSeconds,
         lookaheadSeconds: lookaheadSeconds,
       );

  /// 推理桥。
  final OrtRunner runner;

  /// 解码器。
  final TextCtcDecoder decoder;

  /// 词表。
  final Map<int, String> vocab;

  /// 采样率。
  final int sampleRate;

  /// 最大窗口。
  final double windowSeconds;

  /// 重叠。
  final double overlapSeconds;

  /// 尾词延迟提交量。
  final double lookaheadSeconds;

  final OfflineTranscriber _segmenter;

  /// 转写一段音频（不查询参考文本）。
  ///
  /// @param samples 16 kHz 单声道 PCM
  /// @param offsetSample 该段在会话中的绝对起始采样（用于记录真实时间）
  /// @param isCancelled 取消判定
  /// @param onProgress 进度回调（0..1）
  /// @return 片段转写结果
  Future<BroadcastFragment> transcribe(
    Float32List samples, {
    int offsetSample = 0,
    bool Function()? isCancelled,
    void Function(double fraction)? onProgress,
  }) async {
    if (samples.isEmpty) {
      return BroadcastFragment(
        words: const <String>[],
        timedWords: const <TimedWord>[],
        segments: const <BroadcastSegment>[],
        sampleRate: sampleRate,
      );
    }
    final bounds = _segmenter.audioSegmentBounds(samples);
    final transcript = TimedTranscript();
    final segments = <BroadcastSegment>[];
    for (var index = 0; index < bounds.length; index++) {
      if (isCancelled?.call() ?? false) break;
      final bound = bounds[index];
      final evidence = await runner.run(Float32List.sublistView(samples, bound.$1, bound.$2));
      final decoded = decoder.decode(evidence.logprobs, evidence.timeSteps, evidence.vocabSize);
      final isFinal = index == bounds.length - 1 || bounds[index + 1].$1 >= bound.$2;
      transcript.update(
        decoded: decoded,
        vocab: vocab,
        frames: evidence.timeSteps,
        windowStart: (offsetSample + bound.$1) / sampleRate,
        windowEnd: (offsetSample + bound.$2) / sampleRate,
        isFinal: isFinal,
        lookaheadSeconds: lookaheadSeconds,
      );
      segments.add(
        BroadcastSegment(
          startSample: offsetSample + bound.$1,
          endSample: offsetSample + bound.$2,
          evidence: evidence,
          decoded: decoded,
          forcedBoundary: bound.$2 - bound.$1 >= (windowSeconds * sampleRate).round() - 1,
        ),
      );
      onProgress?.call(bound.$2 / samples.length);
    }
    return BroadcastFragment(
      words: List<String>.unmodifiable(transcript.words),
      timedWords: List<TimedWord>.unmodifiable(transcript.timedWords),
      segments: List<BroadcastSegment>.unmodifiable(segments),
      sampleRate: sampleRate,
    );
  }
}
