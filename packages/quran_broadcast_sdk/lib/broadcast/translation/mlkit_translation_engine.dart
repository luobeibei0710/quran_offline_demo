/// ML Kit 端侧翻译适配器（本项目唯一的机器翻译引擎）。
///
/// 平台事实与限制（据 Google 官方文档，2026-09 核对）：
///
/// - ML Kit Translation 只提供**动态下载**路径，语言包不能随安装包分发；
/// - 非英语语言之间经英语中转，因此 阿→中 需要同时准备阿拉伯语、英语与中文
///   三个语言包，中英质量必须**分别**评估；
/// - 插件是社区维护的 Flutter 桥接包（本仓库锁定 `google_mlkit_translation`
///   0.14.0），其原生 podspec 要求 iOS 15.5，Android 侧 minSdk 26 已满足。
///
/// 本适配器不做云降级：缺包时抛出分类异常，由上层显示「缺少离线语言包」并
/// 支持同一记录重试。
library;

import 'dart:async';

import 'package:flutter/services.dart' show PlatformException;
import 'package:google_mlkit_translation/google_mlkit_translation.dart';

import '../domain/utterance_record.dart';
import 'offline_translation_engine.dart';

/// ML Kit 翻译适配器。
class MlKitTranslationEngine implements OfflineTranslationEngine {
  /// 构造适配器。
  ///
  /// @param engineVersion 桥接包与原生 SDK 的可见版本，写入译文来源
  MlKitTranslationEngine({this.engineVersion = 'google_mlkit_translation/0.14.0'});

  /// 引擎可见版本。
  final String engineVersion;

  /// 缓存的翻译器实例（按目标语言）。
  final Map<TargetLanguage, OnDeviceTranslator> _translators = <TargetLanguage, OnDeviceTranslator>{};

  /// 已确认就绪的语言。
  final Set<TargetLanguage> _ready = <TargetLanguage>{};

  /// 模型管理器：保持为长生命周期实例。
  ///
  /// 注意：仅持有字段**不足以避免** `Model manager deallocated during download`。
  /// `google_mlkit_translation` 0.14.0 的 iOS 实现里，`manageModel` 每次调用都
  /// `let manager = GenericModelManager()` 并覆盖插件字段，旧实例随即被 ARC 释放；
  /// 只要上一次下载/查询还在进行中，原生就会返回该错误。Dart 侧持有的只是代理，
  /// 管不到原生实例的生命周期，因此还必须让所有原生调用**串行**（见 [_serial]）。
  OnDeviceTranslatorModelManager? _modelManager;
  OnDeviceTranslatorModelManager get _manager =>
      _modelManager ??= OnDeviceTranslatorModelManager();

  /// 串行锁尾：所有原生 manager 调用排在这条 Future 链上，保证同一时刻只有一个
  /// 原生 manager 存活并处于活动状态。
  Future<void> _tail = Future<void>.value();

  /// 正在下载的语言（BCP-47）；非空时 [statusFor] 不再触碰原生，避免把正在下载的
  /// manager 挤掉。
  final Set<String> _pendingBcp = <String>{};

  int _generation = 1;

  /// 把一次原生 manager 调用排到串行链上执行。
  ///
  /// @param action 原生调用
  /// @return 调用结果
  Future<T> _serial<T>(Future<T> Function() action) {
    final previous = _tail;
    final completer = Completer<void>();
    _tail = completer.future;
    return previous.catchError((Object _) {}).then((_) async {
      try {
        return await action();
      } finally {
        completer.complete();
      }
    });
  }

  @override
  String get engineId => engineVersion;

  @override
  int get generation => _generation;

