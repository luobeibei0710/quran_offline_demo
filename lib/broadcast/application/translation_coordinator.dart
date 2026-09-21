/// 翻译协调器：来源策略、输入预处理、串行任务、缓存与失败重试。
///
/// 来源策略固定为用户确认的 `editionPreferredWithMachineFallback`：
///
/// | 情形 | 来源 | 输入文本 |
/// |---|---|---|
/// | 匹配成功且该语言有授权校订译本 | `curatedEdition` | 直接查表，不过机器翻译 |
/// | 匹配成功但译本缺失 | `machineCanonical` | 新库标准原文（保留音标与原始顺序） |
/// | 未匹配 | `machineAsr` | 实际 ASR 转写 |
///
/// 其余硬性规则：
///
/// - **半节只翻译确认范围**；整节译本若作为上下文展示，必须由界面标注为
///   「整节译文（上下文）」，不能冒充该片段的精确译文；
/// - 缓存键包含 `输入哈希 + 语料版本 + 目标语言 + 提供方 + 引擎代号 + 预处理版本`，
///   引擎升级或语言包重新准备后主动失效；
/// - 失败不丢记录：译文行写失败状态，任务保留可重试；
/// - 迟到结果由 [RecordRepository.saveTranslation] 二次校验 `recordId /
///   revision / targetLanguage`，过期即丢弃，既不会覆盖新句，也不会复活已删记录。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../data/broadcast_corpus.dart';
import '../data/record_repository.dart';
import '../domain/utterance_record.dart';
import '../translation/offline_translation_engine.dart';
import '../translation/verse_translation_repository.dart';

/// 翻译输入预处理。
///
/// 单独版本化，便于缓存失效与事后归因。**不**使用为模糊匹配折叠字符的
/// `QuranText.normalize` 输出作为标准原文输入；标准原文按上游文本原样切片，
/// 保留音标与原始词序。
class TranslationPreprocessor {
  /// 当前预处理版本。
  static const String version = 'translation-input-1';

  /// 标准原文输入：按词范围切片，保留原始字符。
  ///
  /// @param sourceText 上游原文（含音标）
  /// @param wordStart 节内起始词（含）；null 表示整节
  /// @param wordEnd 节内结束词（含）；null 表示整节
  /// @return 待翻译原文
  static String canonical(String sourceText, {int? wordStart, int? wordEnd}) {
    if (wordStart == null || wordEnd == null) return sourceText.trim();
    final words = sourceText.split(RegExp(r'\s+')).where((word) => word.isNotEmpty).toList();
    if (words.isEmpty) return sourceText.trim();
    final start = wordStart.clamp(0, words.length - 1);
    final end = wordEnd.clamp(start, words.length - 1);
    return words.sublist(start, end + 1).join(' ').trim();
  }
}

/// 一次翻译的输入与来源决策。
class TranslationInput {
  /// 构造输入。
  ///
  /// @param kind 输入种类
  /// @param sourceKind 译文来源种类
  /// @param text 待翻译文本
  /// @param inputScope 范围标记
  /// @param curated 命中的校订译本（若有）
  const TranslationInput({
    required this.kind,
    required this.sourceKind,
    required this.text,
    required this.inputScope,
    this.curated,
  });

  /// 输入种类。
  final TranslationInputKind kind;

  /// 来源种类。
  final TranslationSourceKind sourceKind;

  /// 待翻译文本。
  final String text;

  /// 范围标记（`confirmedRange` / `fullVerses` / `asr`）。
  final String inputScope;

  /// 命中的校订译本。
  final VerseTranslation? curated;
}

/// 翻译协调器。
class TranslationCoordinator {
  /// 构造协调器。
  ///
  /// @param engine 离线翻译引擎
  /// @param records 记录仓储
  /// @param library 独立三章语料库（提供标准原文）
  /// @param editions 校订译本仓储
  /// @param allowDownload 是否允许联网准备语言包（仅准备阶段）
  TranslationCoordinator({
    required this.engine,
    required this.records,
    required this.library,
    this.editions = const NoCuratedEditionRepository(),
    this.allowDownload = true,
  });

  /// 翻译引擎。
  final OfflineTranslationEngine engine;

