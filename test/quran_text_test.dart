/// [QuranText] 的阿拉伯语归一化与相似度测试。
///
/// 这些断言覆盖与 Tilawa 对齐的基本语义，以及外部输入的 Arabic Presentation
/// Forms-A/B 兼容，是召回质量的第一道防线。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:quran_broadcast_sdk/quran_offline/quran_text.dart';

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

    test('Presentation Forms 的词首、词中、词尾与独立形等价于逻辑字母', () {
      for (final shapedBeh in <String>[
        '\uFE8F',
        '\uFE90',
        '\uFE91',
        '\uFE92',
      ]) {
        expect(QuranText.normalize(shapedBeh), 'ب');
      }
      expect(QuranText.normalize('\uFE91\uFEB4\uFEE2'), 'بسم');
    });

    test('展开 Allah 与 lam-alef 合字后继续应用既有字母归一化', () {
      expect(QuranText.normalize('\uFDF2'), 'الله');
      for (final lamAlef in <String>[
        '\uFEF5',
        '\uFEF6',
        '\uFEF7',
        '\uFEF8',
        '\uFEF9',
        '\uFEFA',
        '\uFEFB',
        '\uFEFC',
      ]) {
        expect(QuranText.normalize(lamAlef), 'لا');
      }
    });

    test('没有 Unicode 分解的装饰合字与符号保持原样', () {
      expect(QuranText.normalize('\uFDFD'), '\uFDFD');
      expect(QuranText.normalize('\uFE73'), '\uFE73');
    });

    test('Presentation Forms 归一化幂等且不改变既有逻辑字符结果', () {
      const shaped = '\uFE91\uFEB4\uFEE2 \uFDF2 \uFEFB';
      final normalized = QuranText.normalize(shaped);
      expect(QuranText.normalize(normalized), normalized);
      expect(QuranText.normalize('بِسْمِ اللَّهِ'), 'بسم الله');
      expect(QuranText.normalize('أحمد رحمة موسى'), 'احمد رحمه موسي');
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
