/// 记录仓储：三类文本快照的事务保存、历史分页、详情、删除与翻译任务恢复。
///
/// 一致性规则（与实施方案 §7.2 一致）：
///
/// - 记录、匹配、指标与翻译任务在**同一事务**内写入；写成功才让历史计数 +1；
/// - 业务去重键 `(sessionId, utteranceId, revision)`，同一音频片段反复回调
///   只更新同一条记录；同一经文在另一时间出现时 utteranceId 不同，生成新记录；
/// - 删除记录级联删除匹配、指标、译文与任务，迟到译文不得复活记录；
/// - 翻译任务失败不丢记录，重启时把残留 running 恢复为 pending 再重试。
library;

import 'package:sqflite/sqflite.dart';

import '../domain/utterance_record.dart';

/// 保存一条记录所需的全量输入。
class RecordDraft {
  /// 构造草稿。
  ///
  /// @param sessionId 会话标识
  /// @param utteranceId 句段标识（同一音频片段复用）
  /// @param startSample 起始采样
  /// @param endSample 结束采样
  /// @param sampleRate 采样率
  /// @param boundaryReason 结束原因
  /// @param rawAsrText 实际 ASR 转写
  /// @param targetLanguage 创建时冻结的目标语言
  /// @param matchStatus 匹配状态
  /// @param scope 覆盖范围形态
  /// @param matches 匹配经文
  /// @param metrics 指标快照
  /// @param job 需要入队的翻译任务
  /// @param processingMs 各阶段耗时（毫秒 JSON）
  /// @param matcherEvidenceJson 诊断证据 JSON
  /// @param revision 修订号，默认 1
  const RecordDraft({
    required this.sessionId,
    required this.utteranceId,
    required this.startSample,
    required this.endSample,
    required this.sampleRate,
    required this.boundaryReason,
    required this.rawAsrText,
    required this.targetLanguage,
    required this.matchStatus,
    required this.scope,
    this.matches = const <MatchedVerse>[],
    this.metrics,
    this.job,
    this.processingMs,
    this.matcherEvidenceJson,
    this.revision = 1,
  });

  /// 会话标识。
  final String sessionId;

  /// 句段标识。
  final String utteranceId;

  /// 起始采样。
  final int startSample;

  /// 结束采样。
  final int endSample;

  /// 采样率。
  final int sampleRate;

  /// 结束原因。
  final BoundaryReason boundaryReason;

  /// 实际 ASR 转写。
  final String rawAsrText;

  /// 目标语言。
  final TargetLanguage targetLanguage;

  /// 匹配状态。
  final MatchStatus matchStatus;

  /// 覆盖范围形态。
  final RecordScope scope;

  /// 匹配经文。
  final List<MatchedVerse> matches;

  /// 指标快照。
  final RecordMetrics? metrics;

  /// 待入队的翻译任务。
  final TranslationJob? job;

  /// 各阶段耗时 JSON。
  final String? processingMs;

  /// 诊断证据 JSON。
  final String? matcherEvidenceJson;

  /// 修订号。
  final int revision;
}

/// 记录仓储。
class RecordRepository {
  /// 构造仓储。
  ///
  /// @param db 已打开的数据库句柄
  RecordRepository(this.db);

  /// 数据库句柄。
  final Database db;

  /// 默认分页大小。
  static const int defaultPageSize = 50;

  /// 展示序号计数器在 `settings` 表中的键。
  static const String _sequenceCounterKey = 'display_sequence_counter';

