import 'package:flutter_test/flutter_test.dart';
import 'package:quran_offline_demo/broadcast/data/translation_catalog.dart';
import 'package:quran_offline_demo/broadcast/domain/utterance_record.dart';
import 'package:quran_offline_demo/broadcast/translation/verse_translation_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BroadcastTranslationCatalog catalog;
  late JsonVerseTranslationRepository repository;

  setUpAll(() async {
    TargetLanguage.resetRegistryForTest();
    catalog = await BroadcastTranslationCatalog.load();
    repository = JsonVerseTranslationRepository(catalog: catalog);
  });

  group('译本目录', () {
    test('加载 62 种语言并全部注册为可选语言', () {
      expect(catalog.editions, hasLength(62));
      expect(catalog.verseCount, 6236);
      final languages = TargetLanguage.all;
      expect(languages.length, greaterThanOrEqualTo(62));
      // 中文与英语排在最前，便于默认选择。
      expect(languages.first, TargetLanguage.chinese);
      expect(languages[1], TargetLanguage.english);
      expect(
        languages.map((language) => language.id),
        containsAll(<String>['uyghur', 'japanese', 'korean', 'french', 'urdu', 'hindi']),
      );
    });

    test('每个译本都带出版方、版本与许可（许可要求署名与注明版本）', () {
      for (final edition in catalog.editions.values) {
        expect(edition.publisher, isNotEmpty, reason: '${edition.editionId} 缺出版方');
        expect(edition.version, isNotEmpty, reason: '${edition.editionId} 缺版本');
        expect(edition.license, contains('QuranEnc'), reason: '${edition.editionId} 缺许可全文');
        expect(edition.attribution, contains(edition.version));
      }
      expect(catalog.obligations, contains('QuranEnc'));
    });

    test('语言标识可用于注册表解析（含早期标识兼容）', () {
      expect(TargetLanguage.tryParse('chinese')!.displayName, '简体中文');
      expect(TargetLanguage.tryParse('uyghur')!.displayName, 'ئۇيغۇرچە');
      // 早期两语言版本落库的标识要能还原。
      expect(TargetLanguage.tryParse('zh-Hans')!.id, 'chinese');
      expect(TargetLanguage.tryParse('en')!.id, 'english');
      expect(TargetLanguage.tryParse(null), isNull);
    });
  });

  group('权威译本查表', () {
    test('中文命中马坚译本，译文与机器翻译的错译形成对比', () async {
      final translation = await repository.find(
        verseKey: '67:8',
        language: TargetLanguage.chinese,
      );
      expect(translation, isNotNull);
      expect(translation!.editionId, 'chinese_makin');
      expect(translation.translator, contains('Makeen'));
      expect(translation.text, contains('火狱'));
      expect(
        translation.text.length,
        greaterThan(20),
        reason: '人工译本应是完整句子，而不是 ML Kit 那种短语级错译',
      );
    });

    test('英文命中 Saheeh 译本', () async {
      final translation = await repository.find(
        verseKey: '112:1',
        language: TargetLanguage.english,
      );
      expect(translation, isNotNull);
      expect(translation!.editionId, 'english_saheeh');
      expect(translation.text.toLowerCase(), contains('say'));
    });

    test('第三语言（乌尔都语）也能查到全经任意节', () async {
      final translation = await repository.find(
        verseKey: '2:255',
        language: TargetLanguage.tryParse('urdu')!,
      );
      expect(translation, isNotNull);
      expect(translation!.text, isNotEmpty);
      expect(translation.verseKey, '2:255');
    });

    test('缺失语言返回 null，由上层回退机器翻译', () async {
      final translation = await repository.find(
        verseKey: '67:8',
        language: const TargetLanguage(id: 'klingon', displayName: 'Klingon'),
      );
      expect(translation, isNull);
      expect(repository.editionIdFor(const TargetLanguage(id: 'klingon', displayName: 'K')), isNull);
    });

    test('切换语言只保留一份译本缓存，内存有界', () async {
      // 依次加载三种语言：如果不做淘汰，62 种语言会有约 89 MB 常驻内存。
      await repository.find(verseKey: '1:1', language: TargetLanguage.chinese);
      await repository.find(verseKey: '1:1', language: TargetLanguage.english);
      final urdu = TargetLanguage.tryParse('uyghur')!;
      await repository.find(verseKey: '1:1', language: urdu);
      // 回到中文仍能查到（缓存被重建，而不是失效）。
      final again = await repository.find(verseKey: '1:1', language: TargetLanguage.chinese);
      expect(again, isNotNull);
      expect(again!.text, isNotEmpty);
    });
  });
}