  /// 记录仓储。
  final RecordRepository records;

  /// 语料库。
  final BroadcastQuranLibrary library;

  /// 校订译本仓储。
  final VerseTranslationRepository editions;

  /// 是否允许联网准备语言包。
  final bool allowDownload;

  /// 一次 drain 最多处理的任务数（长会话下避免一次卡太久）。
  static const int defaultDrainLimit = 8;

  /// 决定该记录的来源与输入文本。
  ///
  /// @param record 记录
  /// @param language 目标语言
  /// @return 输入与来源
  Future<TranslationInput> resolveInput(UtteranceRecord record, TargetLanguage language) async {
    final asrText = record.rawAsrText.trim();
    if (record.matches.isEmpty || !record.matchStatus.isMatched) {
      // 未匹配：翻译实际 ASR 转写，原文与匹配指标留空。
      return TranslationInput(
        kind: TranslationInputKind.asr,
        sourceKind: TranslationSourceKind.machineAsr,
        text: asrText,
        inputScope: 'asr',
      );
    }

    // 已匹配：优先查授权校订译本（整节粒度）。
    final ordered = <MatchedVerse>[...record.matches]..sort((a, b) => a.ordinal.compareTo(b.ordinal));
    if (ordered.every((match) => match.isWholeVerse)) {
      final curated = await _lookupCurated(ordered, language);
      if (curated != null) {
        return TranslationInput(
          kind: TranslationInputKind.canonical,
          sourceKind: TranslationSourceKind.curatedEdition,
          text: curated.text,
          inputScope: 'fullVerses',
          curated: curated,
        );
      }
      return TranslationInput(
        kind: TranslationInputKind.canonical,
        sourceKind: TranslationSourceKind.machineCanonical,
        text: _canonicalText(ordered),
        inputScope: 'fullVerses',
      );
    }

    // 半节/混合范围：只翻译经过确认的范围，不用整节内容补齐。
    final hasPartial = ordered.any((match) => !match.isWholeVerse);
    return TranslationInput(
      kind: TranslationInputKind.canonical,
      sourceKind: TranslationSourceKind.machineCanonical,
      text: _canonicalText(ordered),
      inputScope: hasPartial ? 'confirmedRange' : 'fullVerses',
    );
  }

  /// 计算缓存键。
  ///
  /// @param input 输入决策
  /// @param language 目标语言
  /// @param provider 提供方
  /// @param engineId 引擎标识
  /// @param generation 引擎代号
  /// @return 稳定缓存键
  String cacheKeyFor(
    TranslationInput input,
    TargetLanguage language, {
    required String provider,
    required String? engineId,
    required int generation,
  }) => <String>[
    _stableHash(input.text),
    library.manifest.corpusId,
    library.manifest.corpusVersion,
    language.code,
    provider,
    engineId ?? 'unknown',
    'gen$generation',
    TranslationPreprocessor.version,
  ].join('|');

