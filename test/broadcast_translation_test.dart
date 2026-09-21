import 'package:flutter_test/flutter_test.dart';
import 'package:quran_offline_demo/broadcast/application/translation_coordinator.dart';
import 'package:quran_offline_demo/broadcast/data/app_database.dart';
import 'package:quran_offline_demo/broadcast/data/broadcast_corpus.dart';
import 'package:quran_offline_demo/broadcast/data/record_repository.dart';
import 'package:quran_offline_demo/broadcast/domain/utterance_record.dart';
import 'package:quran_offline_demo/broadcast/translation/offline_translation_engine.dart';
import 'package:quran_offline_demo/broadcast/translation/verse_translation_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 假翻译引擎：记录请求，按脚本返回成功或分类失败。
class _FakeEngine implements OfflineTranslationEngine {
  _FakeEngine({this.failure, this.status = TranslationEngineStatus.ready});

  final TranslationException? failure;
  TranslationEngineStatus status;

  static const String engineVersion = 'fake/1';

  final List<TranslationRequest> requests = <TranslationRequest>[];
  @override
  int generation = 1;
  bool closed = false;

  @override
  String get engineId => engineVersion;

  @override
  Future<TranslationEngineStatus> statusFor(TargetLanguage target) async => status;

  @override
  Future<TranslationEngineStatus> prepare({
    required TargetLanguage target,
    bool allowDownload = true,
  }) async => status;

