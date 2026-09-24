/// CTC 约束打分：用前向后向对数似然给候选经文序列打分。
///
/// 这是「固定文本约束」路线的核心 —— 因为待识别内容是 6236 节固定经文，
/// 可以把候选的 token 序列直接送入 CTC 的前向后向算法，得到严格的声学似然，
/// 比单纯文本相似度可靠得多（实测冠军与次优的差距可达 1.0 以上）。
///
/// 与 Tilawa 的 `ctc-rescore.ts` 等价。
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// 声学证据：一次前向推理得到的完整 log 概率。
class AcousticEvidence {
  /// 构造声学证据。
  ///
  /// @param logprobs 行主序 `[timeSteps, vocabSize]`
  /// @param timeSteps 帧数
  /// @param vocabSize 词表大小
  /// @param blankId blank token 的 id
  const AcousticEvidence({
    required this.logprobs,
    required this.timeSteps,
    required this.vocabSize,
    required this.blankId,
  });

  /// 行主序 log 概率。
  final Float32List logprobs;

  /// 帧数。
  final int timeSteps;

  /// 词表大小。
  final int vocabSize;

  /// blank token id。
  final int blankId;
}

/// CTC 打分的归一化口径。
///
/// 两种口径的差异只在**尺度**（同一候选按帧 = 按 token × token 数 / 帧数），
/// 因此「最优位置」不会变，但**容差带**的尺度会变：
///
/// - [perFrame]：除以帧数。同一段音频帧数是常数，因此不同**长度**的候选处于同一
///   口径，适合「多候选横向比较」（召回精排、跨度判定）。若用 [perToken]，token
///   越多分母越大，长序列会系统性占优（实测设备端因此把单节判成多节连读）。
/// - [perToken]：除以 token 数。用于「同一候选的前缀递增比较」（已读词估算）：
///   最优前缀位置与 [perFrame] 相同，但该处使用的容差常数
///   （[QuranWordProgress.defaultTolerance]）是在此口径下标定的，保留口径即可
///   避免连带重标定。
enum CtcNormalization {
  /// 除以帧数（跨长度候选比较）。
  perFrame,

  /// 除以 token 数（同候选前缀比较）。
  perToken,
}

/// 单个 token 的强制对齐结果：它在最优路径上占用的帧区间（含两端）。
class CtcAlignmentSpan {
  /// 构造帧区间。
  ///
  /// @param start 发射起始帧
  /// @param end 发射结束帧
  const CtcAlignmentSpan({required this.start, required this.end});

  /// 发射起始帧。
  final int start;

  /// 发射结束帧。
  final int end;

  @override
  String toString() => 'CtcAlignmentSpan($start..$end)';
}

/// CTC 打分工具。
class CtcScorer {
  CtcScorer._();

  /// 表示「不可行」的哨兵分数。
  static const double impossibleScore = 1e9;

  /// 序列长度为 n 时的最少帧数（允许每 token 前后各插一个 blank）。
  static int minFramesRequired(int targetLength) => targetLength * 2 + 1;

