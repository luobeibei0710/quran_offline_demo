/// 广播功能的本地数据库：建库、版本迁移与表结构。
///
/// 设计要点（与实施方案 §7 一致）：
///
/// - 三类文本各自快照落库，详情页不重新计算，历史不会悄悄变化；
/// - `utterance_records` 用 `(session_id, utterance_id, revision)` 作幂等键，
///   同一音频片段多次回调只更新同一条记录；
/// - `display_sequence` 是独立的稳定展示序号，删除记录后不改号；
/// - `record_translations` 用 `(record_id, revision, target_language, provider)`
///   唯一，迟到译文无法覆盖不同修订或不同语言的记录；
/// - 翻译任务与记录同事务写入，重启可恢复。
///
/// 数据库文件放在应用支持目录，不放临时缓存目录；异常时**不**自动清库。
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

/// 广播数据库的建库与迁移。
class BroadcastDatabase {
  BroadcastDatabase._(this.db, this.path);

  /// 当前 schema 版本。
  ///
  /// 每次升级都必须新增一个幂等的迁移步骤，并同步更新迁移测试中的断言。
  static const int schemaVersion = 1;

  /// 数据库文件名。
  static const String fileName = 'broadcast_quran.db';

  /// 已打开的数据库句柄。
  final Database db;

  /// 数据库文件路径（内存库时为 [inMemoryDatabasePath]）。
  final String path;

  /// 打开（必要时创建）数据库。
  ///
  /// @param path 显式路径；省略时使用应用支持目录下的 [fileName]
  /// @param factory 数据库工厂；测试可注入内存实现
  /// @return 已打开的数据库
  Future<Database> get database async => db;

