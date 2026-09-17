/// 比对原文加载（设备文件覆盖 + 内置资产回退）的单元测试。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:quran_offline_demo/quran_offline/reference_text.dart';

import 'support/quran_test_fixtures.dart';

void main() {
  group('ReferenceText.load', () {
    test('设备文件优先于内置资产', () async {
      final bundle = FakeAssetBundle(<String, String>{
        ReferenceText.assetPath: '内置 原文',
      });

      final reference = await ReferenceText.load(
        bundle: bundle,
        readFile: (path) async => path == ReferenceText.overridePaths.first ? '设备 原文 内容' : null,
      );

      expect(reference.words, <String>['设备', '原文', '内容']);
      expect(reference.source, contains('设备文件'));
      expect(reference.rawText, contains('内容'));
    });

    test('设备文件缺失时回退内置资产', () async {
      final bundle = FakeAssetBundle(<String, String>{
        ReferenceText.assetPath: 'بسم الله\nالرحمن الرحيم',
      });

      final reference = await ReferenceText.load(bundle: bundle, readFile: (_) async => null);

      expect(reference.words, <String>['بسم', 'الله', 'الرحمن', 'الرحيم']);
      expect(reference.source, contains('内置文件'));
    });

    test('设备文件为空内容时视为不可用', () async {
      final bundle = FakeAssetBundle(<String, String>{
        ReferenceText.assetPath: '内置',
      });

      final reference = await ReferenceText.load(bundle: bundle, readFile: (_) async => '   \n  ');

      expect(reference.words, <String>['内置']);
      expect(reference.source, contains('内置文件'));
    });

    test('两条来源都取不到时抛 StateError', () async {
      final bundle = FakeAssetBundle(<String, String>{
        ReferenceText.assetPath: '  ',
      });

      await expectLater(
        ReferenceText.load(bundle: bundle, readFile: (_) async => null),
        throwsA(isA<StateError>()),
      );
    });

    test('设备覆盖路径包含本包私有目录与外部私有目录', () {
      expect(ReferenceText.overridePaths.first, contains('com.llvision.quran_offline_demo'));
      expect(ReferenceText.overridePaths, hasLength(2));
      expect(ReferenceText.overridePaths.last, contains('Android/data'));
    });
  });
}
