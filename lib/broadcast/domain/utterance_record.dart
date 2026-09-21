/// 广播功能领域模型：一条持久记录及其匹配、指标与译文快照。
///
/// 三类文本严格分离，互不冒充：
///
/// 1. [UtteranceRecord.rawAsrText]：手机实际听到并由 ASR 输出的阿拉伯语；
/// 2. [MatchedVerse]：独立新库的标准阿拉伯原文（含章/节编号与匹配范围）；
/// 3. [RecordTranslation]：目标语言译文，必须携带来源标记。
///
/// 记录一经创建即冻结三类文本快照，详情页不会用新版经文或当前语言重算，
/// 因此历史不会随时间悄悄变化。
library;

import 'dart:math' as math;

/// 目标语言（应用内部口径）。
enum TargetLanguage {
  /// 简体中文。
  simplifiedChinese('zh-Hans', '简体中文'),

  /// 英语。
  english('en', 'English');

  const TargetLanguage(this.code, this.label);

  /// 应用内语言标签。
  final String code;

  /// 界面展示名。
  final String label;

  /// 从应用内标签解析。
  ///
  /// @param code 语言标签
  /// @return 目标语言；无法识别时返回 null
  static TargetLanguage? tryParse(String? code) {
    if (code == null) return null;
    for (final value in TargetLanguage.values) {
      if (value.code == code) return value;
    }
    return null;
  }
}

/// 源语言固定为阿拉伯语。
const String broadcastSourceLanguage = 'ar';

/// 经文匹配状态。
enum MatchStatus {
  /// 高可信，已确认在库内定位到经文。
  confirmed,

  /// 只覆盖到某节的一部分，范围可确定但未覆盖整节。
  partial,

  /// 有候选但证据不足，界面必须显示为「候选」而不是确认。
  candidate,

  /// 未匹配：保留真实转写，原文与指标留空，不回退旧库也不猜最相似经文。
  unmatched;

  /// 是否为「已确认」（全部或部分）。
  bool get isMatched => this == MatchStatus.confirmed || this == MatchStatus.partial;
}

/// 片段覆盖的经文范围形态。
enum RecordScope {
  /// 完整覆盖一个或多个整节。
  completeVerses,

  /// 只覆盖某一节的一部分。
  partialVerse,

  /// 同时包含整节与部分节。
  mixed,

  /// 范围无法确定（未匹配或只有候选）。
  unknown;

  /// 数据库/界面的稳定名称。
  String get wireName => name;
}

/// 片段结束原因。
enum BoundaryReason {
  /// 检测到足够长的静音。
  silence,

  /// 达到最大片段时长被强制切分。
  maxDuration,

  /// 用户停止或会话收尾。
  stopped,

  /// 其他（含无明确原因的历史记录）。
  unknown;

  /// 数据库/界面的稳定名称。
  String get wireName => name;
}

/// 译文来源种类（用户确认的策略 `editionPreferredWithMachineFallback`）。
enum TranslationSourceKind {
  /// 授权校订译本（本地查表，不经过机器翻译）。
  curatedEdition,

  /// 已匹配经文但该语言译本缺失，机器翻译新库标准原文。
  machineCanonical,

  /// 未匹配经文，机器翻译实际 ASR 转写。
  machineAsr;

  /// 数据库/界面的稳定名称。
  String get wireName => name;

  /// 界面展示的来源说明。
  String get label => switch (this) {
    TranslationSourceKind.curatedEdition => '校订译本',
    TranslationSourceKind.machineCanonical => '机器翻译·标准原文',
    TranslationSourceKind.machineAsr => '机器翻译·识别转写（未匹配经文）',
  };
}

/// 译文状态。
enum TranslationStatus {
  /// 已入队，尚未执行。
  pending,

  /// 正在翻译。
  running,

  /// 已完成，[RecordTranslation.text] 可用。
  done,

  /// 失败，可通过同一记录重试。
  failed,

  /// 缺少语言包且当前不允许联网下载。
  modelMissing;

  /// 数据库/界面的稳定名称。
  String get wireName => name;

  /// 是否可以在同一记录上重试。
  bool get canRetry => this == TranslationStatus.failed || this == TranslationStatus.modelMissing;

  /// 界面展示名。
  String get label => switch (this) {
    TranslationStatus.pending => '等待翻译',
    TranslationStatus.running => '正在翻译',
    TranslationStatus.done => '已翻译',
    TranslationStatus.failed => '翻译失败',
    TranslationStatus.modelMissing => '缺少离线语言包',
  };
}

/// 翻译任务的持久状态。
enum TranslationJobState {
  /// 待执行（含重启后恢复的残留 running）。
  pending,

