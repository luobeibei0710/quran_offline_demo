/// 翻译协调器：来源策略、输入预处理、串行任务、缓存与失败重试。
///
/// 来源策略固定为用户确认的 `editionPreferredWithMachineFallback`：
///
/// | 情形 | 来源 | 输入文本 |
/// |---|---|---|
/// | 匹配到节且有授权校订译本（整节） | `curatedEdition` | 直接查表，不过机器翻译 |
/// | 匹配到节且有授权校订译本（半节或候选） | `curatedEdition` | 整节译本，界面标注「整节译文（上下文）」 |
/// | 匹配到节但译本缺失 | `machineCanonical` | 新库标准原文（保留音标与原始顺序） |
/// | 未匹配 | `machineAsr` | 实际 ASR 转写 |
///
/// 其余硬性规则：
///
/// - **半节不得冒充精确译文**：半节取到的整节译本必须以
///   `inputScope = fullVerseContext` 落库、由界面标注为「整节译文（上下文）」；
///   只有在权威译本确实缺失时才退回机器翻译（`confirmedRange`，界面标注
///   「仅已确认范围」）；
/// - 缓存键包含 `输入哈希 + 语料版本 + 目标语言 + 提供方 + 引擎代号 + 预处理版本`，
///   引擎升级或语言包重新准备后主动失效；
/// - 失败不丢记录：译文行写失败状态，任务保留可重试；
/// - 迟到结果由 [RecordRepository.saveTranslation] 二次校验 `recordId /
///   revision / targetLanguage`，过期即丢弃，既不会覆盖新句，也不会复活已删记录。
library;

import 'dart:async';
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
    final words = sourceText
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .toList();
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

/// 预览译文及其真实来源；预览不写入记录表。
class PreviewTranslation {
  /// 构造预览结果。
  const PreviewTranslation({
    required this.text,
    required this.sourceKind,
    required this.inputScope,
    this.editionLabel,
  });

  /// 译文正文。
  final String text;

  /// 译文真实来源。
  final TranslationSourceKind sourceKind;

  /// 与正式译文一致的输入范围说明。
  final String inputScope;

  /// 校订译本的署名；机器翻译时为空。
  final String? editionLabel;
}

/// 翻译协调器。
class TranslationCoordinator {
  /// 构造协调器。
  ///
  /// @param engine 离线翻译引擎
  /// @param records 记录仓储
  /// @param library 全经语料库（提供标准原文）
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

  Future<int>? _drainFuture;
  bool _drainAgain = false;
  Future<void> _translationTail = Future<void>.value();
  final Map<String, Future<TranslationResult>> _inFlightTranslations =
      <String, Future<TranslationResult>>{};

  /// 预览与正式任务共用同一端侧引擎，保证原生 translator 不被并发调用。
  /// 相同输入同时由预览和终稿请求时，共用一次在途翻译。
  Future<TranslationResult> _translateSerial(
    TranslationRequest request,
    String cacheKey,
  ) {
    final existing = _inFlightTranslations[cacheKey];
    if (existing != null) return existing;
    final task = _translationTail.then((_) => engine.translate(request));
    _inFlightTranslations[cacheKey] = task;
    _translationTail = task.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    unawaited(
      task.then<void>(
        (_) {
          _inFlightTranslations.remove(cacheKey);
        },
        onError: (Object _, StackTrace _) {
          _inFlightTranslations.remove(cacheKey);
        },
      ),
    );
    return task;
  }

  /// 提前把目标语言校订译本载入内存；失败不影响收音和终稿。
  Future<void> warmLanguage(TargetLanguage language) async {
    if (editions.editionIdFor(language) == null) return;
    try {
      await editions.find(verseKey: '1:1', language: language);
    } catch (error) {
      debugPrint('[Broadcast] 译本预热失败：$error');
    }
  }

  /// 一次 drain 最多处理的任务数（长会话下避免一次卡太久）。
  static const int defaultDrainLimit = 8;

  /// 决定该记录的来源与输入文本。
  ///
  /// @param record 记录
  /// @param language 目标语言
  /// @return 输入与来源
  Future<TranslationInput> resolveInput(
    UtteranceRecord record,
    TargetLanguage language,
  ) => resolveInputFor(
    matches: record.matches,
    asrText: record.rawAsrText,
    language: language,
    matched: record.matchStatus.isMatched,
  );

