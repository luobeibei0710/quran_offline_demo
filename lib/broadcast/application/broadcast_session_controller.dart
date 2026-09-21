/// 广播会话控制器：权限、收音、断句、终稿、匹配、保存与翻译调度。
///
/// 设计要点：
///
/// - **单模型串行**：任何时刻最多一个 ORT 推理在执行，预览与终稿共享该约束；
/// - **终稿优先**：终稿队列上限有限，超载时丢弃预览而不是丢弃终稿音频，
///   持续超载会明确提示而不是静默丢录音；
/// - **有界内存**：只保留「当前片段 + 重叠 + 有限待处理片段」，不保留整场录音；
/// - **停止幂等且不丢末句**：停止时先停采样，再等待在途推理，最后处理剩余片段；
/// - **翻译异步**：记录与翻译任务同事务落库，翻译在后台串行执行，失败保留可重试，
///   不阻塞停止流程。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/broadcast_corpus.dart';
import '../data/record_repository.dart';
import '../domain/utterance_record.dart';
import 'broadcast_transcriber.dart';
import 'microphone_source.dart';
import 'quran_match_service.dart';
import 'translation_coordinator.dart';
import 'utterance_segmenter.dart';

/// 识别进行中的实时预览：转写草稿、候选经文与预览译文。
///
/// 三栏在片段进行中即同步刷新；预览匹配标注为「候选」，不落库、不产生历史记录，
/// 终稿确认后由 [UtteranceRecord] 取代。
class BroadcastPreview {
  /// 构造预览。
  ///
  /// @param draftText 实际 ASR 草稿
  /// @param outcome 候选匹配结果
  /// @param translationText 预览译文（尚未生成时为 null）
  /// @param translationSource 预览译文来源标签
  /// @param translationPending 预览译文是否正在生成
  const BroadcastPreview({
    required this.draftText,
    required this.outcome,
    this.translationText,
    this.translationSource,
    this.translationPending = false,
  });

  /// 实际 ASR 草稿。
  final String draftText;

  /// 候选匹配结果。
  final BroadcastMatchOutcome outcome;

  /// 预览译文。
  final String? translationText;

  /// 预览译文来源标签。
  final String? translationSource;

  /// 预览译文是否正在生成。
  final bool translationPending;

  /// 复制并更新预览。
  BroadcastPreview copyWith({
    String? draftText,
    BroadcastMatchOutcome? outcome,
    String? translationText,
    String? translationSource,
    bool? translationPending,
  }) => BroadcastPreview(
    draftText: draftText ?? this.draftText,
    outcome: outcome ?? this.outcome,
    translationText: translationText ?? this.translationText,
    translationSource: translationSource ?? this.translationSource,
    translationPending: translationPending ?? this.translationPending,
  );
}

/// 会话状态。
enum BroadcastSessionStatus {
  /// 空闲，可开始。
  idle,

  /// 正在申请权限 / 打开音源。
  starting,

  /// 正在识别。
  running,

  /// 正在完成最后一句并落库。
  finishing,
}

/// 广播会话控制器。
class BroadcastSessionController extends ChangeNotifier {
  /// 构造控制器。
  ///
  /// @param transcriber 片段转写器
  /// @param matcher 新库匹配服务
  /// @param records 记录仓储
  /// @param translations 翻译协调器
  /// @param audio 音源
  /// @param library 新库语料库
  /// @param targetLanguage 初始目标语言（新记录创建时冻结）
  /// @param segmenterConfig 断句参数
  /// @param previewIntervalSeconds 实时草稿的最小刷新间隔
  BroadcastSessionController({
    required this.transcriber,
    required this.matcher,
    required this.records,
    required this.translations,
    required this.audio,
    required this.library,
    TargetLanguage targetLanguage = TargetLanguage.simplifiedChinese,
    this.segmenterConfig = const UtteranceSegmenterConfig(),
    this.previewIntervalSeconds = 2,
  }) : _targetLanguage = targetLanguage;

  /// 片段转写器。
  final BroadcastTranscriber transcriber;

  /// 匹配服务。
  final QuranMatchService matcher;

  /// 记录仓储。
  final RecordRepository records;

  /// 翻译协调器。
  final TranslationCoordinator translations;

  /// 音源。
  final AudioCaptureSource audio;