  /// 正在执行。
  running,

  /// 已完成。
  done,

  /// 已失败。
  failed;

  /// 数据库/界面的稳定名称。
  String get wireName => name;
}

/// 一条记录关联的某一节经文及其匹配范围。
class MatchedVerse {
  /// 构造匹配经文。
  ///
  /// @param ordinal 在记录内的顺序（0 起）
  /// @param surah 章号
  /// @param ayah 节号
  /// @param wordStart 节内匹配词起点（含）；null 表示整节
  /// @param wordEnd 节内匹配词终点（含）；null 表示整节
  /// @param canonicalTextSnapshot 该节标准原文快照
  /// @param matchedTextSnapshot 实际匹配到的词序列快照
  /// @param corpusVersion 语料版本
  const MatchedVerse({
    required this.ordinal,
    required this.surah,
    required this.ayah,
    required this.wordStart,
    required this.wordEnd,
    required this.canonicalTextSnapshot,
    required this.matchedTextSnapshot,
    required this.corpusVersion,
  });

  /// 记录内顺序。
  final int ordinal;

  /// 章号。
  final int surah;

  /// 节号。
  final int ayah;

  /// 节内匹配词起点（含）。
  final int? wordStart;

  /// 节内匹配词终点（含）。
  final int? wordEnd;

  /// 标准原文快照。
  final String canonicalTextSnapshot;

  /// 实际匹配到的词序列快照。
  final String matchedTextSnapshot;

  /// 语料版本。
  final String corpusVersion;

  /// `surah:ayah` 引用键。
  String get ref => '$surah:$ayah';

  /// 是否覆盖整节。
  bool get isWholeVerse => wordStart == null && wordEnd == null;

  /// 人类可读范围标签。
  String get label => isWholeVerse
      ? ref
      : '$ref 词 ${(wordStart ?? 0) + 1}–${(wordEnd ?? 0) + 1}';
}

/// 比对指标快照。
///
/// 这些数值衡量的是「转写与候选原文的一致性」，不是独立 ASR 准确率保证；
/// 没有可信参考时全部为 null，界面显示「不可用」而不是 0 分。
class RecordMetrics {
  /// 构造指标快照。
  ///
  /// @param metricScope 指标对应的范围描述（如 `1:1-3`）
  /// @param precision 准确率（0..1）
  /// @param recall 覆盖率（0..1）
  /// @param f1 F1（0..1）
  /// @param strictWer 严格词错误率（可超过 1，不截断）
  /// @param substitutions 替换数
  /// @param deletions 缺失数
  /// @param insertions 多余数
  /// @param referenceWords 参考词数
  /// @param hypothesisWords 转写词数
  /// @param matchCount 一致词数
  /// @param nearCount 近似词数
  /// @param mismatchCount 错配词数
  /// @param missingCount 缺失词数
  /// @param extraCount 多余词数
  /// @param alignmentJson 逐词对照 JSON（可空）
  /// @param normalizationVersion 归一化口径版本
  const RecordMetrics({
    required this.metricScope,
    required this.precision,
    required this.recall,
    required this.f1,
    required this.strictWer,
    required this.substitutions,
    required this.deletions,
    required this.insertions,
    required this.referenceWords,
    required this.hypothesisWords,
    required this.matchCount,
    required this.nearCount,
    required this.mismatchCount,
    required this.missingCount,
    required this.extraCount,
    required this.normalizationVersion,
    this.alignmentJson,
  });

  /// 指标范围描述。
  final String metricScope;

  /// 准确率。
  final double? precision;

  /// 覆盖率。
  final double? recall;

  /// F1。
  final double? f1;

  /// 严格 WER。
  final double? strictWer;

  /// 替换数。
  final int? substitutions;

  /// 缺失数。
  final int? deletions;

  /// 多余数。
  final int? insertions;

  /// 参考词数。
  final int? referenceWords;

  /// 转写词数。
  final int? hypothesisWords;

  /// 一致词数。
  final int? matchCount;

  /// 近似词数。
  final int? nearCount;

  /// 错配词数。
  final int? mismatchCount;

  /// 缺失词数。
  final int? missingCount;

  /// 多余词数。
  final int? extraCount;

  /// 归一化口径版本。
  final String normalizationVersion;

  /// 逐词对照 JSON。
  final String? alignmentJson;

