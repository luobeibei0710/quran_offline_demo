/// 广播功能的依赖组装与生命周期。
///
/// 页面不得直接操作 ORT、下载模型或执行 SQL —— 全部依赖在这里创建一次，
/// 由应用级单实例持有。
///
/// 关键隔离点：本文件为匹配与语料只注入 [BroadcastQuranLibrary]（三章 41 节），
/// 只复用 ASR 模型侧资源（`vocab.json` 与 ONNX 模型），**不加载**旧经文库
/// `quran.json` / `quran_ctc_tokens.json`。
library;

import 'package:flutter/foundation.dart';

import '../quran_offline/ctc_decoder.dart';
import '../quran_offline/ort_runner.dart';
import 'application/broadcast_session_controller.dart';
import 'application/broadcast_transcriber.dart';
import 'application/microphone_source.dart';
import 'application/quran_match_service.dart';
import 'application/translation_coordinator.dart';
import 'data/app_database.dart';
import 'data/broadcast_corpus.dart';
import 'data/record_repository.dart';
import 'data/translation_catalog.dart';
import 'domain/utterance_record.dart';
import 'translation/mlkit_translation_engine.dart';
import 'translation/verse_translation_repository.dart';

/// 广播功能的运行时依赖集合。
class BroadcastServices {
  BroadcastServices._({
    required this.library,
    required this.database,
    required this.records,
    required this.runner,
    required this.transcriber,
    required this.matcher,
    required this.engine,
    required this.translationCatalog,
    required this.editions,
    required this.translations,
    required this.session,
  });

  /// ONNX 模型资产键（复用 ASR 模型资源，不涉及旧经文）。
  static const String modelAssetKey = 'assets/quran_offline/fastconformer_full_mixed_ort122.onnx';

  /// 目标语言偏好在设置表中的键。
  static const String languageSettingKey = 'broadcast_target_language';

  /// 独立三章语料库。
  final BroadcastQuranLibrary library;

  /// 本地数据库。
  final BroadcastDatabase database;

  /// 记录仓储。
  final RecordRepository records;

  /// 推理桥。
  final OrtRunner runner;

  /// 片段转写器。
  final BroadcastTranscriber transcriber;

  /// 匹配服务。
  final QuranMatchService matcher;

  /// 机器翻译引擎。
  final MlKitTranslationEngine engine;

  /// 译本目录（62 种语言，含许可与署名信息）。
  final BroadcastTranslationCatalog translationCatalog;

  /// 校订译本仓储（按语言查表，命中即返回权威人工译本）。
  final VerseTranslationRepository editions;

  /// 翻译协调器。
  final TranslationCoordinator translations;

  /// 会话控制器。
  final BroadcastSessionController session;

  /// 初始化全部依赖。
  ///
  /// @param loadModel 是否立即加载 ONNX 模型（测试可传 false）
  /// @param runner 自定义推理桥（测试注入用）
  /// @param audio 自定义音源（测试注入用）
  /// @param engine 自定义翻译引擎（测试注入用）
  /// @return 初始化完成的依赖集合
  static Future<BroadcastServices> bootstrap({
    bool loadModel = true,
    OrtRunner? runner,
    AudioCaptureSource? audio,
    MlKitTranslationEngine? engine,
  }) async {
    final library = await BroadcastQuranLibrary.load();
    final database = await BroadcastDatabase.open();
    final records = RecordRepository(database.db);
    // 重启恢复：把被中断的翻译任务重新排队，不丢记录也不重复建记录。
    await records.recoverInterruptedJobs();

    final ortRunner =
        runner ??
        PlatformOrtRunner(blankId: library.blankId);
    if (loadModel) {
      await ortRunner.loadModel(modelAssetKey);
    }

    final transcriber = BroadcastTranscriber(
      runner: ortRunner,
      decoder: TextCtcDecoder(library.vocab, blankId: library.blankId),
      vocab: library.vocab,
    );
    final matcher = QuranMatchService(library: library);
    final translationEngine = engine ?? MlKitTranslationEngine();
    // 译本目录：注册可选语言（62 种）并提供权威译本查表。
    final translationCatalog = await BroadcastTranslationCatalog.load();
    final editions = JsonVerseTranslationRepository(catalog: translationCatalog);
    final translations = TranslationCoordinator(
      engine: translationEngine,
      records: records,
      library: library,
      editions: editions,
    );

    final savedLanguage = await database.readSetting(languageSettingKey);
    final targetLanguage =
        TargetLanguage.tryParse(savedLanguage) ?? TargetLanguage.chinese;

    final session = BroadcastSessionController(
      transcriber: transcriber,
      matcher: matcher,
      records: records,
      translations: translations,
      audio: audio ?? MicrophoneCaptureSource(sampleRate: transcriber.sampleRate),
      library: library,
      targetLanguage: targetLanguage,
    );

    final services = BroadcastServices._(
      library: library,
      database: database,
      records: records,
      runner: ortRunner,
      transcriber: transcriber,
      matcher: matcher,
      engine: translationEngine,
      translationCatalog: translationCatalog,
      editions: editions,
      translations: translations,
      session: session,
    );
    await services.session.refreshHistory();
    return services;
  }

  /// 持久化目标语言偏好。
  ///
  /// @param language 目标语言
  Future<void> persistTargetLanguage(TargetLanguage language) =>
      database.writeSetting(languageSettingKey, language.id);

  /// 释放资源。
  Future<void> dispose() async {
    session.dispose();
    await engine.close();
    await runner.dispose();
    await database.close();
  }

  /// 在后台处理待办翻译任务（不阻塞界面）。
  Future<void> drainTranslations() async {
    try {
      await translations.drain();
      await session.refreshHistory();
    } catch (error) {
      debugPrint('[Broadcast] 翻译任务处理失败：$error');
    }
  }
}