  /// 语料库。
  final BroadcastQuranLibrary library;

  /// 断句参数。
  final UtteranceSegmenterConfig segmenterConfig;

  /// 预览刷新间隔（秒）。
  final double previewIntervalSeconds;

  /// 终稿队列上限：超过则停止接收并提示（避免静默丢弃录音）。
  static const int finalQueueLimit = 3;

  TargetLanguage _targetLanguage;
  BroadcastSessionStatus _status = BroadcastSessionStatus.idle;
  String _draftText = '';
  String? _statusMessage;
  int _recordCount = 0;
  final List<UtteranceRecord> _recent = <UtteranceRecord>[];

  /// 识别进行中的三栏预览（匹配候选 + 预览译文），终稿确认后清空。
  BroadcastPreview? _preview;
  String? _lastPreviewRef;
  int _previewStableCount = 0;
  bool _previewTranslating = false;
  final Map<String, String> _previewTranslationMemo = <String, String>{};

  /// 预览匹配用轻配置：topK 减半以控制预览开销；终稿仍用完整配置。
  late final QuranMatchService _previewMatcher = QuranMatchService(
    library: library,
    config: const BroadcastMatchConfig(topK: 16),
  );

  UtteranceSegmenter? _segmenter;
  StreamSubscription<Float32List>? _audioSubscription;
  final List<SpeechSegment> _finalQueue = <SpeechSegment>[];
  bool _busy = false;
  bool _finishing = false;
  double _lastPreviewAt = 0;
  int _queueOverflowCount = 0;
  String _sessionId = UtteranceRecord.newUuid();

  /// 会话状态。
  BroadcastSessionStatus get status => _status;

  /// 是否正在识别（含收尾）。
  bool get isRunning =>
      _status == BroadcastSessionStatus.running || _status == BroadcastSessionStatus.finishing;

  /// 当前片段草稿（实际 ASR 输出，未匹配、未翻译）。
  String get draftText => _draftText;

  /// 识别进行中的三栏预览：转写草稿、候选经文与预览译文同步刷新。
  BroadcastPreview? get preview => _preview;

  /// 状态提示（权限、超载、错误等）。
  String? get statusMessage => _statusMessage;

  /// 创建记录时冻结的目标语言。
  TargetLanguage get targetLanguage => _targetLanguage;

  /// 历史总数。
  int get recordCount => _recordCount;

  /// 最近记录（新到旧）。
  List<UtteranceRecord> get recentRecords => List<UtteranceRecord>.unmodifiable(_recent);

  /// 当前会话已保存的记录数（用于停止时汇报本次结果）。
  int _sessionSaved = 0;

  /// 会话内估计的安静本底，可用于界面提示收音强度。
  double get quietBaseline => _segmenter?.quietBaseline ?? 0;

  /// 切换目标语言（仅空闲时允许，避免一句中途混语言）。
  ///
  /// @param language 新目标语言
  /// @return 是否切换成功
  bool updateTargetLanguage(TargetLanguage language) {
    if (isRunning) return false;
    _targetLanguage = language;
    notifyListeners();
    return true;
  }

  /// 刷新历史总数与最近记录。
  Future<void> refreshHistory() async {
    _recordCount = await records.count();
    final page = await records.page(limit: 10);
    _recent
      ..clear()
      ..addAll(page);
    notifyListeners();
  }

  /// 开始识别（幂等：已在运行时直接返回）。
  ///
  /// @return 是否成功进入识别状态
  Future<bool> start() async {
    if (isRunning) return true;
    _status = BroadcastSessionStatus.starting;
    _statusMessage = null;
    notifyListeners();

    if (!await audio.ensurePermission()) {
      _status = BroadcastSessionStatus.idle;
      _statusMessage = '未授予麦克风权限';
      notifyListeners();
      return false;
    }
    try {
      _segmenter = UtteranceSegmenter(
        sampleRate: transcriber.sampleRate,
        config: segmenterConfig,
      );
      _finalQueue.clear();
      _queueOverflowCount = 0;
      _draftText = '';
      _lastPreviewAt = 0;
      _clearPreview();
      final stream = await audio.start();
      _status = BroadcastSessionStatus.running;
      _sessionSaved = 0;
      debugPrint(
        '[Broadcast] 开始识别：目标语言 ${_targetLanguage.code}，'
        '断句 静音≥${segmenterConfig.silenceSeconds}s / 最短 ${segmenterConfig.minSpeechSeconds}s / '
        '最长 ${segmenterConfig.maxSeconds}s',
      );
      notifyListeners();
      _audioSubscription = stream.listen(
        _onChunk,
        onError: (Object error) {
          _statusMessage = '音频中断：$error';
          notifyListeners();
          unawaited(stop());
        },
        cancelOnError: false,
      );
      return true;
    } catch (error) {
      await audio.stop();
      _status = BroadcastSessionStatus.idle;
      _statusMessage = '无法开始收音：$error';
      notifyListeners();
      return false;
    }
  }