  static Future<BroadcastDatabase> open({String? path, DatabaseFactory? factory}) async {
    final effectiveFactory = factory ?? databaseFactory;
    final target = path ?? await _defaultPath();
    final handle = await effectiveFactory.openDatabase(
      target,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onConfigure: (db) async {
          // 外键级联删除：删除记录时一并清理匹配、指标、译文与任务。
          await db.execute('PRAGMA foreign_keys = ON');
        },
        onCreate: (db, version) async {
          await createSchema(db);
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          await migrate(db, from: oldVersion, to: newVersion);
        },
      ),
    );
    return BroadcastDatabase._(handle, target);
  }

  /// 关闭数据库。
  Future<void> close() => db.close();

  /// 建库：创建全部表与索引。
  ///
  /// 必须是幂等的，且得到的结果等同于「所有迁移依次执行后的最终形态」。
  ///
  /// @param db 数据库句柄
  static Future<void> createSchema(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS recognition_sessions (
        id TEXT PRIMARY KEY,
        started_at INTEGER NOT NULL,
        ended_at INTEGER,
        target_language TEXT NOT NULL,
        status TEXT NOT NULL,
        model_version TEXT,
        config_version TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS utterance_records (
        id TEXT PRIMARY KEY,
        display_sequence INTEGER NOT NULL UNIQUE,
        session_id TEXT NOT NULL,
        utterance_id TEXT NOT NULL,
        revision INTEGER NOT NULL,
        start_sample INTEGER NOT NULL,
        end_sample INTEGER NOT NULL,
        sample_rate INTEGER NOT NULL,
        boundary_reason TEXT NOT NULL,
        raw_asr_text TEXT NOT NULL,
        source_language TEXT NOT NULL,
        target_language TEXT NOT NULL,
        match_status TEXT NOT NULL,
        scope TEXT NOT NULL,
        processing_ms TEXT,
        matcher_evidence TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        UNIQUE (session_id, utterance_id, revision)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS record_matches (
        record_id TEXT NOT NULL,
        ordinal INTEGER NOT NULL,
        surah INTEGER NOT NULL,
        ayah INTEGER NOT NULL,
        word_start INTEGER,
        word_end INTEGER,
        canonical_text TEXT NOT NULL,
        matched_text TEXT NOT NULL,
        corpus_version TEXT NOT NULL,
        PRIMARY KEY (record_id, ordinal),
        FOREIGN KEY (record_id) REFERENCES utterance_records (id) ON DELETE CASCADE
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS record_metrics (
        record_id TEXT NOT NULL,
        revision INTEGER NOT NULL,
        metric_scope TEXT NOT NULL,
        precision REAL,
        recall REAL,
        f1 REAL,
        strict_wer REAL,
        substitutions INTEGER,
        deletions INTEGER,
        insertions INTEGER,
        reference_words INTEGER,
        hypothesis_words INTEGER,
        match_count INTEGER,
        near_count INTEGER,
        mismatch_count INTEGER,
        missing_count INTEGER,
        extra_count INTEGER,
        alignment_json TEXT,
        normalization_version TEXT NOT NULL,
        PRIMARY KEY (record_id, revision),
        FOREIGN KEY (record_id) REFERENCES utterance_records (id) ON DELETE CASCADE
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS record_translations (
        id TEXT PRIMARY KEY,
        record_id TEXT NOT NULL,
        revision INTEGER NOT NULL,
        target_language TEXT NOT NULL,
        provider TEXT NOT NULL,
        source_kind TEXT NOT NULL,
        edition_id TEXT,
        engine_id TEXT,
        source_hash TEXT NOT NULL,
        input_scope TEXT NOT NULL,
        text TEXT NOT NULL,
        status TEXT NOT NULL,
        error_code TEXT,
        elapsed_ms INTEGER,
        created_at INTEGER NOT NULL,
        UNIQUE (record_id, revision, target_language, provider),
        FOREIGN KEY (record_id) REFERENCES utterance_records (id) ON DELETE CASCADE
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS translation_jobs (
        id TEXT PRIMARY KEY,
        record_id TEXT NOT NULL,
        revision INTEGER NOT NULL,
        target_language TEXT NOT NULL,
        provider TEXT NOT NULL,
        source_hash TEXT NOT NULL,
        state TEXT NOT NULL,
        attempt_count INTEGER NOT NULL DEFAULT 0,
        last_error TEXT,
        created_at INTEGER NOT NULL,
        UNIQUE (record_id, revision, target_language, provider),
        FOREIGN KEY (record_id) REFERENCES utterance_records (id) ON DELETE CASCADE
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS translation_cache (
        cache_key TEXT PRIMARY KEY,
        text TEXT NOT NULL,
        provider TEXT NOT NULL,
        engine_id TEXT,
        source_kind TEXT NOT NULL,
        last_used_at INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_records_created ON utterance_records (created_at DESC)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_records_session ON utterance_records (session_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_jobs_record ON translation_jobs (record_id, revision)',
    );
  }

  /// 迁移：从 [from] 升到 [to]。
  ///
  /// 每一步都必须能重复执行（先探测再改），避免「先建最新库再回填版本号」
  /// 这类场景撞上已存在的列。
  ///
  /// @param db 数据库句柄
  /// @param from 旧版本
  /// @param to 目标版本
  static Future<void> migrate(DatabaseExecutor db, {required int from, required int to}) async {
    for (var version = from + 1; version <= to; version++) {
      switch (version) {
        case 1:
          await createSchema(db);
        default:
          throw StateError('缺少 v$version 的迁移步骤');
      }
    }
  }

  /// 读取某项设置。
  ///
  /// @param key 设置键
  /// @return 设置值；不存在时返回 null
  Future<String?> readSetting(String key) async {
    final rows = await db.query('settings', where: 'key = ?', whereArgs: <Object?>[key], limit: 1);
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }

  /// 写入某项设置。
  ///
  /// @param key 设置键
  /// @param value 设置值
  Future<void> writeSetting(String key, String value) async {
    await db.insert('settings', <String, Object?>{
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<String> _defaultPath() async {
    final directory = await getApplicationSupportDirectory();
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return '${directory.path}${Platform.pathSeparator}$fileName';
  }
}