  /// 计算候选 token 序列的平均负对数似然（越小越匹配）。
  ///
  /// 使用标准 CTC 前向后向（log 域）算法；默认按**帧数**归一化（见 [CtcNormalization]）。
  /// 选按帧是因为跨长度候选比较时，按 token 归一化会让长序列系统性占优 —— 实测
  /// 设备端因此把单节诵读判成 `112:1-3`，而正确单节在按帧口径下以 5 倍差距胜出
  /// （标定数据见 `tools/quran_offline/tune_span_penalty.py`）。
  ///
  /// @param evidence 声学证据
  /// @param ids 候选 token 序列
  /// @param normalize 归一化口径，默认 [CtcNormalization.perFrame]
  /// @return 平均负对数似然；不可行时返回 [impossibleScore]
  static double scoreSequence(
    AcousticEvidence evidence,
    List<int> ids, {
    CtcNormalization normalize = CtcNormalization.perFrame,
  }) {
    final targetLength = ids.length;
    if (targetLength == 0) return impossibleScore;
    if (minFramesRequired(targetLength) > evidence.timeSteps) return impossibleScore;

    final stateCount = targetLength * 2 + 1;
    final states = Int32List(stateCount);
    for (var s = 0; s < stateCount; s++) {
      states[s] = s.isEven ? evidence.blankId : ids[(s - 1) >> 1];
    }

    var prev = Float64List(stateCount)..fillRange(0, stateCount, double.negativeInfinity);
    var curr = Float64List(stateCount)..fillRange(0, stateCount, double.negativeInfinity);

    prev[0] = evidence.logprobs[evidence.blankId];
    if (stateCount > 1) {
      prev[1] = evidence.logprobs[states[1]];
    }

    for (var t = 1; t < evidence.timeSteps; t++) {
      curr.fillRange(0, stateCount, double.negativeInfinity);
      final frameOffset = t * evidence.vocabSize;

      for (var s = 0; s < stateCount; s++) {
        var total = prev[s];
        if (s > 0) total = _logAddExp(total, prev[s - 1]);
        if (s > 1 && states[s] != evidence.blankId && states[s] != states[s - 2]) {
          total = _logAddExp(total, prev[s - 2]);
        }
        if (total != double.negativeInfinity) {
          curr[s] = total + evidence.logprobs[frameOffset + states[s]];
        }
      }

      final swap = prev;
      prev = curr;
      curr = swap;
    }

    var finalScore = prev[stateCount - 1];
    if (stateCount > 1) {
      finalScore = _logAddExp(finalScore, prev[stateCount - 2]);
    }
    if (finalScore.isNaN || finalScore == double.negativeInfinity || !finalScore.isFinite) {
      return impossibleScore;
    }
    final divisor = normalize == CtcNormalization.perFrame ? evidence.timeSteps : targetLength;
    return -finalScore / divisor;
  }

  /// 强制对齐：求候选 token 序列的 Viterbi 最优路径，返回每个 token 的发射帧区间。
  ///
  /// 与 [scoreSequence] 用同一套 CTC 状态图（blank 与 token 交替）。返回的区间是
  /// 「最优路径在该 token 状态上停留的帧」，用于**帧级**判断读到第几个词 ——
  /// 被挤压到音频尾部空白帧的 token 即「尚未念到」（见 [lastContentFrame]）。
  ///
  /// 复杂度 O(帧数 × 状态数)，并保存回溯表（帧数 × 状态数 的 int）。
  ///
  /// @param evidence 声学证据
  /// @param ids 候选 token 序列
  /// @return 每个 token 的帧区间；序列为空或帧数不足（不可行）时返回 null
  static List<CtcAlignmentSpan>? alignFrames(AcousticEvidence evidence, List<int> ids) {
    final targetLength = ids.length;
    if (targetLength == 0) return null;
    if (minFramesRequired(targetLength) > evidence.timeSteps) return null;

    final stateCount = targetLength * 2 + 1;
    final states = Int32List(stateCount);
    for (var s = 0; s < stateCount; s++) {
      states[s] = s.isEven ? evidence.blankId : ids[(s - 1) >> 1];
    }

    var prev = Float64List(stateCount)..fillRange(0, stateCount, double.negativeInfinity);
    var curr = Float64List(stateCount)..fillRange(0, stateCount, double.negativeInfinity);
    // back[t][s] = 帧 t 处于状态 s 时的前驱状态
    final back = List<Int32List>.generate(
      evidence.timeSteps,
      (_) => Int32List(stateCount)..fillRange(0, stateCount, -1),
      growable: false,
    );

    prev[0] = evidence.logprobs[evidence.blankId];
    if (stateCount > 1) {
      prev[1] = evidence.logprobs[states[1]];
    }

    for (var t = 1; t < evidence.timeSteps; t++) {
      curr.fillRange(0, stateCount, double.negativeInfinity);
      final frameOffset = t * evidence.vocabSize;
      final row = back[t];
      for (var s = 0; s < stateCount; s++) {
        var best = prev[s];
        var from = s;
        if (s > 0 && prev[s - 1] > best) {
          best = prev[s - 1];
          from = s - 1;
        }
        if (s > 1 &&
            states[s] != evidence.blankId &&
            states[s] != states[s - 2] &&
            prev[s - 2] > best) {
          best = prev[s - 2];
          from = s - 2;
        }
        if (best == double.negativeInfinity) continue;
        curr[s] = best + evidence.logprobs[frameOffset + states[s]];
        row[s] = from;
      }
      final swap = prev;
      prev = curr;
      curr = swap;
    }

    var endState = stateCount - 1;
    if (stateCount > 1 && prev[stateCount - 2] > prev[endState]) {
      endState = stateCount - 2;
    }
    if (prev[endState] == double.negativeInfinity) return null;

    // 回溯：先还原每帧所在状态，再归并成每个 token 的帧区间
    final spans = List<CtcAlignmentSpan?>.filled(targetLength, null);
    var state = endState;
    for (var t = evidence.timeSteps - 1; t >= 0; t--) {
      if (state.isOdd) {
        final tokenIndex = (state - 1) >> 1;
        final existing = spans[tokenIndex];
        spans[tokenIndex] = existing == null
            ? CtcAlignmentSpan(start: t, end: t)
            : CtcAlignmentSpan(start: t, end: existing.end);
      }
      if (t > 0) state = back[t][state];
    }
    if (spans.any((span) => span == null)) return null;
    return spans.cast<CtcAlignmentSpan>();
  }

