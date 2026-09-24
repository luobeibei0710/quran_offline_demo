/// 广播功能的依赖组装与生命周期。
///
/// 页面不得直接操作 ORT、下载模型或执行 SQL —— 全部依赖在这里创建一次，
/// 由应用级单实例持有。
///
/// 关键隔离点：本文件为匹配与语料只注入 [BroadcastQuranLibrary]
/// （全经 114 章 6236 节），只复用 ASR 模型侧资源（`vocab.json` 与 ONNX 模型），
/// **不加载**旧经文库
/// `quran.json` / `quran_ctc_tokens.json`。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../quran_offline/ctc_decoder.dart';
import '../quran_offline/ort_runner.dart';
import 'application/audio_pcm_dump.dart';
import 'application/broadcast_latency_trace.dart';
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
import 'translation/offline_translation_engine.dart';
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
    this.pcmDump,
    this.trace,
  });

  /// ONNX 模型资产键（复用 ASR 模型资源，不涉及旧经文）。
  static const String modelAssetKey =
      'assets/quran_offline/fastconformer_full_mixed_ort122.onnx';

  /// 麦克风 PCM 转储开关（`--dart-define=quran_dump_pcm=true`）。
  ///
  /// 默认 false：未显式开启时不写任何文件，收音与推理路径完全不变。
  static const bool dumpPcmEnabled = bool.fromEnvironment('quran_dump_pcm');

  /// 结构化时延埋点开关（`--dart-define=quran_latency_trace=true`）。
  static const bool latencyTraceEnabled = bool.fromEnvironment(
    'quran_latency_trace',
  );

  /// 目标语言偏好在设置表中的键。
  static const String languageSettingKey = 'broadcast_target_language';

  /// 全经语料库（114 章 6236 节）。
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
  final OfflineTranslationEngine engine;

  /// 译本目录（62 种语言，含许可与署名信息）。
  final BroadcastTranslationCatalog translationCatalog;

  /// 校订译本仓储（按语言查表，命中即返回权威人工译本）。
  final VerseTranslationRepository editions;

  /// 翻译协调器。
  final TranslationCoordinator translations;

  /// 会话控制器。
  final BroadcastSessionController session;

  /// 诊断用 PCM 转储；未开启时为 null。
  final AudioPcmDump? pcmDump;

  /// 结构化时延记录器；未开启时为 null。
  final BroadcastLatencyTrace? trace;

  Future<void>? _disposeFuture;
  final Set<Future<void>> _drainTasks = <Future<void>>{};

  /// 初始化全部依赖。
  ///
  /// @param loadModel 是否立即加载 ONNX 模型（测试可传 false）
  /// @param runner 自定义推理桥（测试注入用）
  /// @param audio 自定义音源（测试注入用）
  /// @param engine 自定义翻译引擎（测试注入用）
  /// @param database 已打开的数据库（测试注入内存库用）
  /// @param editions 校订译本仓储（测试可注入无译本实现以走机器翻译分支）
  /// @return 初始化完成的依赖集合
  static Future<BroadcastServices> bootstrap({
    bool loadModel = true,
    String modelAssetKey = BroadcastServices.modelAssetKey,
    OrtRunner? runner,
    AudioCaptureSource? audio,
    OfflineTranslationEngine? engine,
    BroadcastDatabase? database,
    QuranMatchService? matcher,
    VerseTranslationRepository? editions,
  }) async {
    final library = await BroadcastQuranLibrary.load();
    BroadcastDatabase? effectiveDatabase;
    OrtRunner? ortRunner;
    OfflineTranslationEngine? translationEngine;
    AudioPcmDump? pcmDump;
    BroadcastServices? services;
    try {
      effectiveDatabase = database ?? await BroadcastDatabase.open();
      final records = RecordRepository(effectiveDatabase.db);
      // 重启恢复：把被中断的翻译任务重新排队，不丢记录也不重复建记录。
      await records.recoverInterruptedJobs();

      ortRunner = runner ?? PlatformOrtRunner(blankId: library.blankId);
      if (loadModel) {
        await ortRunner.loadModel(modelAssetKey);
      }

      final transcriber = BroadcastTranscriber(
        runner: ortRunner,
        decoder: TextCtcDecoder(library.vocab, blankId: library.blankId),
        vocab: library.vocab,
      );
      final effectiveMatcher = matcher ?? QuranMatchService(library: library);
      translationEngine = engine ?? MlKitTranslationEngine();
      // 译本目录：注册可选语言（62 种）并提供权威译本查表。
      final translationCatalog = await BroadcastTranslationCatalog.load();
      final effectiveEditions =
          editions ??
          JsonVerseTranslationRepository(catalog: translationCatalog);
      final translations = TranslationCoordinator(
        engine: translationEngine,
        records: records,
        library: library,
        editions: effectiveEditions,
      );

      final savedLanguage = await effectiveDatabase.readSetting(
        languageSettingKey,
      );
      final targetLanguage =
          TargetLanguage.tryParse(savedLanguage) ?? TargetLanguage.chinese;

      if (dumpPcmEnabled) {
        pcmDump = AudioPcmDump(sampleRate: transcriber.sampleRate);
        await pcmDump.open();
      }
      final trace = latencyTraceEnabled ? BroadcastLatencyTrace() : null;

      final session = BroadcastSessionController(
        transcriber: transcriber,
        matcher: effectiveMatcher,
        records: records,
        translations: translations,
        audio:
            audio ??
            MicrophoneCaptureSource(
              sampleRate: transcriber.sampleRate,
              pcmDump: pcmDump,
            ),
        library: library,
        targetLanguage: targetLanguage,
        trace: trace,
      );

      services = BroadcastServices._(
        library: library,
        database: effectiveDatabase,
        records: records,
        runner: ortRunner,
        transcriber: transcriber,
        matcher: effectiveMatcher,
        engine: translationEngine,
        translationCatalog: translationCatalog,
        editions: effectiveEditions,
        translations: translations,
        session: session,
        pcmDump: pcmDump,
        trace: trace,
      );
      await services.session.refreshHistory();
      return services;
    } catch (error) {
      // Initialization may fail after the database or native model is open.
      // Release every resource already acquired, but keep the original error.
      Future<void> release(Future<void> Function() action) async {
        try {
          await action();
        } catch (cleanupError) {
          debugPrint('[Broadcast] 初始化清理失败：$cleanupError');
        }
      }

      if (services != null) {
        await release(services.dispose);
      } else {
        if (pcmDump != null) await release(pcmDump.close);
        if (translationEngine != null) await release(translationEngine.close);
        if (ortRunner != null) await release(ortRunner.dispose);
        if (effectiveDatabase != null) await release(effectiveDatabase.close);
      }
      rethrow;
    }
  }

  /// 持久化目标语言偏好。
  ///
  /// @param language 目标语言
  Future<void> persistTargetLanguage(TargetLanguage language) =>
      database.writeSetting(languageSettingKey, language.id);

  /// 释放资源。
  Future<void> dispose() => _disposeFuture ??= _disposeInternal();

  Future<void> _disposeInternal() async {
    Object? firstError;
    StackTrace? firstTrace;
    Future<void> release(Future<void> Function() action) async {
      try {
        await action();
      } catch (error, trace) {
        firstError ??= error;
        firstTrace ??= trace;
        debugPrint('[Broadcast] 资源释放失败：$error');
      }
    }

    await release(session.stop);
    await release(() => Future.wait(_drainTasks.toList()));
    await release(session.shutdown);
    if (pcmDump != null) await release(pcmDump!.close);
    await release(engine.close);
    await release(runner.dispose);
    await release(database.close);
    if (firstError != null) Error.throwWithStackTrace(firstError!, firstTrace!);
  }

  /// 在后台处理待办翻译任务（不阻塞界面）。
  Future<void> drainTranslations() {
    if (_disposeFuture != null) return Future<void>.value();
    final task = _drainTranslations();
    _drainTasks.add(task);
    unawaited(task.whenComplete(() => _drainTasks.remove(task)));
    return task;
  }

  Future<void> _drainTranslations() async {
    try {
      await translations.drain();
      await session.refreshHistory();
    } catch (error) {
      debugPrint('[Broadcast] 翻译任务处理失败：$error');
    }
  }
}