  /// 停止识别（幂等），并保证最后一个片段被保存。
  Future<void> stop() async {
    if (_status == BroadcastSessionStatus.idle || _finishing) return;
    _finishing = true;
    _status = BroadcastSessionStatus.finishing;
    _statusMessage = '正在完成最后一句…';
    notifyListeners();

    await _audioSubscription?.cancel();
    _audioSubscription = null;
    await audio.stop();

    // 等待在途推理结束，避免与收尾片段抢模型。
    while (_busy) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final segmenter = _segmenter;
    if (segmenter != null) {
      final last = segmenter.flush();
      if (last != null) _finalQueue.add(last);
    }
    await _drainFinalQueue();

    debugPrint(
      '[Broadcast] 停止识别：本次会话保存 $_sessionSaved 条记录'
      '${_queueOverflowCount > 0 ? '，另有 $_queueOverflowCount 个片段因过载被丢弃' : ''}',
    );
    _status = BroadcastSessionStatus.idle;
    _finishing = false;
    _statusMessage = _queueOverflowCount > 0
        ? '本次有 $_queueOverflowCount 个片段因过载未处理，请降低输入频率'
        : null;
    _draftText = '';
    _clearPreview();
    notifyListeners();
  }

  void _onChunk(Float32List chunk) {
    final segmenter = _segmenter;
    if (segmenter == null || _status != BroadcastSessionStatus.running) return;
    segmenter.addChunk(chunk);

    final onSilence = segmenter.takeOnSilence();
    if (onSilence != null) _enqueueFinal(onSilence);
    final forced = segmenter.takeOnMaxDuration();
    if (forced != null) _enqueueFinal(forced);

    unawaited(_drainFinalQueue());
    unawaited(_maybePreview());
  }

  void _enqueueFinal(SpeechSegment segment) {
    if (!segment.hasSpeech) return;
    if (_finalQueue.length >= finalQueueLimit) {
      // 超载：丢弃最旧的排队片段并计数，界面会明确提示，不静默丢录音。
      _finalQueue.removeAt(0);
      _queueOverflowCount++;
      debugPrint('[Broadcast] 终稿队列超载：丢弃最旧片段，累计丢弃 $_queueOverflowCount 次');
    }
    _finalQueue.add(segment);
  }

  /// 串行处理终稿（终稿优先于预览）。
  Future<void> _drainFinalQueue() async {
    if (_busy) return;
    while (_finalQueue.isNotEmpty) {
      final segment = _finalQueue.removeAt(0);
      _busy = true;
      try {
        await _processFinal(segment);
      } catch (error) {
        _statusMessage = '保存失败：$error';
        notifyListeners();
      } finally {
        _busy = false;
      }
    }
  }