  /// 应用语言标识到 ML Kit 语言的映射。
  ///
  /// 译本目录有 62 种语言，而 ML Kit 端侧翻译只覆盖其中一部分，因此这里是**显式
  /// 白名单**：未列出的语言查表翻译照常可用（权威译本），只是「未匹配片段」的
  /// 机器翻译不可用，界面要如实提示而不是假装能翻。
  static const Map<String, TranslateLanguage> _mlKitLanguages = <String, TranslateLanguage>{
    'albanian': TranslateLanguage.albanian,
    'bengali': TranslateLanguage.bengali,
    'chinese': TranslateLanguage.chinese,
    'croatian': TranslateLanguage.croatian,
    'dutch': TranslateLanguage.dutch,
    'english': TranslateLanguage.english,
    'french': TranslateLanguage.french,
    'german': TranslateLanguage.german,
    'gujarati': TranslateLanguage.gujarati,
    'hindi': TranslateLanguage.hindi,
    'indonesian': TranslateLanguage.indonesian,
    'italian': TranslateLanguage.italian,
    'japanese': TranslateLanguage.japanese,
    'kannada': TranslateLanguage.kannada,
    'korean': TranslateLanguage.korean,
    'lithuanian': TranslateLanguage.lithuanian,
    'macedonian': TranslateLanguage.macedonian,
    'malay': TranslateLanguage.malay,
    'persian': TranslateLanguage.persian,
    'portuguese': TranslateLanguage.portuguese,
    'romanian': TranslateLanguage.romanian,
    'russian': TranslateLanguage.russian,
    'spanish': TranslateLanguage.spanish,
    'swahili': TranslateLanguage.swahili,
    'swedish': TranslateLanguage.swedish,
    'tagalog': TranslateLanguage.tagalog,
    'tamil': TranslateLanguage.tamil,
    'telugu': TranslateLanguage.telugu,
    'thai': TranslateLanguage.thai,
    'turkish': TranslateLanguage.turkish,
    'ukrainian': TranslateLanguage.ukrainian,
    'urdu': TranslateLanguage.urdu,
    'vietnamese': TranslateLanguage.vietnamese,
  };

  /// 查询语言是否支持端侧机器翻译。
  ///
  /// @param language 应用内语言
  /// @return ML Kit 语言；不支持时返回 null
  static TranslateLanguage? mlKitLanguage(TargetLanguage language) =>
      _mlKitLanguages[language.id];

  /// 该语言是否支持端侧机器翻译（用于界面提示）。
  ///
  /// @param language 应用内语言
  /// @return 是否支持
  static bool supportsMachineTranslation(TargetLanguage language) =>
      _mlKitLanguages.containsKey(language.id);

  /// 目标语言所需的全部语言包。
  ///
  /// 非英语语言之间经英语中转，因此英语目标只需阿拉伯语 + 英语；其他目标在
  /// 需要时还要额外的中转包（ML Kit 自行处理中转，这里只声明必需的阿拉伯语、
  /// 英语与目标语言本身）。
  ///
  /// @param target 目标语言
  /// @return 需要准备的 ML Kit 语言；不支持时返回空列表
  static List<TranslateLanguage> requiredModels(TargetLanguage target) {
    final language = mlKitLanguage(target);
    if (language == null) return const <TranslateLanguage>[];
    if (language == TranslateLanguage.english) {
      return const <TranslateLanguage>[TranslateLanguage.arabic, TranslateLanguage.english];
    }
    return <TranslateLanguage>[TranslateLanguage.arabic, TranslateLanguage.english, language];
  }

  @override
  Future<TranslationEngineStatus> statusFor(TargetLanguage target) async {
    if (mlKitLanguage(target) == null) return TranslationEngineStatus.unsupportedLanguage;
    // 有下载在跑时不再查询原生：iOS 上任何一次新的 manager 调用都会释放正在下载
    // 的那个实例，直接导致下载失败。
    if (_pendingBcp.isNotEmpty) return TranslationEngineStatus.downloading;
    final manager = _manager;
    for (final language in requiredModels(target)) {
      final downloaded =
          await _serial(() => manager.isModelDownloaded(language.bcpCode));
      if (!downloaded) return TranslationEngineStatus.missing;
    }
    _ready.add(target);
    return TranslationEngineStatus.ready;
  }

