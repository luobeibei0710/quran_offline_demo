/// [QuranAssets] / [QuranVerse] 的解析与索引测试。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quran_offline_demo/quran_offline/quran_assets.dart';

import 'support/quran_test_fixtures.dart';

void main() {
  group('QuranAssets.load', () {
    test('解析词表、经文与 span 表', () async {
      final assets = await loadFixtureAssets();

      expect(assets.vocab, hasLength(FixtureTokens.vocabSize));
      expect(assets.blankId, FixtureTokens.blank);
      expect(assets.verses, hasLength(3));
      expect(assets.spanTokens, hasLength(3));
    });

    test('经文按章号、节号升序排列并建立索引', () async {
      final assets = await loadFixtureAssets();

      expect(assets.verses.map((verse) => verse.ref).toList(), <String>['1:1', '1:2', '2:1']);
      expect(assets.versesBySurah[1], hasLength(2));
      expect(assets.versesByRef['2:1']?.surahNameEn, 'Al-Baqarah');
      expect(assets.verse(1, 2)?.surahName, 'الفاتحة');
      expect(assets.verse(9, 9), isNull);
    });

    test('按引用取 span token 序列', () async {
      final assets = await loadFixtureAssets();

      expect(assets.tokensFor(1, 1, 1), <int>[FixtureTokens.bism, FixtureTokens.allah]);
      expect(assets.tokensFor(1, 1, 2), hasLength(3));
      expect(assets.tokensFor(1, 1, 9), isNull);
    });

    test('资产缺失时抛出 FlutterError', () {
      final bundle = FakeAssetBundle(<String, String>{});

      expect(() => QuranAssets.load(bundle: bundle), throwsA(isA<FlutterError>()));
    });

    test('随后重复读取同一资产时命中缓存', () async {
      final bundle = FakeAssetBundle(buildFixtureAssetFiles());
      await loadFixtureAssets(bundle: bundle);
      await loadFixtureAssets(bundle: bundle);

      expect(bundle.loadCounts['${QuranAssets.assetDir}/vocab.json'], 1);
    });
  });

  group('QuranVerse', () {
    test('ref、归一化文本与分词', () {
      const verse = QuranVerse(
        surah: 1,
        ayah: 1,
        textUthmani: 'بِسْمِ اللَّهِ',
        textClean: '\uFEFFبسم   الله',
        surahName: 'الفاتحة',
        surahNameEn: 'Al-Fatihah',
      );

      expect(verse.ref, '1:1');
      expect(verse.normalizedText, 'بسم الله');
      expect(verse.words, <String>['بسم', 'الله']);
      expect(verse.toString(), contains('1:1'));
    });

    test('textClean 为空时回退到奥斯曼体文本', () {
      const verse = QuranVerse(
        surah: 2,
        ayah: 1,
        textUthmani: 'الم',
        textClean: '',
        surahName: 'البقرة',
        surahNameEn: 'Al-Baqarah',
      );

      expect(verse.normalizedText, 'الم');
      expect(verse.words, <String>['الم']);
    });
  });
}