  /// 与 [resolveInput] 同一套来源规则，但允许没有持久记录的调用方（实时预览）使用。
  ///
  /// @param matches 匹配范围（可为空）
  /// @param asrText 实际转写
  /// @param language 目标语言
  /// @param matched 是否处于已匹配状态
  /// @return 输入与来源
  Future<TranslationInput> resolveInputFor({
    required List<MatchedVerse> matches,
    required String asrText,
    required TargetLanguage language,
    required bool matched,
  }) async {
    final text = asrText.trim();
    // 判据是「有没有匹配到节」，而不是「记录是否已达 confirmed」。
    //
    // 曾经用 `!matched` 一并拦在这里，于是 `candidate` 状态（有明确候选、只是
    // 可信度未达确认门槛）也走机器翻译。真机 11 条记录里 10 条落入机翻分支，
    // 译文退化成乱码。
    if (matches.isEmpty) {
      // 未匹配：翻译实际 ASR 转写，原文与匹配指标留空。
      return TranslationInput(
        kind: TranslationInputKind.asr,
        sourceKind: TranslationSourceKind.machineAsr,
        text: text,
        inputScope: 'asr',
      );
    }

    // 已匹配：优先查授权校订译本。
    //
    // 半节/候选同样走这条路。旧规则是「半节一律机器翻译，以免整节译本冒充精确
    // 译文」，但实测 ML Kit 对带音标的古兰经阿拉伯语几乎无效（真机输出
    // `As ٱلقلوب ٱلقلوب ٱلقلوب…` 这种重复词乱码，`status` 却仍是 done），
    // 而连续诵读下片段边界几乎不落在节边界，于是「整节 + confirmed」是少数情况，
    // 权威译本实际被整体绕过。授权译本即便只作为上下文，也远好于乱码。
    // 用 `fullVerseContext` 明确标记这种「整节译本用于半节片段」，由界面标注，
    // 不冒充精确译文。
    final ordered = <MatchedVerse>[...matches]
      ..sort((a, b) => a.ordinal.compareTo(b.ordinal));
    final wholeVerses = ordered.every((match) => match.isWholeVerse);
    final curated = await _lookupCurated(ordered, language);
    if (curated != null) {
      return TranslationInput(
        kind: TranslationInputKind.canonical,
        sourceKind: TranslationSourceKind.curatedEdition,
        text: curated.text,
        inputScope: wholeVerses ? 'fullVerses' : 'fullVerseContext',
        curated: curated,
      );
    }
    return TranslationInput(
      kind: TranslationInputKind.canonical,
      sourceKind: TranslationSourceKind.machineCanonical,
      text: _canonicalText(ordered),
      inputScope: wholeVerses ? 'fullVerses' : 'confirmedRange',
    );
  }

  /// 预览翻译：与终稿共用同一套来源规则、缓存键与缓存表。
  ///
  /// 识别进行中即可调用：缓存命中时直接返回（零成本），未命中时调用一次引擎并把
  /// 结果写入缓存 —— 因此片段结束后的正式翻译通常直接命中，不会重复调用引擎。
  /// 预览结果**不**写任何记录行，落库仍只发生在终稿。
  ///
  /// @param matches 当前候选匹配范围（可为空）
  /// @param asrText 实际转写
  /// @param language 目标语言
  /// @return 译文与来源；缺语言包或引擎失败时返回 null
  Future<PreviewTranslation?> translatePreview({
    required List<MatchedVerse> matches,
    required String asrText,
    required TargetLanguage language,
  }) async {
    try {
      final input = await resolveInputFor(
        matches: matches,
        asrText: asrText,
        language: language,
        matched: matches.isNotEmpty,
      );
      if (input.text.trim().isEmpty) return null;
      PreviewTranslation previewResult(String text) => PreviewTranslation(
        text: text,
        sourceKind: input.sourceKind,
        inputScope: input.inputScope,
        editionLabel: input.curated?.label,
      );
      if (input.sourceKind == TranslationSourceKind.curatedEdition) {
        return previewResult(input.text);
      }
      final provider = engine.engineId;
      final cacheKey = cacheKeyFor(
        input,
        language,
        provider: provider,
        engineId: engine.engineId,
        generation: engine.generation,
      );
      final cached = await records.readCache(cacheKey);
      if (cached != null) return previewResult(cached);
      final result = await _translateSerial(
        TranslationRequest(
          recordId: 'preview',
          revision: 0,
          inputText: input.text,
          inputKind: input.kind,
          sourceHash: 'preview',
          targetLanguage: language,
        ),
        cacheKey,
      );
      await records.writeCache(
        cacheKey,
        result.text,
        provider: provider,
        sourceKind: input.sourceKind,
        engineId: result.engineId,
      );
      return previewResult(result.text);
    } on TranslationException catch (error) {
      debugPrint(
        '[Broadcast] 预览翻译不可用：${error.code.wireName} — ${error.message}',
      );
      return null;
    } catch (error) {
      debugPrint('[Broadcast] 预览翻译失败：$error');
      return null;
    }
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
    language.id,
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
      await records.updateJobState(
        job.id,
        TranslationJobState.failed,
        error: '记录已删除',
      );
      return TranslationStatus.failed;
    }
    final language = job.targetLanguage;
    final provider = engine.engineId;
    final input = await resolveInput(record, language);
    final sourceHash = _stableHash(input.text);
    debugPrint(
      '[Broadcast] 翻译任务：记录 #${record.displaySequence} 语言=${language.displayName} '
      '来源=${input.sourceKind.wireName} 范围=${input.inputScope} '
      '输入 ${input.text.length} 字符',
    );
    final cacheKey = cacheKeyFor(
      input,
      language,
      provider: input.sourceKind == TranslationSourceKind.curatedEdition
          ? 'curated'
          : provider,
      engineId: engine.engineId,
      generation: engine.generation,
    );