  @override
  Future<TranslationEngineStatus> prepare({
    required TargetLanguage target,
    bool allowDownload = true,
  }) async {
    if (mlKitLanguage(target) == null) {
      throw const TranslationException(
        TranslationErrorCode.unsupportedLanguage,
        'ML Kit 不支持该目标语言',
      );
    }
    final manager = _manager;
    var downloadedSomething = false;
    // 整个准备过程占住串行锁：下载期间不允许任何其它原生 manager 调用插进来。
    return _serial(() async {
      for (final language in requiredModels(target)) {
        final bcp = language.bcpCode;
        if (await manager.isModelDownloaded(bcp)) continue;
        if (!allowDownload) {
          throw TranslationException(
            TranslationErrorCode.offlineDownloadUnavailable,
            '缺少 $bcp 语言包，且当前不允许联网下载',
          );
        }
        final bool ok;
        _pendingBcp.add(bcp);
        try {
          ok = await manager.downloadModel(bcp, isWifiRequired: false);
        } on PlatformException catch (error) {
          // 插件原生层抛的是 PlatformException，不是我们的 TranslationException。
          // iOS 上实测：下载过程中若原生 ModelManager 被释放，返回 `cancelled /
          // Model manager deallocated during download`。必须在这里转换，否则异常
          // 会一路冒泡到 UI 把页面打崩。
          throw TranslationException(
            TranslationErrorCode.modelMissing,
            '$bcp 语言包下载失败：${error.message ?? error.code}',
          );
        } finally {
          _pendingBcp.remove(bcp);
        }
        if (!ok) {
          throw TranslationException(
            TranslationErrorCode.modelMissing,
            '$bcp 语言包下载未成功',
          );
        }
        downloadedSomething = true;
      }
      if (downloadedSomething) _generation++;
      _ready.add(target);
      return TranslationEngineStatus.ready;
    });
  }

  @override
  Future<TranslationResult> translate(TranslationRequest request) async {
    final target = mlKitLanguage(request.targetLanguage);
    if (target == null) {
      throw const TranslationException(
        TranslationErrorCode.unsupportedLanguage,
        'ML Kit 不支持该目标语言',
      );
    }
    if (request.inputText.trim().isEmpty) {
      throw const TranslationException(TranslationErrorCode.translateFailed, '待翻译文本为空');
    }
    final watch = Stopwatch()..start();
    try {
      if (!_ready.contains(request.targetLanguage)) {
        final status = await statusFor(request.targetLanguage);
        if (status != TranslationEngineStatus.ready) {
          throw TranslationException(
            status == TranslationEngineStatus.missing
                ? TranslationErrorCode.modelMissing
                : TranslationErrorCode.translateFailed,
            '语言包未就绪（$status）',
          );
        }
      }
      final translator = _translators.putIfAbsent(
        request.targetLanguage,
        () => OnDeviceTranslator(
          sourceLanguage: TranslateLanguage.arabic,
          targetLanguage: target,
        ),
      );
      final text = await translator.translateText(request.inputText);
      watch.stop();
      if (text.trim().isEmpty) {
        throw const TranslationException(TranslationErrorCode.translateFailed, '引擎返回空译文');
      }
      return TranslationResult(
        text: text.trim(),
        provider: 'mlkit',
        engineId: '$engineVersion (gen $_generation)',
        elapsedMs: watch.elapsedMilliseconds,
      );
    } on TranslationException {
      rethrow;
    } catch (error) {
      throw TranslationException(TranslationErrorCode.translateFailed, '$error');
    }
  }

  @override
  Future<void> close() async {
    for (final translator in _translators.values) {
      await translator.close();
    }
    _translators.clear();
    _ready.clear();
  }
}