  /// 无参考时的空指标（界面必须显示「不可用」）。
  ///
  /// @param metricScope 范围描述
  /// @param normalizationVersion 归一化版本
  /// @return 全部为 null 的指标快照
  static RecordMetrics unavailable({
    required String metricScope,
    required String normalizationVersion,
  }) => RecordMetrics(
    metricScope: metricScope,
    precision: null,
    recall: null,
    f1: null,
    strictWer: null,
    substitutions: null,
    deletions: null,
    insertions: null,
    referenceWords: null,
    hypothesisWords: null,
    matchCount: null,
    nearCount: null,
    mismatchCount: null,
    missingCount: null,
    extraCount: null,
    normalizationVersion: normalizationVersion,
  );
}

/// 一条记录的译文快照。
class RecordTranslation {
  /// 构造译文。
  ///
  /// @param id 译文行主键
  /// @param recordId 所属记录
  /// @param revision 对应记录修订号
  /// @param targetLanguage 目标语言
  /// @param provider 提供方标识（`mlkit` / `curated`）
  /// @param sourceKind 来源种类
  /// @param sourceHash 输入文本哈希（用于幂等与缓存）
  /// @param inputScope 输入范围（`confirmedRange` / `fullVerseContext`）
  /// @param text 译文（失败时为空串）
  /// @param status 状态
  /// @param createdAt 创建时间
  /// @param editionId 校订译本标识
  /// @param engineId 引擎标识与版本
  /// @param errorCode 失败分类
  /// @param elapsedMs 耗时
  const RecordTranslation({
    required this.id,
    required this.recordId,
    required this.revision,
    required this.targetLanguage,
    required this.provider,
    required this.sourceKind,
    required this.sourceHash,
    required this.inputScope,
    required this.text,
    required this.status,
    required this.createdAt,
    this.editionId,
    this.engineId,
    this.errorCode,
    this.elapsedMs,
  });

  /// 主键。
  final String id;

  /// 所属记录。
  final String recordId;

  /// 对应记录修订号。
  final int revision;

  /// 目标语言。
  final TargetLanguage targetLanguage;

  /// 提供方标识。
  final String provider;

  /// 来源种类。
  final TranslationSourceKind sourceKind;

  /// 输入文本哈希。
  final String sourceHash;

  /// 输入范围。
  final String inputScope;

  /// 译文文本。
  final String text;

  /// 状态。
  final TranslationStatus status;

  /// 创建时间。
  final DateTime createdAt;

  /// 校订译本标识。
  final String? editionId;

  /// 引擎标识与版本。
  final String? engineId;

  /// 失败分类。
  final String? errorCode;

  /// 耗时（毫秒）。
  final int? elapsedMs;

  /// 来源展示文案（含译者或引擎与版本）。
  String get sourceLabel {
    final parts = <String>[sourceKind.label];
    if (editionId != null && editionId!.isNotEmpty) parts.add('译本 $editionId');
    if (engineId != null && engineId!.isNotEmpty) parts.add(engineId!);
    return parts.join(' · ');
  }
}

/// 一条持久化记录（三栏内容的完整快照）。
class UtteranceRecord {
  /// 构造记录。
  ///
  /// @param id 业务身份（UUID，排序或删除后不变）
  /// @param displaySequence 稳定展示序号（数据库自增，删除后不改号）
  /// @param sessionId 所属会话
  /// @param utteranceId 句段标识（同一音频片段反复回调共用）
  /// @param revision 修订号
  /// @param startSample 音频起始采样
  /// @param endSample 音频结束采样
  /// @param sampleRate 采样率
  /// @param boundaryReason 片段结束原因
  /// @param rawAsrText 实际 ASR 转写
  /// @param targetLanguage 创建时冻结的目标语言
  /// @param matchStatus 匹配状态
  /// @param scope 覆盖范围形态
  /// @param createdAt 创建时间
  /// @param updatedAt 最近更新时间
  /// @param matches 匹配经文
  /// @param metrics 比对指标
  /// @param translations 该记录已生成的译文
  /// @param processingMs 各阶段耗时（毫秒 JSON）
  /// @param matcherEvidenceJson 诊断证据 JSON
  const UtteranceRecord({
    required this.id,
    required this.displaySequence,
    required this.sessionId,
    required this.utteranceId,
    required this.revision,
    required this.startSample,
    required this.endSample,
    required this.sampleRate,
    required this.boundaryReason,
    required this.rawAsrText,
    required this.targetLanguage,
    required this.matchStatus,
    required this.scope,
    required this.createdAt,
    required this.updatedAt,
    this.matches = const <MatchedVerse>[],
    this.metrics,
    this.translations = const <RecordTranslation>[],
    this.processingMs,
    this.matcherEvidenceJson,
  });

  /// 业务身份。
  final String id;

  /// 稳定展示序号。
  final int displaySequence;

