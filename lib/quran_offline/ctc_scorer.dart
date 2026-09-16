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

/// CTC 打分工具。
class CtcScorer {
  CtcScorer._();

  /// 表示「不可行」的哨兵分数。
  static const double impossibleScore = 1e9;

  /// 序列长度为 n 时的最少帧数（允许每 token 前后各插一个 blank）。
  static int minFramesRequired(int targetLength) => targetLength * 2 + 1;

  /// 计算候选 token 序列的平均负对数似然（越小越匹配）。
  ///
  /// 使用标准 CTC 前向后向（log 域）算法，返回 `-logP(seq) / len(seq)`，
  /// 便于不同长度候选之间横向比较。
  ///
  /// @param evidence 声学证据
  /// @param ids 候选 token 序列
  /// @return 平均负对数似然；不可行时返回 [impossibleScore]
  static double scoreSequence(AcousticEvidence evidence, List<int> ids) {
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
    return -finalScore / targetLength;
  }

  /// 在已排序候选中挑出「得分接近最优且最长」的稳定前缀。
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