  Future<void> _processFinal(SpeechSegment segment) async {
    final watch = Stopwatch()..start();
    final fragment = await transcriber.transcribe(
      segment.samples,
      offsetSample: segment.startSample,
    );
    final seconds = (segment.endSample - segment.startSample) / transcriber.sampleRate;
    if (fragment.isEmpty) {
      // 纯噪声：不建伪句，也不产生伪经文。
      debugPrint(
        '[Broadcast] 片段 ${segment.startSample}-${segment.endSample}（${seconds.toStringAsFixed(1)}s，'
        '${segment.reason.name}）无有效语音内容，不建记录',
      );
      return;
    }
    final outcome = matcher.match(fragment);
    if (outcome.asrText.trim().isEmpty) return;
    debugPrint(
      '[Broadcast] 片段 ${seconds.toStringAsFixed(1)}s（${segment.reason.name}）'
      '识别分段 ${fragment.segments.length} 段 → '
      '状态=${outcome.status.name} 范围=${outcome.scope.name} '
      '候选=${outcome.candidateRef ?? '-'} '
      '解释比例=${outcome.precision?.toStringAsFixed(2) ?? '-'} '
      '覆盖=${outcome.coverage?.toStringAsFixed(2) ?? '-'} '
      '置信=${outcome.confidence?.toStringAsFixed(2) ?? '-'} '
      '词数=${fragment.words.length}'
      '${outcome.rejectionReason == null ? '' : ' 原因=${outcome.rejectionReason}'}',
    );
    debugPrint('[Broadcast] 实际转写：${outcome.asrText}');

    final job = outcome.needsTranslation
        ? TranslationJob(
            id: 'job-${UtteranceRecord.newUuid()}',
            recordId: 'pending',
            revision: 1,
            targetLanguage: _targetLanguage,
            provider: translations.engine.engineId,
            sourceHash: 'pending',
            state: TranslationJobState.pending,
            attemptCount: 0,
            createdAt: DateTime.now().toUtc(),
          )
        : null;
    final record = await records.save(
      RecordDraft(
        sessionId: _sessionId,
        utteranceId: 'utt-${segment.startSample}-${segment.endSample}',
        startSample: segment.startSample,
        endSample: segment.endSample,
        sampleRate: transcriber.sampleRate,
        boundaryReason: switch (segment.reason) {
          SegmentBoundary.silence => BoundaryReason.silence,
          SegmentBoundary.maxDuration => BoundaryReason.maxDuration,
          SegmentBoundary.stopped => BoundaryReason.stopped,
        },
        rawAsrText: outcome.asrText,
        targetLanguage: _targetLanguage,
        matchStatus: outcome.status,
        scope: outcome.scope,
        matches: outcome.matches,
        metrics: outcome.metrics,
        job: job,
        matcherEvidenceJson: outcome.evidenceJson,
      ),
    );
    _recordCount++;
    _sessionSaved++;
    _recent.insert(0, record);
    if (_recent.length > 20) _recent.removeLast();
    _draftText = '';
    // 终稿已确认：清空预览，三栏切换为已确认记录（新片段从空草稿开始）。
    _clearPreview();
    watch.stop();
    debugPrint(
      '[Broadcast] 记录 #${record.displaySequence} 已保存'
      '（${record.matchSummary}，${record.matchStatus.name}/${record.scope.wireName}，'
      'F1=${record.metrics?.f1?.toStringAsFixed(3) ?? '不可用'}，'
      'WER=${record.metrics?.strictWer?.toStringAsFixed(3) ?? '不可用'}，'
      '词数 ${record.metrics?.referenceWords ?? '-'}/${record.metrics?.hypothesisWords ?? '-'}，'
      '总耗时 ${watch.elapsedMilliseconds}ms）',
    );
    notifyListeners();

    if (job != null) {
      // 翻译异步执行：失败不丢记录，可同记录重试。
      unawaited(_runTranslations());
    }
  }

  /// 实时预览：只在空闲且没有待处理终稿时执行，避免与终稿抢模型。
  ///
  /// 与只更新转写草稿不同，这里同时对同一份声学证据跑一次候选匹配，
  /// 让「转写 / 匹配经文 / 译文」三栏在片段进行中就同步刷新；
  /// 预览匹配标注为候选，不落库、不产生历史记录。
  Future<void> _maybePreview() async {
    final segmenter = _segmenter;
    if (segmenter == null || _busy || _finalQueue.isNotEmpty) return;
    if (_status != BroadcastSessionStatus.running) return;
    final elapsed = segmenter.totalSamples / transcriber.sampleRate;
    if (elapsed - _lastPreviewAt < previewIntervalSeconds) return;
    if (segmenter.pendingSeconds < previewIntervalSeconds) return;
    _lastPreviewAt = elapsed;
    _busy = true;
    try {
      final fragment = await transcriber.transcribe(
        segmenter.pendingSamples,
        offsetSample: segmenter.totalSamples - segmenter.pendingSamples.length,
      );
      if (fragment.words.isEmpty || _status != BroadcastSessionStatus.running) return;
      final matchWatch = Stopwatch()..start();
      final outcome = _previewMatcher.match(fragment);
      matchWatch.stop();
      _draftText = fragment.text;
      _preview = BroadcastPreview(draftText: fragment.text, outcome: outcome);
      debugPrint(
        '[Broadcast] 预览 ${segmenter.pendingSeconds.toStringAsFixed(1)}s：'
        '${outcome.status.name} 候选=${outcome.candidateRef ?? '-'} '
        '覆盖=${outcome.coverage?.toStringAsFixed(2) ?? '-'} '
        '置信=${outcome.confidence?.toStringAsFixed(2) ?? '-'} '
        '匹配 ${matchWatch.elapsedMilliseconds}ms'
        '${outcome.rejectionReason == null ? '' : ' 原因=${outcome.rejectionReason}'}',
      );
      _trackPreviewStability(outcome);
      notifyListeners();
    } catch (_) {
      // 预览失败不影响终稿链路。
    } finally {
      _busy = false;
    }
  }

