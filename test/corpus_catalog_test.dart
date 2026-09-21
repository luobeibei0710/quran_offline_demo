/// 语料清单的单元测试。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:quran_offline_demo/quran_offline/corpus_catalog.dart';
import 'package:quran_offline_demo/quran_offline/reference_text.dart';

import 'support/quran_test_fixtures.dart';

void main() {
  group('CorpusCatalog.load（内置语料）', () {
    test('从 manifest.json 列出内置语料，原文按章节区间取', () async {
      final bundle = FakeAssetBundle(<String, String>{
        CorpusCatalog.manifestAsset: jsonEncode(<Map<String, Object>>[
          <String, Object>{
            'file': 'corpus_036_001_005.wav',
            'surah': 36,
            'ayahStart': 1,
            'ayahEnd': 5,
            'includesBismillah': false,
          },
          <String, Object>{
            'file': 'corpus_112_001_001.wav',
            'surah': 112,
            'ayahStart': 1,
            'ayahEnd': 1,
          },
        ]),
      });

      final items = await CorpusCatalog.load(
        bundle: bundle,
        listDir: (_) async => const <String>[],
      );

      expect(items, hasLength(2));
      expect(items.first.includesBismillah, isFalse);
      expect(items.last.includesBismillah, isTrue);
      expect(items.first.audio.assetKey, '${CorpusCatalog.assetDir}corpus_036_001_005.wav');
      expect(items.first.title, '内置语料 · 36:1-5');
      expect(items.first.expectedRefs, <String>['36:1', '36:2', '36:3', '36:4', '36:5']);
      expect(items.last.expectedRefs, <String>['112:1']);
      expect(items.last.title, '内置语料 · 112:1');
    });

    test('清单缺失或格式不符时不抛异常，只是没有内置语料', () async {
      final missing = await CorpusCatalog.load(
        bundle: FakeAssetBundle(<String, String>{}),
        listDir: (_) async => const <String>[],
      );
      final broken = await CorpusCatalog.load(
        bundle: FakeAssetBundle(<String, String>{CorpusCatalog.manifestAsset: '不是 JSON'}),
        listDir: (_) async => const <String>[],
      );

      expect(missing, isEmpty);
      expect(broken, isEmpty);
    });
  });

  group('CorpusCatalog.load（设备语料）', () {
    /// 设备语料目录（用第一个候选目录模拟）。
    final String deviceDir = CorpusCatalog.deviceDirs.first;

    test('同名 txt 提供原文；无 txt 但文件名含区间时用经文库区间；两者都没有则跳过', () async {
      final files = <String>[
        '$deviceDir/我的朗读.wav',
        '$deviceDir/corpus_078_001_010.wav',
        '$deviceDir/坏文件.wav',
      ];
      final texts = <String, String>{'$deviceDir/我的朗读.txt': 'قل هو الله احد'};

      final items = await CorpusCatalog.load(
        bundle: FakeAssetBundle(<String, String>{}),
        listDir: (dir) async => dir == deviceDir ? files : const <String>[],
        readText: (path) async => texts[path],
      );

      expect(items, hasLength(2));
      final custom = items.firstWhere((item) => item.id == '$deviceDir/我的朗读.wav');
      expect(custom.reference.isRange, isFalse);
      expect(custom.reference.textPaths, <String>['$deviceDir/我的朗读.txt']);
      expect(custom.expectedRefs, isEmpty);

      final byName = items.firstWhere((item) => item.id == '$deviceDir/corpus_078_001_010.wav');
      expect(byName.reference.isRange, isTrue);
      expect(byName.expectedRefs.first, '78:1');
      expect(byName.expectedRefs.last, '78:10');
    });

    test('文件名区间解析', () {
      expect(CorpusCatalog.parseRangeFromFileName('corpus_036_001_005.wav'), (36, 1, 5));
      expect(CorpusCatalog.parseRangeFromFileName('CORPUS_112_001_001.WAV'), (112, 1, 1));
      expect(CorpusCatalog.parseRangeFromFileName('我的朗读.wav'), isNull);
    });
  });

  group('CorpusCatalog.referenceVariants', () {
    test('把经文库里的太斯米前缀单独给出一个变体', () {
      // 36:1 在经文库里的原文是「太斯米 + يس」，但语料音频不一定含太斯米
      const full = ReferenceText(
        words: <String>['بسم', 'الله', 'الرحمن', 'الرحيم', 'يس'],
        rawText: 'بِسْمِ اللَّهِ الرَّحْمَٰنِ الرَّحِيمِ يس',
        source: '经文库标准经文 · 36:1',
      );

      final variants = CorpusCatalog.referenceVariants(full);

      expect(variants, hasLength(2));
      expect(variants.first.words, full.words);
      expect(variants.last.words, <String>['يس']);
      expect(variants.last.rawText, 'يس');
      expect(variants.last.source, contains('去掉太斯米前缀'));
      expect(CorpusCatalog.fixedReference(full, includesBismillah: true).words, full.words);
      expect(CorpusCatalog.fixedReference(full, includesBismillah: false).words, ['يس']);
    });

    test('不含太斯米前缀（或本身就是太斯米）时只有一条', () {
      const other = ReferenceText(
        words: <String>['قل', 'هو', 'الله', 'احد'],
        rawText: 'قل هو الله احد',
        source: '经文库标准经文 · 112:1',
      );
      const bismillahOnly = ReferenceText(
        words: <String>['بسم', 'الله', 'الرحمن', 'الرحيم'],
        rawText: 'بسم الله الرحمن الرحيم',
        source: '经文库标准经文 · 1:1',
      );

      expect(CorpusCatalog.referenceVariants(other), hasLength(1));
      expect(CorpusCatalog.referenceVariants(bismillahOnly), hasLength(1));
    });
  });
}