  /// 事务保存一条记录（幂等）。
  ///
  /// @param draft 保存内容
  /// @return 落库后的完整记录（含稳定序号）
  Future<UtteranceRecord> save(RecordDraft draft) async {
    final now = DateTime.now().toUtc();
    late String recordId;
    await db.transaction((txn) async {
      final existing = await txn.query(
        'utterance_records',
        columns: <String>['id'],
        where: 'session_id = ? AND utterance_id = ? AND revision = ?',
        whereArgs: <Object?>[draft.sessionId, draft.utteranceId, draft.revision],
        limit: 1,
      );
      final values = <String, Object?>{
        'session_id': draft.sessionId,
        'utterance_id': draft.utteranceId,
        'revision': draft.revision,
        'start_sample': draft.startSample,
        'end_sample': draft.endSample,
        'sample_rate': draft.sampleRate,
        'boundary_reason': draft.boundaryReason.wireName,
        'raw_asr_text': draft.rawAsrText,
        'source_language': broadcastSourceLanguage,
        'target_language': draft.targetLanguage.id,
        'match_status': draft.matchStatus.name,
        'scope': draft.scope.wireName,
        'processing_ms': draft.processingMs,
        'matcher_evidence': draft.matcherEvidenceJson,
        'updated_at': now.millisecondsSinceEpoch,
      };

      if (existing.isEmpty) {
        recordId = UtteranceRecord.newId();
        // 序号用独立计数器分配：删除记录后不回填空洞，也不会回收旧号。
        final counter = await txn.query(
          'settings',
          columns: <String>['value'],
          where: 'key = ?',
          whereArgs: <Object?>[_sequenceCounterKey],
          limit: 1,
        );
        final next = (counter.isEmpty ? 0 : int.tryParse('${counter.first['value']}') ?? 0) + 1;
        await txn.insert('settings', <String, Object?>{
          'key': _sequenceCounterKey,
          'value': '$next',
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        values['id'] = recordId;
        values['display_sequence'] = next;
        values['created_at'] = now.millisecondsSinceEpoch;
        await txn.insert('utterance_records', values);
      } else {
        recordId = existing.first['id']! as String;
        await txn.update(
          'utterance_records',
          values,
          where: 'id = ?',
          whereArgs: <Object?>[recordId],
        );
      }

      await txn.delete('record_matches', where: 'record_id = ?', whereArgs: <Object?>[recordId]);
      for (final match in draft.matches) {
        await txn.insert('record_matches', <String, Object?>{
          'record_id': recordId,
          'ordinal': match.ordinal,
          'surah': match.surah,
          'ayah': match.ayah,
          'word_start': match.wordStart,
          'word_end': match.wordEnd,
          'canonical_text': match.canonicalTextSnapshot,
          'matched_text': match.matchedTextSnapshot,
          'corpus_version': match.corpusVersion,
        });
      }

      final metrics = draft.metrics;
      if (metrics != null) {
        await txn.insert('record_metrics', <String, Object?>{
          'record_id': recordId,
          'revision': draft.revision,
          'metric_scope': metrics.metricScope,
          'precision': metrics.precision,
          'recall': metrics.recall,
          'f1': metrics.f1,
          'strict_wer': metrics.strictWer,
          'substitutions': metrics.substitutions,
          'deletions': metrics.deletions,
          'insertions': metrics.insertions,
          'reference_words': metrics.referenceWords,
          'hypothesis_words': metrics.hypothesisWords,
          'match_count': metrics.matchCount,
          'near_count': metrics.nearCount,
          'mismatch_count': metrics.mismatchCount,
          'missing_count': metrics.missingCount,
          'extra_count': metrics.extraCount,
          'alignment_json': metrics.alignmentJson,
          'normalization_version': metrics.normalizationVersion,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }

      final job = draft.job;
      if (job != null) {
        await txn.insert('translation_jobs', <String, Object?>{
          'id': job.id,
          'record_id': recordId,
          'revision': job.revision,
          'target_language': job.targetLanguage.id,
          'provider': job.provider,
          'source_hash': job.sourceHash,
          'state': job.state.wireName,
          'attempt_count': job.attemptCount,
          'last_error': job.lastError,
          'created_at': job.createdAt.millisecondsSinceEpoch,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
    return (await byId(recordId))!;
  }

  /// 历史总数。
  ///
  /// @return 记录条数
  Future<int> count() async {
    final rows = await db.rawQuery('SELECT COUNT(*) AS total FROM utterance_records');
    return (rows.first['total'] as int?) ?? 0;
  }

  /// 按时间倒序分页。
  ///
  /// @param limit 每页条数
  /// @param offset 跳过条数
  /// @return 记录列表（含匹配、指标与译文）
  Future<List<UtteranceRecord>> page({int limit = defaultPageSize, int offset = 0}) async {
    final rows = await db.query(
      'utterance_records',
      orderBy: 'created_at DESC, display_sequence DESC',
      limit: limit,
      offset: offset,
    );
    return _hydrate(rows);
  }

  /// 按主键取记录。
  ///
  /// @param id 业务标识
  /// @return 记录；不存在时返回 null
  Future<UtteranceRecord?> byId(String id) async {
    final rows = await db.query(
      'utterance_records',
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    final records = await _hydrate(rows);
    return records.isEmpty ? null : records.first;
  }

  /// 删除一条记录（级联删除关联数据）。
  ///
  /// @param id 业务标识
  /// @return 是否真的删除了记录
  Future<bool> delete(String id) async {
    final removed = await db.delete(
      'utterance_records',
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
    return removed > 0;
  }

  /// 清空全部历史记录。
  ///
  /// 与单条删除的区别：这是「清空」语义，展示序号计数器一并重置，新记录重新从
  /// `#000001` 开始；单条删除仍不回收序号，两者互不影响。
  ///
  /// 级联清理匹配、指标、译文与翻译任务（外键 ON DELETE CASCADE）。
  /// **翻译缓存不清理** —— 缓存键只含输入文本与语料/引擎信息，与记录无关，
  /// 保留它可以让相同经文重新识别时直接命中，避免重复调用引擎。
  ///
  /// 调用方必须自行确认「识别中不得清空」（见实施方案 §3.2）。
  ///
  /// @return 被删除的记录数
  Future<int> deleteAll() async {
    return db.transaction((txn) async {
      final removed = await txn.delete('utterance_records');
      await txn.delete(
        'settings',
        where: 'key = ?',
        whereArgs: <Object?>[_sequenceCounterKey],
      );
      return removed;
    });
  }

  /// 写入或更新一条译文（迟到结果的安全入口）。
  ///
  /// 只有在记录仍然存在、且修订号与目标语言与入参一致时才会落库；否则视为
  /// 过期结果直接丢弃，既不覆盖新版本，也不会复活已删除的记录。
  ///
  /// @param translation 译文快照
  /// @return 是否已写入
  Future<bool> saveTranslation(RecordTranslation translation) async {
    final rows = await db.query(
      'utterance_records',
      columns: <String>['revision', 'target_language'],
      where: 'id = ?',
      whereArgs: <Object?>[translation.recordId],
      limit: 1,
    );
    if (rows.isEmpty) return false;
    final revision = rows.first['revision'] as int?;
    final language = rows.first['target_language'] as String?;
    if (revision != translation.revision || language != translation.targetLanguage.id) {
      return false;
    }
    await db.insert('record_translations', <String, Object?>{
      'id': translation.id,
      'record_id': translation.recordId,
      'revision': translation.revision,
      'target_language': translation.targetLanguage.id,
      'provider': translation.provider,
      'source_kind': translation.sourceKind.wireName,
      'edition_id': translation.editionId,
      'engine_id': translation.engineId,
      'source_hash': translation.sourceHash,
      'input_scope': translation.inputScope,
      'text': translation.text,
      'status': translation.status.wireName,
      'error_code': translation.errorCode,
      'elapsed_ms': translation.elapsedMs,
      'created_at': translation.createdAt.millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    return true;
  }

  /// 取待执行的翻译任务（按创建顺序）。
  ///
  /// @param limit 最多返回条数
  /// @return 任务列表
  Future<List<TranslationJob>> pendingJobs({int limit = 20}) async {
    final rows = await db.query(
      'translation_jobs',
      where: 'state IN (?, ?)',
      whereArgs: <Object?>[TranslationJobState.pending.wireName, TranslationJobState.running.wireName],
      orderBy: 'created_at ASC',
      limit: limit,
    );
    return <TranslationJob>[for (final row in rows) _jobFromRow(row)];
  }

  /// 恢复被中断的任务：把残留 `running` 重置为 `pending`。
  ///
  /// 幂等：没有 running 任务时不做任何修改。
  ///
  /// @return 被重置的任务数
  Future<int> recoverInterruptedJobs() async {
    final affected = await db.update(
      'translation_jobs',
      <String, Object?>{'state': TranslationJobState.pending.wireName},
      where: 'state = ?',
      whereArgs: <Object?>[TranslationJobState.running.wireName],
    );
    await db.update(
      'record_translations',
      <String, Object?>{'status': TranslationStatus.pending.wireName},
      where: 'status = ?',
      whereArgs: <Object?>[TranslationStatus.running.wireName],
    );
    return affected;
  }

  /// 更新任务状态。
  ///
  /// @param jobId 任务主键
  /// @param state 新状态
  /// @param error 失败原因
  /// @param incrementAttempt 是否让尝试次数 +1
  Future<void> updateJobState(
    String jobId,
    TranslationJobState state, {
    String? error,
    bool incrementAttempt = false,
  }) async {
    await db.rawUpdate(
      'UPDATE translation_jobs SET state = ?, last_error = ?'
      '${incrementAttempt ? ', attempt_count = attempt_count + 1' : ''} WHERE id = ?',
      <Object?>[state.wireName, error, jobId],
    );
  }

  /// 把某条记录的失败任务重新排队（同记录重试，不新建历史）。
  ///
  /// @param recordId 业务标识
  /// @param language 目标语言
  /// @return 被重置的任务数
  Future<int> requeueJobs(String recordId, TargetLanguage language) async {
    return db.update(
      'translation_jobs',
      <String, Object?>{'state': TranslationJobState.pending.wireName, 'last_error': null},
      where: 'record_id = ? AND target_language = ?',
      whereArgs: <Object?>[recordId, language.id],
    );
  }

  /// 读取翻译缓存。
  ///
  /// @param cacheKey 缓存键
  /// @return 命中文本；未命中时返回 null
  Future<String?> readCache(String cacheKey) async {
    final rows = await db.query(
      'translation_cache',
      where: 'cache_key = ?',
      whereArgs: <Object?>[cacheKey],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    await db.update(
      'translation_cache',
      <String, Object?>{'last_used_at': DateTime.now().toUtc().millisecondsSinceEpoch},
      where: 'cache_key = ?',
      whereArgs: <Object?>[cacheKey],
    );
    return rows.first['text'] as String?;
  }

  /// 写入翻译缓存。
  ///
  /// @param cacheKey 缓存键（含输入哈希、语料版本、语言、提供方与预处理版本）
  /// @param text 译文
  /// @param provider 提供方
  /// @param sourceKind 来源种类
  /// @param engineId 引擎标识与版本
  Future<void> writeCache(
    String cacheKey,
    String text, {
    required String provider,
    required TranslationSourceKind sourceKind,
    String? engineId,
  }) async {
    await db.insert('translation_cache', <String, Object?>{
      'cache_key': cacheKey,
      'text': text,
      'provider': provider,
      'engine_id': engineId,
      'source_kind': sourceKind.wireName,
      'last_used_at': DateTime.now().toUtc().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 批量补全匹配、指标与译文，避免分页查询时的逐条查询。
  Future<List<UtteranceRecord>> _hydrate(List<Map<String, Object?>> rows) async {
    if (rows.isEmpty) return const <UtteranceRecord>[];
    final ids = <String>[for (final row in rows) row['id']! as String];
    final placeholders = List<String>.filled(ids.length, '?').join(', ');

    final matchRows = await db.query(
      'record_matches',
      where: 'record_id IN ($placeholders)',
      whereArgs: ids,
      orderBy: 'record_id ASC, ordinal ASC',
    );
    final metricRows = await db.query(
      'record_metrics',
      where: 'record_id IN ($placeholders)',
      whereArgs: ids,
    );
    final translationRows = await db.query(
      'record_translations',
      where: 'record_id IN ($placeholders)',
      whereArgs: ids,
      orderBy: 'created_at ASC',
    );

    final matches = <String, List<MatchedVerse>>{};
    for (final row in matchRows) {
      matches.putIfAbsent(row['record_id']! as String, () => <MatchedVerse>[]).add(
        MatchedVerse(
          ordinal: row['ordinal']! as int,
          surah: row['surah']! as int,
          ayah: row['ayah']! as int,
          wordStart: row['word_start'] as int?,
          wordEnd: row['word_end'] as int?,
          canonicalTextSnapshot: '${row['canonical_text']}',
          matchedTextSnapshot: '${row['matched_text']}',
          corpusVersion: '${row['corpus_version']}',
        ),
      );
    }
    final metrics = <String, RecordMetrics>{
      for (final row in metricRows) row['record_id']! as String: _metricsFromRow(row),
    };
    final translations = <String, List<RecordTranslation>>{};
    for (final row in translationRows) {
      translations
          .putIfAbsent(row['record_id']! as String, () => <RecordTranslation>[])
          .add(_translationFromRow(row));
    }

    return <UtteranceRecord>[
      for (final row in rows)
        UtteranceRecord(
          id: row['id']! as String,
          displaySequence: row['display_sequence']! as int,
          sessionId: '${row['session_id']}',
          utteranceId: '${row['utterance_id']}',
          revision: row['revision']! as int,
          startSample: row['start_sample']! as int,
          endSample: row['end_sample']! as int,
          sampleRate: row['sample_rate']! as int,
          boundaryReason: _boundaryReason(row['boundary_reason'] as String?),
          rawAsrText: '${row['raw_asr_text']}',
          targetLanguage:
              TargetLanguage.tryParse(row['target_language'] as String?) ?? TargetLanguage.chinese,
          matchStatus: _matchStatus(row['match_status'] as String?),
          scope: _scope(row['scope'] as String?),
          createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at']! as int, isUtc: true),
          updatedAt: DateTime.fromMillisecondsSinceEpoch(row['updated_at']! as int, isUtc: true),
          matches: matches[row['id']] ?? const <MatchedVerse>[],
          metrics: metrics[row['id']],
          translations: translations[row['id']] ?? const <RecordTranslation>[],
          processingMs: row['processing_ms'] as String?,
          matcherEvidenceJson: row['matcher_evidence'] as String?,
        ),
    ];
  }

  static RecordMetrics _metricsFromRow(Map<String, Object?> row) => RecordMetrics(
    metricScope: '${row['metric_scope']}',
    precision: row['precision'] as double?,
    recall: row['recall'] as double?,
    f1: row['f1'] as double?,
    strictWer: row['strict_wer'] as double?,
    substitutions: row['substitutions'] as int?,
    deletions: row['deletions'] as int?,
    insertions: row['insertions'] as int?,
    referenceWords: row['reference_words'] as int?,
    hypothesisWords: row['hypothesis_words'] as int?,
    matchCount: row['match_count'] as int?,
    nearCount: row['near_count'] as int?,
    mismatchCount: row['mismatch_count'] as int?,
    missingCount: row['missing_count'] as int?,
    extraCount: row['extra_count'] as int?,
    normalizationVersion: '${row['normalization_version']}',
    alignmentJson: row['alignment_json'] as String?,
  );

  static RecordTranslation _translationFromRow(Map<String, Object?> row) => RecordTranslation(
    id: '${row['id']}',
    recordId: '${row['record_id']}',
    revision: row['revision']! as int,
    targetLanguage:
        TargetLanguage.tryParse(row['target_language'] as String?) ?? TargetLanguage.chinese,
    provider: '${row['provider']}',
    sourceKind: _sourceKind(row['source_kind'] as String?),
    sourceHash: '${row['source_hash']}',
    inputScope: '${row['input_scope']}',
    text: '${row['text']}',
    status: _translationStatus(row['status'] as String?),
    createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at']! as int, isUtc: true),
    editionId: row['edition_id'] as String?,
    engineId: row['engine_id'] as String?,
    errorCode: row['error_code'] as String?,
    elapsedMs: row['elapsed_ms'] as int?,
  );

  static TranslationJob _jobFromRow(Map<String, Object?> row) => TranslationJob(
    id: '${row['id']}',
    recordId: '${row['record_id']}',
    revision: row['revision']! as int,
    targetLanguage:
        TargetLanguage.tryParse(row['target_language'] as String?) ?? TargetLanguage.chinese,
    provider: '${row['provider']}',
    sourceHash: '${row['source_hash']}',
    state: _jobState(row['state'] as String?),
    attemptCount: (row['attempt_count'] as int?) ?? 0,
    createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at']! as int, isUtc: true),
    lastError: row['last_error'] as String?,
  );

  static MatchStatus _matchStatus(String? value) => MatchStatus.values.firstWhere(
    (item) => item.name == value,
    orElse: () => MatchStatus.unmatched,
  );

  static RecordScope _scope(String? value) => RecordScope.values.firstWhere(
    (item) => item.wireName == value,
    orElse: () => RecordScope.unknown,
  );

  static BoundaryReason _boundaryReason(String? value) => BoundaryReason.values.firstWhere(
    (item) => item.wireName == value,
    orElse: () => BoundaryReason.unknown,
  );

  static TranslationSourceKind _sourceKind(String? value) => TranslationSourceKind.values.firstWhere(
    (item) => item.wireName == value,
    orElse: () => TranslationSourceKind.machineAsr,
  );

  static TranslationStatus _translationStatus(String? value) => TranslationStatus.values.firstWhere(
    (item) => item.wireName == value,
    orElse: () => TranslationStatus.pending,
  );

  static TranslationJobState _jobState(String? value) => TranslationJobState.values.firstWhere(
    (item) => item.wireName == value,
    orElse: () => TranslationJobState.pending,
  );
}