    // 占位行与结果行必须使用同一个 provider：译文行的唯一约束是
    // (recordId, revision, targetLanguage, provider)，若「进行中」用 engineId、
    // 结果用 curated，就会在同一记录同一语言下留下两行；两行 created_at 同毫秒时
    // 取译文的顺序不确定，界面可能读到空占位。
    final effectiveProvider =
        input.sourceKind == TranslationSourceKind.curatedEdition
        ? 'curated'
        : provider;

    await records.updateJobState(
      job.id,
      TranslationJobState.running,
      incrementAttempt: true,
    );
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
      final result = await _translateSerial(
        TranslationRequest(
          recordId: record.id,
          revision: record.revision,
          inputText: input.text,
          inputKind: input.kind,
          sourceHash: sourceHash,
          targetLanguage: language,
        ),
        cacheKey,
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
      final preview = result.text.length > 60
          ? '${result.text.substring(0, 60)}…'
          : result.text;
      debugPrint(
        '[Broadcast] 翻译完成：$preview（${result.elapsedMs}ms，${result.engineId}）',
      );
      return TranslationStatus.done;
    } on TranslationException catch (error) {
      debugPrint('[Broadcast] 翻译失败：${error.code.wireName} — ${error.message}');
      final status =
          error.code == TranslationErrorCode.modelMissing ||
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
      await records.updateJobState(
        job.id,
        TranslationJobState.failed,
        error: '$error',
      );
      return TranslationStatus.failed;
    }
  }

  /// 串行处理待办任务（主进程最多 1 个翻译在跑）。
  ///
  /// @param limit 本次最多处理条数
  /// @return 处理过的任务数
  Future<int> drain({int limit = defaultDrainLimit}) {
    final running = _drainFuture;
    if (running != null) {
      _drainAgain = true;
      return running;
    }
    final completion = Completer<int>();
    _drainFuture = completion.future;
    unawaited(
      _runDrain(limit).then(
        (count) {
          _drainFuture = null;
          completion.complete(count);
        },
        onError: (Object error, StackTrace stack) {
          _drainFuture = null;
          completion.completeError(error, stack);
        },
      ),
    );
    return completion.future;
  }

  /// 关闭共享引擎与数据库前，等待所有在途的翻译调用和待办处理。
  Future<void> waitForIdle() async {
    await _drainFuture;
    await _translationTail;
  }

  Future<int> _runDrain(int limit) async {
    var processed = 0;
    do {
      _drainAgain = false;
      final jobs = await records.pendingJobs(limit: limit);
      for (final job in jobs) {
        await runJob(job);
        processed++;
      }
    } while (_drainAgain);
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

  Future<VerseTranslation?> _lookupCurated(
    List<MatchedVerse> matches,
    TargetLanguage language,
  ) async {
    final editionId = editions.editionIdFor(language);
    if (editionId == null) return null;
    final available = editions.availableVerseKeys(language);
    // 要求**每一节**都能查到：一个片段里一半用译本、一半用机器翻译会让来源标记
    // 含混不清，这种情况下整体回退机器翻译（调用方会据此标 confirmedRange）。
    final parts = <String>[];
    String? publisher;
    String? version;
    for (final match in matches) {
      if (available != null && !available.contains(match.ref)) return null;
      final found = await editions.find(
        verseKey: match.ref,
        language: language,
      );
      if (found == null) return null;
      parts.add(found.text);
      publisher ??= found.translator;
      version ??= found.version;
    }
    if (parts.isEmpty) return null;
    return VerseTranslation(
      editionId: editionId,
      translator: publisher ?? editionId,
      version: version ?? 'unknown',
      language: language,
      verseKey: matches.map((match) => match.ref).join(','),
      text: parts.join(' '),
    );
  }

  /// 按匹配范围拼接标准原文；半节只取确认的词范围。
  String _canonicalText(List<MatchedVerse> matches) {
    final parts = <String>[];
    for (final match in matches) {
      final sourceText =
          library.verse(match.surah, match.ayah)?.textUthmani ?? '';
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
        id: '${record.id}:${record.revision}:${language.id}:$provider',
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