  /// 处理一条待执行任务。
  ///
  /// 幂等；失败时写失败状态并保留任务以便重试。
  ///
  /// @param job 任务
  /// @return 处理后的状态
  Future<TranslationStatus> runJob(TranslationJob job) async {
    final record = await records.byId(job.recordId);
    if (record == null) {
      // 记录已被删除：任务直接终止，不得复活记录。
      await records.updateJobState(job.id, TranslationJobState.failed, error: '记录已删除');
      return TranslationStatus.failed;
    }
    final language = job.targetLanguage;
    final provider = engine.engineId;
    final input = await resolveInput(record, language);
    final sourceHash = _stableHash(input.text);
    debugPrint(
      '[Broadcast] 翻译任务：记录 #${record.displaySequence} 语言=${language.label} '
      '来源=${input.sourceKind.wireName} 范围=${input.inputScope} '
      '输入 ${input.text.length} 字符',
    );
    final cacheKey = cacheKeyFor(
      input,
      language,
      provider: input.sourceKind == TranslationSourceKind.curatedEdition ? 'curated' : provider,
      engineId: engine.engineId,
      generation: engine.generation,
    );

    // 占位行与结果行必须使用同一个 provider：译文行的唯一约束是
    // (recordId, revision, targetLanguage, provider)，若「进行中」用 engineId、
    // 结果用 curated，就会在同一记录同一语言下留下两行；两行 created_at 同毫秒时
    // 取译文的顺序不确定，界面可能读到空占位。
    final effectiveProvider = input.sourceKind == TranslationSourceKind.curatedEdition
        ? 'curated'
        : provider;

    await records.updateJobState(job.id, TranslationJobState.running, incrementAttempt: true);
    await _writeTranslation(
      record: record,
      language: language,
      provider: effectiveProvider,
      sourceKind: input.sourceKind,
      sourceHash: sourceHash,
      inputScope: input.inputScope,
      text: '',
      status: TranslationStatus.running,
      engineId: engine.engineId,
    );

    // 校订译本：直接落库，不经过机器翻译。
    if (input.sourceKind == TranslationSourceKind.curatedEdition) {
      await _writeTranslation(
        record: record,
        language: language,
        provider: effectiveProvider,
        sourceKind: input.sourceKind,
        sourceHash: sourceHash,
        inputScope: input.inputScope,
        text: input.text,
        status: TranslationStatus.done,
        engineId: null,
        editionId: input.curated?.editionId,
      );
      await records.updateJobState(job.id, TranslationJobState.done);
      debugPrint('[Broadcast] 翻译完成：命中校订译本 ${input.curated?.editionId}（未经机器翻译）');
      return TranslationStatus.done;
    }

    final cached = await records.readCache(cacheKey);
    if (cached != null) {
      debugPrint('[Broadcast] 翻译缓存命中：复用已有译文（未调用引擎）');
      await _writeTranslation(
        record: record,
        language: language,
        provider: provider,
        sourceKind: input.sourceKind,
        sourceHash: sourceHash,
        inputScope: input.inputScope,
        text: cached,
        status: TranslationStatus.done,
        engineId: engine.engineId,
      );
      await records.updateJobState(job.id, TranslationJobState.done);
      return TranslationStatus.done;
    }

    try {
      final result = await engine.translate(
        TranslationRequest(
          recordId: record.id,
          revision: record.revision,
          inputText: input.text,
          inputKind: input.kind,
          sourceHash: sourceHash,
          targetLanguage: language,
        ),
      );
      await _writeTranslation(
        record: record,
        language: language,
        provider: provider,
        sourceKind: input.sourceKind,
        sourceHash: sourceHash,
        inputScope: input.inputScope,
        text: result.text,
        status: TranslationStatus.done,
        engineId: result.engineId,
        elapsedMs: result.elapsedMs,
      );
      await records.writeCache(
        cacheKey,
        result.text,
        provider: provider,
        sourceKind: input.sourceKind,
        engineId: result.engineId,
      );
      await records.updateJobState(job.id, TranslationJobState.done);
      final preview = result.text.length > 60 ? '${result.text.substring(0, 60)}…' : result.text;
      debugPrint('[Broadcast] 翻译完成：$preview（${result.elapsedMs}ms，${result.engineId}）');
      return TranslationStatus.done;
    } on TranslationException catch (error) {
      debugPrint('[Broadcast] 翻译失败：${error.code.wireName} — ${error.message}');
      final status = error.code == TranslationErrorCode.modelMissing ||
              error.code == TranslationErrorCode.offlineDownloadUnavailable
          ? TranslationStatus.modelMissing
          : TranslationStatus.failed;
      await _writeTranslation(
        record: record,
        language: language,
        provider: provider,
        sourceKind: input.sourceKind,
        sourceHash: sourceHash,
        inputScope: input.inputScope,
        text: '',
        status: status,
        engineId: engine.engineId,
        errorCode: error.code.wireName,
      );
      await records.updateJobState(
        job.id,
        status == TranslationStatus.modelMissing
            ? TranslationJobState.pending
            : TranslationJobState.failed,
        error: error.message,
      );
      return status;
    } catch (error) {
      await _writeTranslation(
        record: record,
        language: language,
        provider: provider,
        sourceKind: input.sourceKind,
        sourceHash: sourceHash,
        inputScope: input.inputScope,
        text: '',
        status: TranslationStatus.failed,
        engineId: engine.engineId,
        errorCode: TranslationErrorCode.translateFailed.wireName,
      );
      await records.updateJobState(job.id, TranslationJobState.failed, error: '$error');
      return TranslationStatus.failed;
    }
  }

