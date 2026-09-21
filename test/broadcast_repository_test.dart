import 'package:flutter_test/flutter_test.dart';
import 'package:quran_offline_demo/broadcast/data/app_database.dart';
import 'package:quran_offline_demo/broadcast/data/record_repository.dart';
import 'package:quran_offline_demo/broadcast/domain/utterance_record.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  late BroadcastDatabase database;
  late RecordRepository repository;

  setUp(() async {
    database = await BroadcastDatabase.open(
      path: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    repository = RecordRepository(database.db);
  });

  tearDown(() async {
    await database.close();
  });

  RecordDraft draft({
    String utteranceId = 'utt-1',
    String sessionId = 'sess-1',
    int revision = 1,
    String text = 'قل هو الله احد',
    MatchStatus status = MatchStatus.confirmed,
    RecordScope scope = RecordScope.completeVerses,
    TargetLanguage language = TargetLanguage.simplifiedChinese,
    List<MatchedVerse> matches = const <MatchedVerse>[],
    RecordMetrics? metrics,
    TranslationJob? job,
  }) => RecordDraft(
    sessionId: sessionId,
    utteranceId: utteranceId,
    revision: revision,
    startSample: 0,
    endSample: 16000,
    sampleRate: 16000,
    boundaryReason: BoundaryReason.silence,
    rawAsrText: text,
    targetLanguage: language,
    matchStatus: status,
    scope: scope,
    matches: matches,
    metrics: metrics,
    job: job,
  );

  MatchedVerse verse(int ordinal, int surah, int ayah, {int? wordStart, int? wordEnd}) =>
      MatchedVerse(
        ordinal: ordinal,
        surah: surah,
        ayah: ayah,
        wordStart: wordStart,
        wordEnd: wordEnd,
        canonicalTextSnapshot: 'سورة $surah:$ayah',
        matchedTextSnapshot: 'مطابق',
        corpusVersion: '1.1',
      );

  group('建库与迁移', () {
    test('schema 版本为 1，迁移步骤可重复执行', () async {
      expect(BroadcastDatabase.schemaVersion, 1);
      // 重复执行建库与迁移必须是幂等的（先建最新库再回填版本号的场景）。
      await BroadcastDatabase.createSchema(database.db);
      await BroadcastDatabase.migrate(database.db, from: 0, to: 1);
      final tables = await database.db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      );
      final names = <String>[for (final row in tables) '${row['name']}'];
      expect(
        names,
        containsAll(<String>[
          'recognition_sessions',
          'utterance_records',
          'record_matches',
          'record_metrics',
          'record_translations',
          'translation_jobs',
          'translation_cache',
          'settings',
        ]),
      );
    });

    test('缺少迁移步骤时明确报错，不静默降级', () async {
      expect(
        () => BroadcastDatabase.migrate(database.db, from: 1, to: 2),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('记录保存与幂等', () {
    test('同一音频片段反复保存只更新一条记录，序号不变', () async {
      final first = await repository.save(draft());
      expect(first.displaySequence, 1);
      expect(await repository.count(), 1);

      final second = await repository.save(draft(text: 'قل هو الله احد الرحمن'));
      expect(second.id, first.id, reason: '同一 (session, utterance, revision) 必须复用同一记录');
      expect(second.displaySequence, 1);
      expect(second.rawAsrText, 'قل هو الله احد الرحمن');
      expect(await repository.count(), 1);
    });

    test('同一经文在另一时间复读生成新记录，序号递增且不复用', () async {
      final first = await repository.save(draft(utteranceId: 'utt-1'));
      final second = await repository.save(draft(utteranceId: 'utt-2'));
      expect(second.id, isNot(first.id));
      expect(second.displaySequence, 2);

      await repository.delete(second.id);
      expect(await repository.count(), 1);
      final third = await repository.save(draft(utteranceId: 'utt-3'));
      expect(third.displaySequence, 3, reason: '删除后不得回收旧序号');
    });

    test('匹配、指标与翻译任务在同一事务中保存', () async {
      final record = await repository.save(
        draft(
          matches: <MatchedVerse>[verse(0, 112, 1), verse(1, 112, 2)],
          metrics: const RecordMetrics(
            metricScope: '112:1-2',
            precision: 0.9,
            recall: 0.8,
            f1: 0.85,
            strictWer: 1.4,
            substitutions: 2,
            deletions: 3,
            insertions: 4,
            referenceWords: 10,
            hypothesisWords: 11,
            matchCount: 8,
            nearCount: 1,
            mismatchCount: 1,
            missingCount: 1,
            extraCount: 2,
            normalizationVersion: 'quran-text-normalize-1',
          ),
          job: TranslationJob(
            id: 'job-1',
            recordId: 'placeholder',
            revision: 1,
            targetLanguage: TargetLanguage.simplifiedChinese,
            provider: 'mlkit',
            sourceHash: 'hash-1',
            state: TranslationJobState.pending,
            attemptCount: 0,
            createdAt: DateTime.utc(2026, 9, 21),
          ),
        ),
      );
      expect(record.matches, hasLength(2));
      expect(record.matches.first.label, '112:1');
      expect(record.metrics!.f1, closeTo(0.85, 1e-9));
      expect(record.metrics!.strictWer, closeTo(1.4, 1e-9), reason: 'WER 允许超过 100% 且不截断');
      final jobs = await repository.pendingJobs();
      expect(jobs, hasLength(1));
      expect(jobs.single.recordId, record.id);
    });

    test('无可信参考时指标为 null，而不是 0 分', () async {
      final record = await repository.save(
        draft(
          status: MatchStatus.unmatched,
          scope: RecordScope.unknown,
          metrics: RecordMetrics.unavailable(
            metricScope: 'unmatched',
            normalizationVersion: 'quran-text-normalize-1',
          ),
        ),
      );
      expect(record.metrics, isNotNull);
      expect(record.metrics!.f1, isNull);
      expect(record.metrics!.precision, isNull);
      expect(record.metrics!.strictWer, isNull);
      expect(record.matches, isEmpty);
      expect(record.matchSummary, '未匹配');
    });
  });

  group('译文与任务的一致性', () {
    test('迟到译文只有在修订号与目标语言相符时才写入', () async {
      final record = await repository.save(draft());
      final ok = await repository.saveTranslation(
        RecordTranslation(
          id: 'tr-1',
          recordId: record.id,
          revision: 1,
          targetLanguage: TargetLanguage.simplifiedChinese,
          provider: 'mlkit',
          sourceKind: TranslationSourceKind.machineCanonical,
          sourceHash: 'h1',
          inputScope: 'confirmedRange',
          text: '说：他是真主，是独一的主',
          status: TranslationStatus.done,
          createdAt: DateTime.utc(2026, 9, 21),
        ),
      );
      expect(ok, isTrue);

      final staleRevision = await repository.saveTranslation(
        RecordTranslation(
          id: 'tr-2',
          recordId: record.id,
          revision: 2,
          targetLanguage: TargetLanguage.simplifiedChinese,
          provider: 'mlkit',
          sourceKind: TranslationSourceKind.machineCanonical,
          sourceHash: 'h2',
          inputScope: 'confirmedRange',
          text: '过期译文',
          status: TranslationStatus.done,
          createdAt: DateTime.utc(2026, 9, 21),
        ),
      );
      expect(staleRevision, isFalse, reason: '旧 revision 不得覆盖当前记录');

      final staleLanguage = await repository.saveTranslation(
        RecordTranslation(
          id: 'tr-3',
          recordId: record.id,
          revision: 1,
          targetLanguage: TargetLanguage.english,
          provider: 'mlkit',
          sourceKind: TranslationSourceKind.machineCanonical,
          sourceHash: 'h3',
          inputScope: 'confirmedRange',
          text: 'stale',
          status: TranslationStatus.done,
          createdAt: DateTime.utc(2026, 9, 21),
        ),
      );
      expect(staleLanguage, isFalse, reason: '目标语言在创建时冻结，晚到结果不得串语言');

      final reloaded = (await repository.byId(record.id))!;
      expect(reloaded.translationFor(TargetLanguage.simplifiedChinese)!.text, '说：他是真主，是独一的主');
      expect(reloaded.translationFor(TargetLanguage.english), isNull);
    });

    test('记录被删除后，迟到译文不能复活记录', () async {
      final record = await repository.save(
        draft(
          job: TranslationJob(
            id: 'job-x',
            recordId: 'placeholder',
            revision: 1,
            targetLanguage: TargetLanguage.english,
            provider: 'mlkit',
            sourceHash: 'h',
            state: TranslationJobState.pending,
            attemptCount: 0,
            createdAt: DateTime.utc(2026, 9, 21),
          ),
        ),
      );
      await repository.delete(record.id);
      final written = await repository.saveTranslation(
        RecordTranslation(
          id: 'tr-late',
          recordId: record.id,
          revision: 1,
          targetLanguage: TargetLanguage.english,
          provider: 'mlkit',
          sourceKind: TranslationSourceKind.machineAsr,
          sourceHash: 'h',
          inputScope: 'confirmedRange',
          text: 'late',
          status: TranslationStatus.done,
          createdAt: DateTime.utc(2026, 9, 21),
        ),
      );
      expect(written, isFalse);
      expect(await repository.count(), 0);
    });

    test('删除记录级联清理匹配、指标、译文与任务', () async {
      final record = await repository.save(
        draft(
          matches: <MatchedVerse>[verse(0, 1, 1)],
          metrics: RecordMetrics.unavailable(
            metricScope: 'unmatched',
            normalizationVersion: 'quran-text-normalize-1',
          ),
          job: TranslationJob(
            id: 'job-c',
            recordId: 'placeholder',
            revision: 1,
            targetLanguage: TargetLanguage.simplifiedChinese,
            provider: 'mlkit',
            sourceHash: 'h',
            state: TranslationJobState.pending,
            attemptCount: 0,
            createdAt: DateTime.utc(2026, 9, 21),
          ),
        ),
      );
      await repository.delete(record.id);
      for (final table in <String>[
        'record_matches',
        'record_metrics',
        'translation_jobs',
      ]) {
        final rows = await database.db.query(table);
        expect(rows, isEmpty, reason: '$table 应随记录级联删除');
      }
    });

    test('重启把残留 running 任务恢复为 pending 并保留记录', () async {
      final record = await repository.save(
        draft(
          job: TranslationJob(
            id: 'job-r',
            recordId: 'placeholder',
            revision: 1,
            targetLanguage: TargetLanguage.english,
            provider: 'mlkit',
            sourceHash: 'h',
            state: TranslationJobState.running,
            attemptCount: 0,
            createdAt: DateTime.utc(2026, 9, 21),
          ),
        ),
      );
      final recovered = await repository.recoverInterruptedJobs();
      expect(recovered, 1);
      expect((await repository.pendingJobs()).single.id, 'job-r');
      expect((await repository.byId(record.id))!.rawAsrText, 'قل هو الله احد');

      final requeued = await repository.requeueJobs(record.id, TargetLanguage.english);
      expect(requeued, 1);
      expect(await repository.count(), 1, reason: '重试不得新建历史');
    });
  });

  group('清空全部历史', () {
    test('级联清理关联数据并重置展示序号', () async {
      for (var index = 0; index < 3; index++) {
        await repository.save(
          draft(
            utteranceId: 'utt-$index',
            matches: <MatchedVerse>[verse(0, 112, 1)],
            job: TranslationJob(
              id: 'job-$index',
              recordId: 'placeholder',
              revision: 1,
              targetLanguage: TargetLanguage.simplifiedChinese,
              provider: 'mlkit',
              sourceHash: 'h',
              state: TranslationJobState.pending,
              attemptCount: 0,
              createdAt: DateTime.utc(2026, 9, 21),
            ),
          ),
        );
      }
      expect(await repository.count(), 3);

      expect(await repository.deleteAll(), 3);
      expect(await repository.count(), 0);
      expect(await repository.page(), isEmpty);
      for (final table in <String>['record_matches', 'record_metrics', 'translation_jobs']) {
        expect(await database.db.query(table), isEmpty, reason: '$table 应被级联清理');
      }
      expect(await repository.pendingJobs(), isEmpty);

      // 「清空」语义：序号重置，新记录从 #000001 开始。
      final fresh = await repository.save(draft(utteranceId: 'after-clear'));
      expect(fresh.displaySequence, 1);
    });

    test('保留翻译缓存，避免重新识别时重复调用引擎', () async {
      await repository.save(draft());
      await repository.writeCache(
        'cache-key-1',
        '缓存译文',
        provider: 'mlkit',
        sourceKind: TranslationSourceKind.machineCanonical,
      );
      await repository.deleteAll();
      expect(
        await repository.readCache('cache-key-1'),
        '缓存译文',
        reason: '缓存键与记录无关，清空历史不应牵连缓存',
      );
    });

    test('空库清空不报错', () async {
      expect(await repository.deleteAll(), 0);
      expect(await repository.count(), 0);
    });
  });

  group('历史分页', () {
    test('按时间倒序分页，序号稳定', () async {
      for (var index = 0; index < 5; index++) {
        await repository.save(draft(utteranceId: 'utt-$index', text: 'نص $index'));
      }
      expect(await repository.count(), 5);
      final firstPage = await repository.page(limit: 3);
      expect(firstPage, hasLength(3));
      final secondPage = await repository.page(limit: 3, offset: 3);
      expect(secondPage, hasLength(2));
      final sequences = <int>[
        for (final record in <UtteranceRecord>[...firstPage, ...secondPage]) record.displaySequence,
      ];
      expect(sequences.toSet(), hasLength(5));
      expect(sequences.reduce((a, b) => a > b ? a : b), 5);
    });
  });

  group('设置项', () {
    test('读写设置项', () async {
      expect(await database.readSetting('targetLanguage'), isNull);
      await database.writeSetting('targetLanguage', 'en');
      expect(await database.readSetting('targetLanguage'), 'en');
      await database.writeSetting('targetLanguage', 'zh-Hans');
      expect(await database.readSetting('targetLanguage'), 'zh-Hans');
    });
  });
}
