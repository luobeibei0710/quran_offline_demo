/// [CtcScorer] 的前向后向打分与稳定前缀选择测试。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:quran_offline_demo/quran_offline/ctc_scorer.dart';

import 'support/quran_test_fixtures.dart';

void main() {
  group('CtcScorer.minFramesRequired', () {
    test('长度为 n 的序列最少需要 2n+1 帧', () {
      expect(CtcScorer.minFramesRequired(1), 3);
      expect(CtcScorer.minFramesRequired(2), 5);
      expect(CtcScorer.minFramesRequired(3), 7);
    });
  });

  group('CtcScorer.scoreSequence', () {
    test('与声学证据对齐的序列得分接近 0', () {
      final evidence = buildAlignedEvidence(<int>[FixtureTokens.bism, FixtureTokens.allah]);
      final score = CtcScorer.scoreSequence(
        evidence,
        <int>[FixtureTokens.bism, FixtureTokens.allah],
      );

      expect(score.isFinite, isTrue);
      expect(score, lessThan(0.1));
    });

    test('错误序列的得分显著高于正确序列', () {
      final evidence = buildAlignedEvidence(<int>[FixtureTokens.bism, FixtureTokens.allah]);
      final correct = CtcScorer.scoreSequence(
        evidence,
        <int>[FixtureTokens.bism, FixtureTokens.allah],
      );
      final wrong = CtcScorer.scoreSequence(evidence, <int>[FixtureTokens.alhamd]);

      expect(wrong, greaterThan(correct + 1.0));
    });

    test('帧数不足以容纳序列时判定为不可行', () {
      // 合成证据仅有 5 帧，长度 3 的序列至少需要 7 帧
      final evidence = buildAlignedEvidence(<int>[FixtureTokens.bism, FixtureTokens.allah]);

      expect(
        CtcScorer.scoreSequence(
          evidence,
          <int>[FixtureTokens.bism, FixtureTokens.allah, FixtureTokens.alhamd],
        ),
        CtcScorer.impossibleScore,
      );
    });

    test('空序列判定为不可行', () {
      final evidence = buildAlignedEvidence(<int>[FixtureTokens.bism, FixtureTokens.allah]);

      expect(CtcScorer.scoreSequence(evidence, const <int>[]), CtcScorer.impossibleScore);
    });
  });

  group('CtcScorer.chooseLongestStablePrefix', () {
    test('在容差范围内选择最长候选', () {
      expect(
        CtcScorer.chooseLongestStablePrefix(
          <double>[0.10, 0.15, 0.50],
          <int>[5, 9, 20],
        ),
        1,
      );
    });

    test('差距超出容差时保留最优候选', () {
      expect(
        CtcScorer.chooseLongestStablePrefix(
          <double>[0.10, 0.40],
          <int>[5, 20],
        ),
        0,
      );
    });

    test('全部不可行时返回 null', () {
      expect(
        CtcScorer.chooseLongestStablePrefix(
          <double>[CtcScorer.impossibleScore, CtcScorer.impossibleScore],
          <int>[1, 2],
        ),
        isNull,
      );
    });

    test('空列表或长度不一致时返回 null', () {
      expect(CtcScorer.chooseLongestStablePrefix(const <double>[], const <int>[]), isNull);
      expect(CtcScorer.chooseLongestStablePrefix(<double>[0.1], <int>[1, 2]), isNull);
    });
  });
}
