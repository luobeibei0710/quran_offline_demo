/// 离线机器翻译的统一契约。
///
/// 机器翻译固定使用 ML Kit（见实施方案 §6.1）；本文件只描述职责与数据契约，
/// 具体引擎由 [MlKitTranslationEngine] 实现，测试可注入假引擎。
///
/// 三条硬性约束：
///
/// 1. **翻译输入由来源规则决定**：未匹配时是实际 ASR 转写，已匹配但缺译本时
///    是新库标准原文；两者都不能使用为模糊匹配而折叠字符的归一化文本。
/// 2. **来源必须可追溯**：结果带上 `sourceKind`，界面不得把机器翻译标成校订译本。
/// 3. **运行期离线**：语言包在准备阶段下载；运行期缺包要明确失败，不降级到云服务。
library;

import '../domain/utterance_record.dart';

/// 翻译输入的种类。
enum TranslationInputKind {
  /// 新库标准阿拉伯原文。
  canonical,

  /// 实际 ASR 转写。
  asr;

  /// 数据库/界面名称。
  String get wireName => name;
}

/// 引擎准备状态。
enum TranslationEngineStatus {
  /// 语言包已就绪，可离线翻译。
  ready,

  /// 语言包缺失（运行期离线时不自动下载）。
  missing,

  /// 正在下载语言包。
  downloading,

  /// 准备失败。
  failed,

  /// 目标语言不被该引擎支持。
  unsupportedLanguage;

  /// 数据库/界面名称。
  String get wireName => name;
}

/// 失败分类。
enum TranslationErrorCode {
  /// 缺少语言包。
  modelMissing,

  /// 缺包且当前不允许自动下载。
  offlineDownloadUnavailable,

  /// 目标语言不受支持。
  unsupportedLanguage,

  /// 翻译执行失败。
  translateFailed,

  /// 存储写入失败。
  storageFailed;

  /// 数据库/界面名称。
  String get wireName => name;
}

/// 带分类的翻译异常。
class TranslationException implements Exception {
  /// 构造异常。
  ///
  /// @param code 失败分类
  /// @param message 说明
  const TranslationException(this.code, this.message);

  /// 失败分类。
  final TranslationErrorCode code;

  /// 说明。
  final String message;

  @override
  String toString() => 'TranslationException(${code.wireName}: $message)';
}

/// 一次翻译请求。
class TranslationRequest {
  /// 构造请求。
  ///
  /// @param recordId 记录标识
  /// @param revision 记录修订号
  /// @param inputText 待翻译文本（来自标准原文或实际转写）
  /// @param inputKind 输入种类
  /// @param sourceHash 输入哈希（幂等键与缓存键的一部分）
  /// @param targetLanguage 目标语言
  const TranslationRequest({
    required this.recordId,
    required this.revision,
    required this.inputText,
    required this.inputKind,
    required this.sourceHash,
    required this.targetLanguage,
  });

  /// 记录标识。
  final String recordId;

  /// 记录修订号。
  final int revision;

  /// 待翻译文本。
  final String inputText;

  /// 输入种类。
  final TranslationInputKind inputKind;

  /// 输入哈希。
  final String sourceHash;

  /// 目标语言。
  final TargetLanguage targetLanguage;
}

/// 一次翻译结果。
class TranslationResult {
  /// 构造结果。
  ///
  /// @param text 译文
  /// @param provider 提供方标识
  /// @param engineId 引擎标识与版本
  /// @param elapsedMs 耗时
  const TranslationResult({
    required this.text,
    required this.provider,
    required this.engineId,
    required this.elapsedMs,
  });

  /// 译文。
  final String text;

  /// 提供方标识。
  final String provider;

  /// 引擎标识与版本。
  final String? engineId;

  /// 耗时（毫秒）。
  final int elapsedMs;
}

/// 离线翻译引擎契约。
abstract interface class OfflineTranslationEngine {
  /// 引擎标识（写入缓存键与译文来源）。
  String get engineId;

  /// 引擎当前代号。
  ///
  /// 用于缓存失效：模型重新准备或引擎升级后主动递增，不杜撰引擎内部版本号。
  int get generation;

  /// 查询目标语言的就绪状态。
  ///
  /// @param target 目标语言
  /// @return 状态
  Future<TranslationEngineStatus> statusFor(TargetLanguage target);

  /// 准备语言包（允许按 [allowDownload] 联网下载）。
  ///
  /// @param target 目标语言
  /// @param allowDownload 是否允许联网下载语言包
  /// @return 准备后的状态
  Future<TranslationEngineStatus> prepare({required TargetLanguage target, bool allowDownload = true});

  /// 执行翻译。
  ///
  /// @param request 翻译请求
  /// @return 翻译结果
  /// @throws TranslationException 分类失败时抛出
  Future<TranslationResult> translate(TranslationRequest request);

  /// 排空在途调用并释放资源。
  Future<void> close();
}