  /// 所属会话。
  final String sessionId;

  /// 句段标识。
  final String utteranceId;

  /// 修订号。
  final int revision;

  /// 音频起始采样。
  final int startSample;

  /// 音频结束采样。
  final int endSample;

  /// 采样率。
  final int sampleRate;

  /// 结束原因。
  final BoundaryReason boundaryReason;

  /// 实际 ASR 转写。
  final String rawAsrText;

  /// 创建时冻结的目标语言。
  final TargetLanguage targetLanguage;

  /// 匹配状态。
  final MatchStatus matchStatus;

  /// 覆盖范围形态。
  final RecordScope scope;

  /// 创建时间。
  final DateTime createdAt;

  /// 最近更新时间。
  final DateTime updatedAt;

  /// 匹配经文。
  final List<MatchedVerse> matches;

  /// 比对指标。
  final RecordMetrics? metrics;

  /// 已生成的译文。
  final List<RecordTranslation> translations;

  /// 各阶段耗时（毫秒 JSON）。
  final String? processingMs;

  /// 匹配诊断证据 JSON。
  final String? matcherEvidenceJson;

  /// 片段起止时间（秒）。
  double get startSeconds => startSample / sampleRate;

  /// 片段结束时间（秒）。
  double get endSeconds => endSample / sampleRate;

  /// 取指定语言的译文。
  ///
  /// @param language 目标语言
  /// @return 译文；该语言尚未生成时返回 null
  RecordTranslation? translationFor(TargetLanguage language) {
    for (final translation in translations.reversed) {
      if (translation.targetLanguage == language && translation.revision == revision) {
        return translation;
      }
    }
    return null;
  }

  /// 经文范围摘要（供历史列表使用）。
  String get matchSummary {
    if (matches.isEmpty) return matchStatus == MatchStatus.candidate ? '候选经文' : '未匹配';
    final surahs = matches.map((match) => match.surah).toSet();
    if (surahs.length != 1) {
      return <String>[for (final match in matches) match.ref].join('、');
    }
    final ordered = <MatchedVerse>[...matches]..sort((a, b) => a.ayah.compareTo(b.ayah));
    final first = ordered.first;
    final last = ordered.last;
    if (ordered.length == 1) return first.label;
    final prefix = matchStatus == MatchStatus.partial ? '部分 ' : '';
    return '$prefix${first.surah}:${first.ayah}–${last.ayah}';
  }

  /// 文本摘要。
  ///
  /// @param maxLength 最大字符数
  /// @return 摘要文本
  String summary(int maxLength) {
    final text = rawAsrText.trim();
    if (text.length <= maxLength) return text;
    return '${text.substring(0, maxLength)}…';
  }

  /// 生成一个新的业务标识（UUID v4）。
  ///
  /// @return 36 字符 UUID 字符串
  static String newId() => newUuid();

  /// 生成一个新的业务标识（UUID v4）。
  ///
  /// 记录、会话与译文行都用它做业务身份；序号则另由数据库自增维护。
  ///
  /// @return 36 字符 UUID 字符串
  static String newUuid() {
    final random = math.Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = <String>[for (final byte in bytes) byte.toRadixString(16).padLeft(2, '0')].join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}

/// 一条待执行的翻译任务。
///
/// 任务与记录同事务写入，因此「记录已保存但译文未完成」是可恢复状态，
/// 而不是丢数据。
class TranslationJob {
  /// 构造任务。
  ///
  /// @param id 主键
  /// @param recordId 所属记录
  /// @param revision 记录修订号
  /// @param targetLanguage 目标语言（创建时冻结）
  /// @param provider 提供方
  /// @param sourceHash 输入文本哈希
  /// @param state 任务状态
  /// @param attemptCount 已尝试次数
  /// @param createdAt 创建时间
  /// @param lastError 最近一次失败原因
  const TranslationJob({
    required this.id,
    required this.recordId,
    required this.revision,
    required this.targetLanguage,
    required this.provider,
    required this.sourceHash,
    required this.state,
    required this.attemptCount,
    required this.createdAt,
    this.lastError,
  });

  /// 主键。
  final String id;

  /// 所属记录。
  final String recordId;

  /// 记录修订号。
  final int revision;

  /// 目标语言。
  final TargetLanguage targetLanguage;

  /// 提供方。
  final String provider;

  /// 输入文本哈希。
  final String sourceHash;

  /// 任务状态。
  final TranslationJobState state;

  /// 已尝试次数。
  final int attemptCount;

  /// 创建时间。
  final DateTime createdAt;

  /// 最近失败原因。
  final String? lastError;
}
