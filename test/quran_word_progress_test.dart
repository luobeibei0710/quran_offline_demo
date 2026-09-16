/// [QuranWordProgress] 的词分组、已读词估算与词表对齐测试。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:quran_offline_demo/quran_offline/quran_word_progress.dart';

import 'support/quran_test_fixtures.dart';

void main() {
  group('QuranWordProgress.groupByWord', () {
    test('按 BPE 词边界前缀切分', () async {
      final assets = await loadFixtureAssets();

      // token 1 = ▁بسم（新词开始）、token 2 = الله（续接到前词）、
      // token 3 = ▁الحمد（词边界前缀 → 开启新组）
      expect(
        QuranWordProgress.groupByWord(
          <int>[FixtureTokens.bism, FixtureTokens.allah, FixtureTokens.alhamd],
          assets.vocab,
        ),
        <List<int>>[
          <int>[FixtureTokens.bism, FixtureTokens.allah],
          <int>[FixtureTokens.alhamd],
        ],
      );
    });

    test('首个 token 无论是否带边界前缀都自成一组', () async {
      final assets = await loadFixtureAssets();

      expect(
        QuranWordProgress.groupByWord(<int>[FixtureTokens.allah], assets.vocab),
        <List<int>>[
          <int>[FixtureTokens.allah],
        ],
      );
    });

    test('空序列返回空分组', () async {
      final assets = await loadFixtureAssets();
      expect(QuranWordProgress.groupByWord(const <int>[], assets.vocab), isEmpty);
    });
  });

  group('QuranWordProgress.estimateReadWords', () {
    test('声学证据完整覆盖时判定为读完全部词', () async {
      final evidence = buildAlignedEvidence(<int>[FixtureTokens.bism, FixtureTokens.allah]);

      // 词分组：[[1], [2]]，与证据完全对齐
      final readWords = QuranWordProgress.estimateReadWords(
        evidence,
        <List<int>>[
          <int>[FixtureTokens.bism],
          <int>[FixtureTokens.allah],
        ],
      );

      expect(readWords, 2);
    });

    test('前缀不可行时停在最后一个可行词', () async {
      // 证据只有 5 帧：前缀 [1]（3 帧）可行，前缀 [1,2,3]（7 帧）不可行
      final evidence = buildAlignedEvidence(<int>[FixtureTokens.bism, FixtureTokens.allah]);

      final readWords = QuranWordProgress.estimateReadWords(
        evidence,
        <List<int>>[
          <int>[FixtureTokens.bism],
          <int>[FixtureTokens.allah, FixtureTokens.alhamd],
        ],
      );

      expect(readWords, 1);
    });

    test('空词组返回 0', () {
      final evidence = buildAlignedEvidence(<int>[FixtureTokens.bism]);

      expect(QuranWordProgress.estimateReadWords(evidence, const <List<int>>[]), 0);
    });
  });

  group('QuranWordProgress.alignedWords', () {
    test('token 词组少于经节词数时截断词表', () async {
      final assets = await loadFixtureAssets();

      // 夹具中 1:1 的 tokens 为 [1, 2]，两个 token 同属一个词（token 2 无 ▁ 前缀），
      // 而经文有 2 个词 → 以较少的一方为准，词表截断为 1 个
      final (words, groups) = QuranWordProgress.alignedWords(assets, 1, 1, 1);

      expect(groups, hasLength(1));
      expect(words, <String>['بسم']);
    });

    test('token 词组多于经节词数时按尾部对齐', () async {
      final assets = await loadFixtureAssets();

      // 1:2 的 token 表只有 1 个词组（[3]），而经文有 2 个词
      final (words, groups) = QuranWordProgress.alignedWords(assets, 1, 2, 2);

      expect(groups, hasLength(1));
      expect(words, hasLength(groups.length));
      expect(words.first, 'الحمد');
    });

    test('缺少 span token 表时返回原文词与空词组', () async {
      final assets = await loadFixtureAssets();

      final (words, groups) = QuranWordProgress.alignedWords(assets, 2, 1, 1);

      expect(words, isNotEmpty);
      expect(groups, isEmpty);
    });
  });
}
