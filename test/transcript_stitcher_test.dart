/// 流式转写拼接（重叠去重）的单元测试。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:quran_offline_demo/quran_offline/transcript_stitcher.dart';

void main() {
  group('TranscriptStitcher.add', () {
    test('首次追加整段', () {
      final stitcher = TranscriptStitcher();

      expect(stitcher.add('a b c'), 3);
      expect(stitcher.words, <String>['a', 'b', 'c']);
      expect(stitcher.text, 'a b c');
      expect(stitcher.length, 3);
      expect(stitcher.isEmpty, isFalse);
    });

    test('窗口向后增长：只追加超出重叠的部分', () {
      final stitcher = TranscriptStitcher()..add('a b c');

      expect(stitcher.add('a b c d e'), 2);
      expect(stitcher.text, 'a b c d e');
    });

    test('窗口向前滑动：重叠部分不重复计入', () {
      final stitcher = TranscriptStitcher()..add('a b c d');

      expect(stitcher.add('c d e f'), 2);
      expect(stitcher.text, 'a b c d e f');
    });

    test('整段已被包含时不追加', () {
      final stitcher = TranscriptStitcher()..add('a b c d');

      expect(stitcher.add('b c d'), 0);
      expect(stitcher.length, 4);
    });

    test('无重叠时整段追加（漏识别造成的断档）', () {
      final stitcher = TranscriptStitcher()..add('a b');

      expect(stitcher.add('x y'), 2);
      expect(stitcher.text, 'a b x y');
    });

    test('按归一化文本判定重叠：音标差异不影响', () {
      final stitcher = TranscriptStitcher()..add('بِسْمِ ٱللَّهِ');

      expect(stitcher.add('بسم الله الرحمن'), 1);
      expect(stitcher.words, <String>['بِسْمِ', 'ٱللَّهِ', 'الرحمن']);
    });

    test('空文本与纯空白不追加', () {
      final stitcher = TranscriptStitcher();

      expect(stitcher.add(''), 0);
      expect(stitcher.add('   '), 0);
      expect(stitcher.isEmpty, isTrue);
    });

    test('reset 清空累积内容', () {
      final stitcher = TranscriptStitcher()..add('a b c');

      stitcher.reset();

      expect(stitcher.isEmpty, isTrue);
      expect(stitcher.text, '');
    });

    test('重叠搜索受 maxOverlapWords 限制', () {
      final stitcher = TranscriptStitcher(maxOverlapWords: 2)..add('a b c d e');

      // 尾部最多回看 2 个词（d e），因此只识别出 2 词重叠
      expect(stitcher.add('d e f'), 1);
      expect(stitcher.text, 'a b c d e f');
    });
  });
}
