/// [QuranText] 的阿拉伯语归一化与相似度测试。
///
/// 这些断言与 Tilawa 的 `normalizer.ts` + `levenshtein.ts` 语义对齐，
/// 是召回质量的第一道防线，故覆盖变音符号、字母变体与空白处理。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:quran_offline_demo/quran_offline/quran_text.dart';

void main() {
  group('QuranText.normalize', () {
    test('移除变音符号（تشكيل）与 Tatweel', () {
      expect(QuranText.normalize('بِسْمِ اللَّهِ'), 'بسم الله');
      expect(QuranText.normalize('الْحَم\u0640\u0640دُ'), 'الحمد');
    });

    test('统一字母变体，避免同音异写被判为不同字符', () {
      expect(QuranText.normalize('أحمد'), 'احمد');
      expect(QuranText.normalize('إبراهيم'), 'ابراهيم');
      expect(QuranText.normalize('آمن'), 'امن');
      expect(QuranText.normalize('ٱلْحَمْدُ'), 'الحمد');
      expect(QuranText.normalize('رحمة'), 'رحمه');
      expect(QuranText.normalize('موسى'), 'موسي');
    });

    test('移除 BOM 并压缩空白', () {
      expect(QuranText.normalize('\uFEFF بسم   الله '), 'بسم الله');
      expect(QuranText.normalize('   '), '');
      expect(QuranText.normalize(''), '');
    });
  });

  group('QuranText.ratio', () {
    test('完全相同的文本相似度为 1', () {
      expect(QuranText.ratio('بسم الله', 'بسم الله'), 1.0);
    });

    test('任一为空时相似度为 0', () {
      expect(QuranText.ratio('', 'بسم'), 0.0);
      expect(QuranText.ratio('بسم', ''), 0.0);
      expect(QuranText.ratio('', ''), 1.0);
    });

    test('按最长长度归一化编辑距离', () {
      expect(QuranText.ratio('abc', 'abd'), closeTo(1 - 1 / 3, 1e-9));
      expect(QuranText.ratio('abc', 'abcde'), closeTo(1 - 2 / 5, 1e-9));
    });
  });

  group('QuranText.fragmentScore', () {
    test('查询为目标的连续片段时得分为 1', () {
      expect(QuranText.fragmentScore('الله', 'بسم الله الرحمن الرحيم'), 1.0);
    });

    test('空输入得分为 0', () {
      expect(QuranText.fragmentScore('', 'بسم'), 0.0);
      expect(QuranText.fragmentScore('بسم', ''), 0.0);
    });

    test('查询长于目标时自动交换两侧', () {
      expect(QuranText.fragmentScore('بسم الله', 'بسم'), closeTo(1.0, 1e-9));
    });
  });

  group('QuranText.textScore', () {
    test('完全一致时权重和为 1', () {
      expect(QuranText.textScore('بسم', 'بسم'), 1.0);
    });

    test('部分匹配时介于 0 与 1 之间', () {
      final score = QuranText.textScore('بسم', 'بسم الله الرحمن الرحيم');
      expect(score, greaterThan(0.0));
      expect(score, lessThan(1.0));
    });
  });
}
