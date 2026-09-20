/// 语料清单的单元测试。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:quran_offline_demo/quran_offline/corpus_catalog.dart';
import 'package:quran_offline_demo/quran_offline/reference_text.dart';

void main() {
  group('CorpusCatalog.load', () {
    test('设备上没有自定义语料时只列官方语料（5 条，均来自资产）', () async {
      final items = await CorpusCatalog.load(fileExists: (_) async => false);

      expect(items.length, CorpusCatalog.officialSamples.length);
      expect(
        items.map((item) => item.reference.ref).toList(),
        <String>['1:1', '1:2', '2:255', '36:1', '112:1'],
      );
      expect(items.every((item) => item.audio.isAsset), isTrue);
      expect(items.every((item) => item.reference.hasExpectedRef), isTrue);
    });

    test('检测到自定义音频时追加一条，原文走设备文件（回退内置）', () async {
      final items = await CorpusCatalog.load(
        fileExists: (path) async => path == CorpusCatalog.customAudioPaths.first,
      );

      expect(items.length, CorpusCatalog.officialSamples.length + 1);
      final custom = items.last;
      expect(custom.id, CorpusCatalog.customId);
      expect(custom.audio.isAsset, isFalse);
      expect(custom.audio.filePaths, CorpusCatalog.customAudioPaths);
      expect(custom.reference.ref, isNull);
      expect(custom.reference.textPaths, ReferenceText.overridePaths);
    });

    test('原文变体：把经文库里的太斯米前缀单独给出一个变体', () {
      // 36:1 在经文库里的原文是「太斯米 + يس」，但官方音频不含太斯米
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
    });

    test('原文变体：不含太斯米前缀（或本身就是太斯米）时只有一条', () {
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

    test('外部私有目录存在自定义音频时同样会列出', () async {
      final items = await CorpusCatalog.load(
        fileExists: (path) async => path == CorpusCatalog.customAudioPaths.last,
      );

      expect(items.last.id, CorpusCatalog.customId);
    });
  });
}
