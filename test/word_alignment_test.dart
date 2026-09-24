/// 词级比对（对齐、判定阈值、整体指标）的单元测试。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:quran_broadcast_sdk/quran_offline/word_alignment.dart';

void main() {
  group('WordAlignment.align', () {
    test('完全相同：全部一致，F1 为 1，结论优秀', () {
      final result = WordAlignment.align(
        <String>['بسم', 'الله', 'الرحمن'],
        <String>['بسم', 'الله', 'الرحمن'],
      );

      expect(result.matchCount, 3);
      expect(result.missingCount, 0);
      expect(result.extraCount, 0);
      expect(result.coverage, 1.0);
      expect(result.precision, 1.0);
      expect(result.f1, 1.0);
      expect(result.verdict, '优秀');
    });

    test('音标与字母变体经归一化后不影响判定', () {
      final result = WordAlignment.align(
        <String>['بِسْمِ', 'ٱللَّهِ'],
        <String>['بسم', 'الله'],
      );

      expect(result.matchCount, 2);
      expect(result.mismatchCount, 0);
      expect(result.f1, 1.0);
    });

    test('漏词判为缺失，且不会连带后续词一起判错', () {
      final result = WordAlignment.align(
        <String>['الحمد', 'لله', 'رب', 'العالمين'],
        <String>['الحمد', 'رب', 'العالمين'],
      );

      expect(result.matchCount, 3);
      expect(result.missingCount, 1);
      expect(result.rows[1].status, WordStatus.missing);
      expect(result.rows[1].reference, 'لله');
      expect(result.rows[1].hypothesis, isNull);
      expect(result.coverage, closeTo(0.75, 1e-9));
      expect(result.precision, 1.0);
      expect(result.verdict, '良好');
    });

    test('多词判为多余，仍未对齐的原文词保持正确', () {
      final result = WordAlignment.align(
        <String>['الحمد', 'لله'],
        <String>['الحمد', 'لله', 'رب'],
      );

      expect(result.matchCount, 2);
      expect(result.extraCount, 1);
      expect(result.rows.last.status, WordStatus.extra);
      expect(result.rows.last.reference, isNull);
      expect(result.coverage, 1.0);
      expect(result.precision, closeTo(2 / 3, 1e-9));
      expect(result.f1, closeTo(0.8, 1e-9));
    });

    test('发音相近的错词判为近似，按半分计入指标', () {
      final result = WordAlignment.align(<String>['الرحمن'], <String>['الرحيم']);

      expect(result.nearCount, 1);
      expect(result.matchCount, 0);
      expect(result.rows.single.score, closeTo(0.667, 0.01));
      expect(result.coverage, closeTo(0.5, 1e-9));
      expect(result.precision, closeTo(0.5, 1e-9));
      expect(result.verdict, '较差');
    });

    test('完全不同的词判为错配', () {
      final result = WordAlignment.align(<String>['الضلينة'], <String>['محيط']);

      expect(result.rows.single.score, lessThan(WordAlignment.nearThreshold));
      expect(result.mismatchCount, 1);
      expect(result.rows.single.status, WordStatus.mismatch);
    });

    test('空输入不抛异常', () {
      final empty = WordAlignment.align(const <String>[], const <String>[]);
      expect(empty.rows, isEmpty);
      expect(empty.isEmpty, isTrue);
      expect(empty.f1, 0.0);

      final onlyHypothesis = WordAlignment.align(const <String>[], <String>['بسم']);
      expect(onlyHypothesis.extraCount, 1);
      expect(onlyHypothesis.coverage, 0.0);

      final onlyReference = WordAlignment.align(<String>['بسم'], const <String>[]);
      expect(onlyReference.missingCount, 1);
      expect(onlyReference.precision, 0.0);
    });

    test('对齐行顺序与原文一致', () {
      final result = WordAlignment.align(
        <String>['a', 'b', 'c'],
        <String>['a', 'x', 'c'],
      );

      expect(result.rows.map((row) => row.reference).toList(), <String?>['a', 'b', 'c']);
    });
  });

  group('WordAlignment 阈值', () {
    test('相似度分档：≥0.80 一致，≥0.50 近似，其余错配', () {
      expect(WordAlignment.statusOf(1.0), WordStatus.match);
      expect(WordAlignment.statusOf(WordAlignment.matchThreshold), WordStatus.match);
      expect(WordAlignment.statusOf(0.79), WordStatus.near);
      expect(WordAlignment.statusOf(WordAlignment.nearThreshold), WordStatus.near);
      expect(WordAlignment.statusOf(0.49), WordStatus.mismatch);
      expect(WordAlignment.statusOf(0.0), WordStatus.mismatch);
    });

    test('整体结论分档', () {
      expect(WordAlignment.verdictOf(0.95), '优秀');
      expect(WordAlignment.verdictOf(WordAlignment.excellentF1), '优秀');
      expect(WordAlignment.verdictOf(0.80), '良好');
      expect(WordAlignment.verdictOf(0.60), '一般');
      expect(WordAlignment.verdictOf(WordAlignment.fairF1 - 0.01), '较差');
    });
  });
}