  /// 串行处理待办任务（主进程最多 1 个翻译在跑）。
  ///
  /// @param limit 本次最多处理条数
  /// @return 处理过的任务数
  Future<int> drain({int limit = defaultDrainLimit}) async {
    final jobs = await records.pendingJobs(limit: limit);
    var processed = 0;
    for (final job in jobs) {
      await runJob(job);
      processed++;
    }
    return processed;
  }

  /// 重试某条记录的某语言译文（同一记录，不新建历史）。
  ///
  /// @param recordId 记录标识
  /// @param language 目标语言
  /// @return 是否重新处理
  Future<bool> retry(String recordId, TargetLanguage language) async {
    final requeued = await records.requeueJobs(recordId, language);
    if (requeued == 0) return false;
    final jobs = await records.pendingJobs(limit: 4);
    for (final job in jobs) {
      if (job.recordId == recordId && job.targetLanguage == language) {
        await runJob(job);
        return true;
      }
    }
    return false;
  }

  Future<VerseTranslation?> _lookupCurated(List<MatchedVerse> matches, TargetLanguage language) async {
    if (editions.editionId == null) return null;
    final available = editions.availableVerseKeys(language);
    for (final match in matches) {
      if (available != null && !available.contains(match.ref)) return null;
      final found = await editions.find(verseKey: match.ref, language: language);
      if (found == null) return null;
    }
    // 多节时按顺序拼接，保持子段顺序。
    final parts = <String>[];
    for (final match in matches) {
      final found = await editions.find(verseKey: match.ref, language: language);
      if (found == null) return null;
      parts.add(found.text);
    }
    return VerseTranslation(
      editionId: editions.editionId!,
      translator: 'unknown',
      version: 'unknown',
      language: language,
      verseKey: matches.map((match) => match.ref).join(','),
      text: parts.join(' '),
    );
  }

  /// 按匹配范围拼接标准原文；半节只取确认的词范围。
  String _canonicalText(List<MatchedVerse> matches) {
    final parts = <String>[];
    for (final match in matches) {
      final sourceText = library.verse(match.surah, match.ayah)?.textUthmani ?? '';
      parts.add(
        TranslationPreprocessor.canonical(
          sourceText,
          wordStart: match.wordStart,
          wordEnd: match.wordEnd,
        ),
      );
    }
    return parts.join(' ').trim();
  }

  Future<void> _writeTranslation({
    required UtteranceRecord record,
    required TargetLanguage language,
    required String provider,
    required TranslationSourceKind sourceKind,
    required String sourceHash,
    required String inputScope,
    required String text,
    required TranslationStatus status,
    String? engineId,
    String? editionId,
    String? errorCode,
    int? elapsedMs,
  }) async {
    await records.saveTranslation(
      RecordTranslation(
        id: '${record.id}:${record.revision}:${language.code}:$provider',
        recordId: record.id,
        revision: record.revision,
        targetLanguage: language,
        provider: provider,
        sourceKind: sourceKind,
        sourceHash: sourceHash,
        inputScope: inputScope,
        text: text,
        status: status,
        createdAt: DateTime.now().toUtc(),
        editionId: editionId,
        engineId: engineId,
        errorCode: errorCode,
        elapsedMs: elapsedMs,
      ),
    );
  }

  /// FNV-1a 64 位稳定哈希。
  ///
  /// 仅用于缓存键与幂等键，不用于安全用途；不引入额外加密依赖。
  ///
  /// @param text 输入文本
  /// @return 16 位十六进制字符串
  static String _stableHash(String text) {
    const int offset = 0xcbf29ce484222325;
    const int prime = 0x100000001b3;
    var hash = offset;
    for (final byte in utf8.encode(text)) {
      hash ^= byte;
      hash = (hash * prime) & 0xFFFFFFFFFFFFFFFF;
    }
    return hash.toUnsigned(64).toRadixString(16).padLeft(16, '0');
  }
}