  /// 音频「内容区」的最后一帧：逐帧取 argmax，返回最后一个**非 blank** 的帧号。
  ///
  /// 之后的帧在贪心解码里全是 blank（静音或尾部），因此被对齐到该区之后的 token
  /// 视为「还没念到」。整段都没有内容帧时返回 -1。
  ///
  /// @param evidence 声学证据
  /// @return 最后一个内容帧下标；无内容帧时返回 -1
  static int lastContentFrame(AcousticEvidence evidence) {
    for (var t = evidence.timeSteps - 1; t >= 0; t--) {
      final offset = t * evidence.vocabSize;
      var bestId = 0;
      var bestValue = double.negativeInfinity;
      for (var v = 0; v < evidence.vocabSize; v++) {
        final value = evidence.logprobs[offset + v];
        if (value > bestValue) {
          bestValue = value;
          bestId = v;
        }
      }
      if (bestId != evidence.blankId) return t;
    }
    return -1;
  }

  /// 在已排序候选中挑出「得分接近最优且最长」的稳定前缀。
  ///
  /// 候选之间 token 长度不同，故 [scores] 应取 [CtcNormalization.perFrame] 口径
  /// （按 token 口径下长候选会因分母更大而系统性占优）。
  ///
  /// 与 Tilawa 的 `chooseLongestStablePrefix` 一致：按 [tolerance] 允许的分数
  /// 波动范围内，选择 token 数最多的候选，避免过早锁定过短的经文。
  ///
  /// @param scores 与候选一一对应的声学分数（越小越好）
  /// @param lengths 与候选一一对应的 token 长度
  /// @param tolerance 允许的分数容差，默认 0.12
  /// @return 选中的下标；全部不可行时返回 null
  static int? chooseLongestStablePrefix(
    List<double> scores,
    List<int> lengths, {
    double tolerance = 0.12,
  }) {
    if (scores.isEmpty || scores.length != lengths.length) return null;

    final order = List<int>.generate(scores.length, (index) => index)
      ..sort((a, b) => scores[a].compareTo(scores[b]));

    final firstIndex = order.first;
    if (!_isFeasible(scores[firstIndex])) return null;

    final bestScore = scores[firstIndex];
    var bestIndex = firstIndex;
    for (final index in order) {
      if (!_isFeasible(scores[index])) continue;
      if (scores[index] > bestScore + tolerance) break;
      if (lengths[index] >= lengths[bestIndex]) bestIndex = index;
    }
    return bestIndex;
  }

  static bool _isFeasible(double score) => score.isFinite && score < impossibleScore;

  static double _logAddExp(double a, double b) {
    if (a == double.negativeInfinity) return b;
    if (b == double.negativeInfinity) return a;
    final hi = math.max(a, b);
    final lo = math.min(a, b);
    return hi + math.log(1 + math.exp(lo - hi));
  }
}