  /// 候选经连续两次相同即触发一次预览翻译（与终稿共用缓存，不重复调引擎）。
  void _trackPreviewStability(BroadcastMatchOutcome outcome) {
    final ref = outcome.candidateRef;
    if (ref == null) {
      _lastPreviewRef = null;
      _previewStableCount = 0;
      return;
    }
    if (ref != _lastPreviewRef) {
      _lastPreviewRef = ref;
      _previewStableCount = 1;
      return;
    }
    _previewStableCount++;
    if (_previewStableCount == 2) unawaited(_translatePreview(outcome));
  }

  /// 预览译文：命中内存或数据库缓存时零成本返回；未命中调一次引擎并写入缓存，
  /// 片段结束后的正式翻译通常直接命中，不会重复调用。
  Future<void> _translatePreview(BroadcastMatchOutcome outcome) async {
    if (_previewTranslating || _status != BroadcastSessionStatus.running) return;
    final language = _targetLanguage;
    final matched = outcome.matches.isNotEmpty;
    final memoKey = '${language.code}:${matched ? outcome.matches.map((match) => match.ref).join(',') : outcome.asrText}';
    if (memoKey.length > 1 && !memoKey.endsWith(':')) {
      final memo = _previewTranslationMemo[memoKey];
      if (memo != null) {
        _preview = _preview?.copyWith(
          translationText: memo,
          translationSource: _previewSourceLabel(matched, language),
          translationPending: false,
        );
        notifyListeners();
        return;
      }
    }
    _previewTranslating = true;
    _preview = _preview?.copyWith(translationText: null, translationSource: null, translationPending: true);
    notifyListeners();
    try {
      final text = await translations.translatePreview(
        matches: outcome.matches,
        asrText: outcome.asrText,
        language: language,
      );
      // 候选已切换：丢弃过期译文，等下一轮稳定再取（通常已入缓存）。
      if (_preview == null || _preview!.outcome.candidateRef != outcome.candidateRef) return;
      if (text != null && text.trim().isNotEmpty) {
        _previewTranslationMemo[memoKey] = text;
        _preview = _preview!.copyWith(
          translationText: text,
          translationSource: _previewSourceLabel(matched, language),
          translationPending: false,
        );
        debugPrint('[Broadcast] 预览译文：${text.length > 40 ? '${text.substring(0, 40)}…' : text}');
      } else {
        _preview = _preview!.copyWith(translationPending: false);
      }
      notifyListeners();
    } finally {
      _previewTranslating = false;
    }
  }

  static String _previewSourceLabel(bool matched, TargetLanguage language) =>
      '${language.label} · ${matched ? '机器翻译·标准原文' : '机器翻译·识别转写'}（预览）';

  /// 终稿确认或会话结束后清空预览（三栏切换为已确认记录）。
  void _clearPreview() {
    _preview = null;
    _lastPreviewRef = null;
    _previewStableCount = 0;
  }

  Future<void> _runTranslations() async {
    try {
      await translations.drain();
      await refreshHistory();
    } catch (_) {
      // 翻译失败已经落库为状态，界面可重试。
    }
  }

  /// 开始一次新的逻辑会话（清空当前草稿与队列，历史记录不受影响）。
  void startNewSession() {
    _sessionId = UtteranceRecord.newUuid();
    _segmenter?.reset();
    _finalQueue.clear();
    _draftText = '';
    _clearPreview();
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_audioSubscription?.cancel());
    unawaited(audio.stop());
    super.dispose();
  }
}