  @override
  Future<TranslationResult> translate(TranslationRequest request) async {
    requests.add(request);
    final error = failure;
    if (error != null) throw error;
    return TranslationResult(
      text: '译:${request.inputText}',
      provider: 'mlkit',
      engineId: engineVersion,
      elapsedMs: 12,
    );
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

/// 假校订译本仓储。
class _FakeEditions implements VerseTranslationRepository {
  _FakeEditions({this.edition, this.entries = const <String, String>{}});

  final String? edition;
  final Map<String, String> entries;

  @override
  String? get editionId => edition;

  @override
  Future<VerseTranslation?> find({
    required String verseKey,
    required TargetLanguage language,
  }) async {
    final text = entries['${language.code}:$verseKey'];
    if (text == null) return null;
    return VerseTranslation(
      editionId: edition!,
      translator: '测试译者',
      version: '1.0',
      language: language,
      verseKey: verseKey,
      text: text,
    );
  }

  @override
  Set<String>? availableVerseKeys(TargetLanguage language) => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  late BroadcastDatabase database;
  late RecordRepository records;
  late BroadcastQuranLibrary library;

  setUp(() async {
    database = await BroadcastDatabase.open(
      path: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    records = RecordRepository(database.db);
    library = await BroadcastQuranLibrary.load();
  });

  tearDown(() => database.close());

  Future<UtteranceRecord> saveRecord({
    String asrText = 'قل هو الله احد',
    MatchStatus status = MatchStatus.confirmed,
    RecordScope scope = RecordScope.completeVerses,
    List<MatchedVerse> matches = const <MatchedVerse>[],
    TargetLanguage language = TargetLanguage.simplifiedChinese,
    String utteranceId = 'utt',
  }) => records.save(
    RecordDraft(
      sessionId: 'session',
      utteranceId: utteranceId,
      startSample: 0,
      endSample: 16000,
      sampleRate: 16000,
      boundaryReason: BoundaryReason.silence,
      rawAsrText: asrText,
      targetLanguage: language,
      matchStatus: status,
      scope: scope,
      matches: matches,
      job: TranslationJob(
        id: 'job-$utteranceId',
        recordId: 'placeholder',
        revision: 1,
        targetLanguage: language,
        provider: 'mlkit',
        sourceHash: 'pending',
        state: TranslationJobState.pending,
        attemptCount: 0,
        createdAt: DateTime.utc(2026, 9, 21),
      ),
    ),
  );

  MatchedVerse verse(int surah, int ayah, {int? wordStart, int? wordEnd}) => MatchedVerse(
    ordinal: 0,
    surah: surah,
    ayah: ayah,
    wordStart: wordStart,
    wordEnd: wordEnd,
    canonicalTextSnapshot: library.verse(surah, ayah)!.textUthmani,
    matchedTextSnapshot: 'مطابق',
    corpusVersion: library.manifest.corpusVersion,
  );

  TranslationCoordinator coordinatorWith(
    _FakeEngine engine, {
    VerseTranslationRepository? editions,
  }) => TranslationCoordinator(
    engine: engine,
    records: records,
    library: library,
    editions: editions ?? const NoCuratedEditionRepository(),
  );

  group('来源策略', () {
    test('未匹配：翻译实际 ASR 转写，来源为 machineAsr', () async {
      final engine = _FakeEngine();
      final coordinator = coordinatorWith(engine);
      final record = await saveRecord(
        asrText: 'هذا كلام عادي',
        status: MatchStatus.unmatched,
        scope: RecordScope.unknown,
      );
      final status = await coordinator.runJob((await records.pendingJobs()).single);
      expect(status, TranslationStatus.done);

      final input = await coordinator.resolveInput(record, TargetLanguage.simplifiedChinese);
      expect(input.sourceKind, TranslationSourceKind.machineAsr);
      expect(input.text, 'هذا كلام عادي');
      final translation = (await records.byId(record.id))!.translationFor(TargetLanguage.simplifiedChinese)!;
      expect(translation.sourceKind, TranslationSourceKind.machineAsr);
      expect(translation.status, TranslationStatus.done);
      expect(translation.text, startsWith('译:'));
      expect(translation.sourceLabel, contains('未匹配经文'));
    });

    test('匹配成功但无译本：翻译标准原文，来源为 machineCanonical', () async {
      final engine = _FakeEngine();
      final coordinator = coordinatorWith(engine);
      final record = await saveRecord(
        asrText: QuranTextNormalized.ikhlas1,
        matches: <MatchedVerse>[verse(112, 1)],
      );
      await coordinator.runJob((await records.pendingJobs()).single);

      final request = engine.requests.single;
      expect(request.inputKind, TranslationInputKind.canonical);
      // 输入必须是新库标准原文（保留音标），不是归一化后的 ASR 文本。
      expect(request.inputText, library.verse(112, 1)!.textUthmani);
      expect(request.inputText, isNot(QuranTextNormalized.ikhlas1));
      final translation = (await records.byId(record.id))!.translationFor(TargetLanguage.simplifiedChinese)!;
      expect(translation.sourceKind, TranslationSourceKind.machineCanonical);
    });

    test('半节只翻译确认范围，范围标记为 confirmedRange', () async {
      final engine = _FakeEngine();
      final coordinator = coordinatorWith(engine);
      final record = await saveRecord(
        matches: <MatchedVerse>[verse(112, 1, wordStart: 4, wordEnd: 6)],
        scope: RecordScope.partialVerse,
        status: MatchStatus.partial,
      );
      await coordinator.runJob((await records.pendingJobs()).single);

      final request = engine.requests.single;
      final words = library
          .verse(112, 1)!
          .textUthmani
          .split(RegExp(r'\s+'))
          .where((word) => word.isNotEmpty)
          .toList();
      expect(request.inputText, words.sublist(4, 7).join(' '));
      expect(request.inputText, isNot(library.verse(112, 1)!.textUthmani));
      final translation = (await records.byId(record.id))!.translationFor(TargetLanguage.simplifiedChinese)!;
      expect(translation.inputScope, 'confirmedRange');
    });

    test('有授权校订译本时直接查表，不经过机器翻译', () async {
      final engine = _FakeEngine();
      final editions = _FakeEditions(
        edition: 'test-zh',
        entries: <String, String>{'zh-Hans:112:1': '说：他是真主，是独一的主'},
      );
      final coordinator = coordinatorWith(engine, editions: editions);
      final record = await saveRecord(matches: <MatchedVerse>[verse(112, 1)]);
      final status = await coordinator.runJob((await records.pendingJobs()).single);

      expect(status, TranslationStatus.done);
      expect(engine.requests, isEmpty, reason: '命中校订译本不得再调用机器翻译');
      final translation = (await records.byId(record.id))!.translationFor(TargetLanguage.simplifiedChinese)!;
      expect(translation.sourceKind, TranslationSourceKind.curatedEdition);
      expect(translation.text, '说：他是真主，是独一的主');
      expect(translation.editionId, 'test-zh');
      expect(translation.sourceLabel, contains('校订译本'));
    });
  });

  group('失败与重试', () {
    test('缺语言包时保留记录并标记可重试', () async {
      final engine = _FakeEngine(
        failure: const TranslationException(TranslationErrorCode.modelMissing, '缺少语言包'),
        status: TranslationEngineStatus.missing,
      );
      final coordinator = coordinatorWith(engine);
      final record = await saveRecord(matches: <MatchedVerse>[verse(112, 1)]);
      final status = await coordinator.runJob((await records.pendingJobs()).single);

      expect(status, TranslationStatus.modelMissing);
      final reloaded = (await records.byId(record.id))!;
      expect(reloaded.rawAsrText, isNotEmpty, reason: '翻译失败不丢转写与原文');
      final translation = reloaded.translationFor(TargetLanguage.simplifiedChinese)!;
      expect(translation.status, TranslationStatus.modelMissing);
      expect(translation.errorCode, 'modelMissing');
      expect(translation.status.canRetry, isTrue);
      expect(await records.pendingJobs(), hasLength(1), reason: '缺包任务保留待重试');
    });

    test('翻译失败后同一记录可重试，且不新增历史', () async {
      final failing = _FakeEngine(
        failure: const TranslationException(TranslationErrorCode.translateFailed, '引擎异常'),
      );
      final coordinator = coordinatorWith(failing);
      final record = await saveRecord(matches: <MatchedVerse>[verse(112, 1)]);
      await coordinator.runJob((await records.pendingJobs()).single);
      expect(await records.count(), 1);

      final recovered = _FakeEngine();
      final retryCoordinator = coordinatorWith(recovered);
      final ok = await retryCoordinator.retry(record.id, TargetLanguage.simplifiedChinese);
      expect(ok, isTrue);
      expect(await records.count(), 1, reason: '重试不得新建记录');
      final translation = (await records.byId(record.id))!.translationFor(TargetLanguage.simplifiedChinese)!;
      expect(translation.status, TranslationStatus.done);
      expect(translation.text, startsWith('译:'));
    });

    test('记录被删除后任务终止，迟到译文不复活记录', () async {
      final engine = _FakeEngine();
      final coordinator = coordinatorWith(engine);
      final record = await saveRecord(matches: <MatchedVerse>[verse(112, 1)]);
      final job = (await records.pendingJobs()).single;
      await records.delete(record.id);
      final status = await coordinator.runJob(job);
      expect(status, TranslationStatus.failed);
      expect(await records.count(), 0);
    });
  });

  group('缓存与幂等', () {
    test('相同输入命中缓存，不重复调用引擎', () async {
      final engine = _FakeEngine();
      final coordinator = coordinatorWith(engine);
      final first = await saveRecord(
        utteranceId: 'a',
        asrText: QuranTextNormalized.ikhlas1,
        matches: <MatchedVerse>[verse(112, 1)],
      );
      await coordinator.runJob((await records.pendingJobs()).single);
      expect(engine.requests, hasLength(1));

      final second = await saveRecord(
        utteranceId: 'b',
        asrText: QuranTextNormalized.ikhlas1,
        matches: <MatchedVerse>[verse(112, 1)],
      );
      await coordinator.runJob((await records.pendingJobs()).single);
      expect(engine.requests, hasLength(1), reason: '同一输入应命中缓存');

      expect((await records.byId(first.id))!.translationFor(TargetLanguage.simplifiedChinese), isNotNull);
      expect((await records.byId(second.id))!.translationFor(TargetLanguage.simplifiedChinese), isNotNull);
    });

    test('缓存键包含语料版本、语言、提供方与预处理版本', () async {
      final coordinator = coordinatorWith(_FakeEngine());
      final input = TranslationInput(
        kind: TranslationInputKind.canonical,
        sourceKind: TranslationSourceKind.machineCanonical,
        text: 'نص',
        inputScope: 'fullVerses',
      );
      final key = coordinator.cacheKeyFor(
        input,
        TargetLanguage.simplifiedChinese,
        provider: 'mlkit',
        engineId: 'fake/1',
        generation: 2,
      );
      expect(key, contains(library.manifest.corpusId));
      expect(key, contains(library.manifest.corpusVersion));
      expect(key, contains('zh-Hans'));
      expect(key, contains('mlkit'));
      expect(key, contains('gen2'));
      expect(key, contains(TranslationPreprocessor.version));

      final englishKey = coordinator.cacheKeyFor(
        input,
        TargetLanguage.english,
        provider: 'mlkit',
        engineId: 'fake/1',
        generation: 2,
      );
      expect(englishKey, isNot(key), reason: '不同目标语言必须使用不同缓存键');
    });
  });
}

/// 测试用的归一化文本常量，避免在断言里手写阿拉伯字符。
class QuranTextNormalized {
  QuranTextNormalized._();

  /// 112:1 的归一化整节文本（含章首太斯米）。
  static const String ikhlas1 = 'بسم الله الرحمن الرحيم قل هو الله احد';
}
