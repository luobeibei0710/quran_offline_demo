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
import 'broadcast_latency_trace.dart';
import 'broadcast_transcriber.dart';
import 'microphone_source.dart';
import 'quran_match_service.dart';
import 'screen_keep_on.dart';
import 'translation_coordinator.dart';
import 'utterance_segmenter.dart';

/// 识别进行中的实时预览：转写草稿、候选经文与预览译文。
///
/// 三栏在片段进行中即同步刷新；预览匹配标注为「候选」，不落库、不产生历史记录，
/// 终稿确认后由 [UtteranceRecord] 取代。
class BroadcastPreview {
  static const Object _keep = Object();

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
    required this.sessionEpoch,
    required this.utteranceStartSample,
    required this.audioStartSample,
    required this.audioEndSample,
    required this.audioReceivedAtUs,
    required this.revision,
    required this.candidateGeneration,
    required this.candidateKey,
    this.translationText,
    this.translationSource,
    this.translationSourceKind,
    this.translationInputScope,
    this.translationPending = false,
  });

  /// 同一次开始识别的版本，避免重启后的迟到结果回写。
  final int sessionEpoch;

  /// 当前待确认片段的绝对起点。
  final int utteranceStartSample;

  /// 本轮有界预览窗口的绝对起点。
  final int audioStartSample;

  /// 本轮预览已听到的绝对音频终点。
  final int audioEndSample;

  /// 窗口末块音频进入控制器时的单调时钟时间。
  final int audioReceivedAtUs;

  /// 同一会话中单调递增的预览序号。
  final int revision;

  /// 候选每次切换都会递增，防止 A→B→A 的迟到结果回写。
  final int candidateGeneration;

  /// 经文及节内词范围组成的稳定键。
  final String candidateKey;

  /// 实际 ASR 草稿。
  final String draftText;

  /// 候选匹配结果。
  final BroadcastMatchOutcome outcome;

  /// 预览译文。
  final String? translationText;

  /// 预览译文来源标签。
  final String? translationSource;

  /// 译文的真实来源。
  final TranslationSourceKind? translationSourceKind;

  /// 译文适用范围（整节、整节上下文或已确认范围）。
  final String? translationInputScope;

  /// 预览译文是否正在生成。
  final bool translationPending;

  /// 复制并更新预览。
  BroadcastPreview copyWith({
    String? draftText,
    BroadcastMatchOutcome? outcome,
    Object? translationText = _keep,
    Object? translationSource = _keep,
    Object? translationSourceKind = _keep,
    Object? translationInputScope = _keep,
    bool? translationPending,
  }) => BroadcastPreview(
    draftText: draftText ?? this.draftText,
    outcome: outcome ?? this.outcome,
    sessionEpoch: sessionEpoch,
    utteranceStartSample: utteranceStartSample,
    audioStartSample: audioStartSample,
    audioEndSample: audioEndSample,
    audioReceivedAtUs: audioReceivedAtUs,
    revision: revision,
    candidateGeneration: candidateGeneration,
    candidateKey: candidateKey,
    translationText: identical(translationText, _keep)
        ? this.translationText
        : translationText as String?,
    translationSource: identical(translationSource, _keep)
        ? this.translationSource
        : translationSource as String?,
    translationSourceKind: identical(translationSourceKind, _keep)
        ? this.translationSourceKind
        : translationSourceKind as TranslationSourceKind?,
    translationInputScope: identical(translationInputScope, _keep)
        ? this.translationInputScope
        : translationInputScope as String?,
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
  /// @param trace 结构化时延记录器；为 null（默认）时不产生任何事件
  BroadcastSessionController({
    required this.transcriber,
    required this.matcher,
    required this.records,
    required this.translations,
    required this.audio,
    required this.library,
    TargetLanguage targetLanguage = TargetLanguage.chinese,
    this.segmenterConfig = const UtteranceSegmenterConfig(),
    this.previewIntervalSeconds = 1,
    this.previewWindowSeconds = 12,
    this.trace,
  }) : assert(previewIntervalSeconds > 0),
       assert(previewWindowSeconds >= previewIntervalSeconds),
       _targetLanguage = targetLanguage;

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
  ///
  /// 真机实测（Redmi 24117RK2CC）：候选匹配本身仅 6–87ms，瓶颈在间隔而非匹配；
  /// 一轮预览推理约 0.4–1s；请求合并，由串行工作泵处理最新窗口。
  final double previewIntervalSeconds;

  /// 预览最多重算最近多少秒音频；终稿始终使用完整片段。
  final double previewWindowSeconds;

  /// 结构化时延记录器；默认不启用。
  final BroadcastLatencyTrace? trace;

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
  Future<void>? _previewTranslationFuture;
  final Map<String, PreviewTranslation> _previewTranslationMemo =
      <String, PreviewTranslation>{};

  UtteranceSegmenter? _segmenter;
  StreamSubscription<Float32List>? _audioSubscription;
  final List<SpeechSegment> _finalQueue = <SpeechSegment>[];
  bool _pumping = false;
  bool _previewRequested = false;
  bool _disposed = false;
  Future<void>? _stopFuture;
  Future<void>? _shutdownFuture;
  Future<void> _backgroundTranslationTail = Future<void>.value();
  double _lastPreviewAt = 0;
  int _lastSegmentBoundaryEndSample = 0;
  int _sessionEpoch = 0;
  int _previewRevision = 0;
  int _candidateGeneration = 0;
  final Stopwatch _runtimeClock = Stopwatch();
  int _lastAudioChunkAtUs = 0;
  int _lastRenderedRevision = 0;
  int _lastRenderedTranslationGeneration = 0;
  int? _candidateStableAtUs;
  int _queueOverflowCount = 0;
  String _sessionId = UtteranceRecord.newUuid();

  /// 会话状态。
  BroadcastSessionStatus get status => _status;

  /// 是否正在识别（含收尾）。
  bool get isRunning =>
      _status == BroadcastSessionStatus.running ||
      _status == BroadcastSessionStatus.finishing;

  /// 当前片段草稿（实际 ASR 输出，未匹配、未翻译）。
  String get draftText => _draftText;

  /// 识别进行中的三栏预览：转写草稿、候选经文与预览译文同步刷新。
  BroadcastPreview? get preview => _preview;

  /// UI 首帧回调：记录音频进入到转写/候选真正可见的延迟。
  void recordPreviewRendered(BroadcastPreview frame) {
    final current = _preview;
    if (current == null ||
        current.sessionEpoch != frame.sessionEpoch ||
        current.revision != frame.revision) {
      return;
    }
    final nowUs = _runtimeClock.elapsedMicroseconds;
    if (_lastRenderedRevision != frame.revision) {
      _lastRenderedRevision = frame.revision;
      debugPrint(
        '[BroadcastLatency] preview_frame revision=${frame.revision} '
        'audio_end=${frame.audioEndSample} '
        'audio_to_frame_ms=${(nowUs - frame.audioReceivedAtUs) ~/ 1000}',
      );
      trace?.record(
        BroadcastLatencyEvent(
          kind: BroadcastLatencyEventKind.previewFrame,
          atUs: nowUs,
          sessionEpoch: frame.sessionEpoch,
          revision: frame.revision,
          candidateGeneration: frame.candidateGeneration,
          utteranceStartSample: frame.utteranceStartSample,
          audioStartSample: frame.audioStartSample,
          audioEndSample: frame.audioEndSample,
          audioReceivedAtUs: frame.audioReceivedAtUs,
          candidateRef: frame.outcome.candidateRef,
          status: frame.outcome.status.name,
          note: frame.translationText == null
              ? 'no_translation'
              : 'with_translation',
        ),
      );
    }
    if (frame.translationText != null &&
        _lastRenderedTranslationGeneration != frame.candidateGeneration) {
      _lastRenderedTranslationGeneration = frame.candidateGeneration;
      final stableAtUs = _candidateStableAtUs;
      if (stableAtUs != null) {
        debugPrint(
          '[BroadcastLatency] translation_frame revision=${frame.revision} '
          'candidate_generation=${frame.candidateGeneration} '
          'stable_to_frame_ms=${(nowUs - stableAtUs) ~/ 1000}',
        );
      }
      trace?.record(
        BroadcastLatencyEvent(
          kind: BroadcastLatencyEventKind.translationFrame,
          atUs: nowUs,
          sessionEpoch: frame.sessionEpoch,
          revision: frame.revision,
          candidateGeneration: frame.candidateGeneration,
          utteranceStartSample: frame.utteranceStartSample,
          audioStartSample: frame.audioStartSample,
          audioEndSample: frame.audioEndSample,
          candidateRef: frame.outcome.candidateRef,
          status: frame.outcome.status.name,
          sourceKind: frame.translationSourceKind,
        ),
      );
    }
  }

  /// 状态提示（权限、超载、错误等）。
  String? get statusMessage => _statusMessage;

  /// 创建记录时冻结的目标语言。
  TargetLanguage get targetLanguage => _targetLanguage;

  /// 历史总数。
  int get recordCount => _recordCount;

  /// 最近记录（新到旧）。
  List<UtteranceRecord> get recentRecords =>
      List<UtteranceRecord>.unmodifiable(_recent);

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
    unawaited(translations.warmLanguage(language));
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
    if (_disposed || _shutdownFuture != null) return false;
    if (isRunning) return true;
    final epoch = ++_sessionEpoch;
    _runtimeClock
      ..reset()
      ..start();
    _lastRenderedRevision = 0;
    _lastRenderedTranslationGeneration = 0;
    _status = BroadcastSessionStatus.starting;
    _statusMessage = null;
    notifyListeners();

    if (!await audio.ensurePermission()) {
      if (_disposed || _status != BroadcastSessionStatus.starting) {
        return false;
      }
      _status = BroadcastSessionStatus.idle;
      _statusMessage = '未授予麦克风权限';
      notifyListeners();
      return false;
    }
    if (_disposed ||
        _shutdownFuture != null ||
        _sessionEpoch != epoch ||
        _status != BroadcastSessionStatus.starting) {
      return false;
    }
    try {
      _segmenter = UtteranceSegmenter(
        sampleRate: transcriber.sampleRate,
        config: segmenterConfig,
      );
      _finalQueue.clear();
      _previewRequested = false;
      _queueOverflowCount = 0;
      _draftText = '';
      _lastPreviewAt = 0;
      _lastSegmentBoundaryEndSample = 0;
      _clearPreview();
      final stream = await audio.start();
      if (_disposed ||
          _shutdownFuture != null ||
          _sessionEpoch != epoch ||
          _status != BroadcastSessionStatus.starting) {
        await audio.stop();
        return false;
      }
      _status = BroadcastSessionStatus.running;
      unawaited(translations.warmLanguage(_targetLanguage));
      _sessionSaved = 0;
      debugPrint(
        '[Broadcast] 开始识别：目标语言 ${_targetLanguage.id}，'
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
      await ScreenKeepOn.setEnabled(true);
      return !_disposed &&
          _sessionEpoch == epoch &&
          _status == BroadcastSessionStatus.running;
    } catch (error) {
      await audio.stop();
      if (_disposed || _shutdownFuture != null || _sessionEpoch != epoch) {
        return false;
      }
      _status = BroadcastSessionStatus.idle;
      _statusMessage = '无法开始收音：$error';
      notifyListeners();
      return false;
    }
  }

  /// 停止识别（幂等），并保证最后一个片段被保存。
  Future<void> stop() {
    if (_stopFuture case final running?) return running;
    if (_status == BroadcastSessionStatus.idle) return Future<void>.value();
    final task = _stopInternal();
    _stopFuture = task;
    return task.whenComplete(() => _stopFuture = null);
  }

  Future<void> _stopInternal() async {
    _status = BroadcastSessionStatus.finishing;
    _statusMessage = '正在完成最后一句…';
    notifyListeners();

    await _audioSubscription?.cancel();
    _audioSubscription = null;
    try {
      await audio.stop();
    } finally {
      await ScreenKeepOn.setEnabled(false);
    }

    // 等待统一工作泵结束，避免与收尾片段抢模型。
    while (_pumping) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final segmenter = _segmenter;
    if (segmenter != null) {
      final last = segmenter.flush();
      if (last != null) _finalQueue.add(last);
    }
    await _pumpWork();

    debugPrint(
      '[Broadcast] 停止识别：本次会话保存 $_sessionSaved 条记录'
      '${_queueOverflowCount > 0 ? '，另有 $_queueOverflowCount 个片段因过载被丢弃' : ''}',
    );
    _status = BroadcastSessionStatus.idle;
    _statusMessage = _queueOverflowCount > 0
        ? '本次有 $_queueOverflowCount 个片段因过载未处理，请降低输入频率'
        : null;
    _draftText = '';
    _clearPreview();
    _previewTranslationMemo.clear();
    notifyListeners();
  }

  void _onChunk(Float32List chunk) {
    final segmenter = _segmenter;
    if (segmenter == null || _status != BroadcastSessionStatus.running) return;
    segmenter.addChunk(chunk);
    _lastAudioChunkAtUs = _runtimeClock.elapsedMicroseconds;

    final onSilence = segmenter.takeOnSilence();
    if (onSilence != null) {
      _lastSegmentBoundaryEndSample = onSilence.endSample;
      _previewRequested = false;
      _enqueueFinal(onSilence);
    }
    final forced = segmenter.takeOnMaxDuration();
    if (forced != null) {
      _lastSegmentBoundaryEndSample = forced.endSample;
      _previewRequested = false;
      _enqueueFinal(forced);
    }

    _requestPreview();
    unawaited(_pumpWork());
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

  /// 合并预览请求；每轮推理结束后取最新音频，不积压过期窗口。
  void _requestPreview() {
    final segmenter = _segmenter;
    if (segmenter == null || _status != BroadcastSessionStatus.running) return;
    final elapsed = segmenter.totalSamples / transcriber.sampleRate;
    if (elapsed - _lastPreviewAt < previewIntervalSeconds) return;
    if (segmenter.totalSamples - _lastSegmentBoundaryEndSample <
        previewIntervalSeconds * transcriber.sampleRate) {
      return;
    }
    if (segmenter.pendingSeconds < previewIntervalSeconds) return;
    _lastPreviewAt = elapsed;
    _previewRequested = true;
  }

  /// 单一串行工作泵：终稿优先，预览请求仅保留最新一次。
  Future<void> _pumpWork() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (_finalQueue.isNotEmpty || _previewRequested) {
        if (_finalQueue.isNotEmpty) {
          final segment = _finalQueue.removeAt(0);
          try {
            await _processFinal(segment);
          } catch (error) {
            _statusMessage = '保存失败：$error';
            notifyListeners();
          }
          continue;
        }
        _previewRequested = false;
        await _processPreview();
      }
    } finally {
      _pumping = false;
    }
  }

  Future<void> _processFinal(SpeechSegment segment) async {
    final watch = Stopwatch()..start();
    final fragment = await transcriber.transcribe(
      segment.samples,
      offsetSample: segment.startSample,
    );
    final seconds =
        (segment.endSample - segment.startSample) / transcriber.sampleRate;
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
      '采样 ${segment.startSample}-${segment.endSample} '
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
    trace?.record(
      BroadcastLatencyEvent(
        kind: BroadcastLatencyEventKind.finalPublished,
        atUs: _runtimeClock.elapsedMicroseconds,
        sessionEpoch: _sessionEpoch,
        revision: _previewRevision,
        candidateGeneration: _candidateGeneration,
        utteranceStartSample: segment.startSample,
        audioStartSample: segment.startSample,
        audioEndSample: segment.endSample,
        candidateRef: outcome.candidateRef,
        status: outcome.status.name,
        note: 'boundary=${segment.reason.name}',
      ),
    );
    notifyListeners();

    if (job != null) {
      // 翻译异步执行：失败不丢记录，可同记录重试。
      _backgroundTranslationTail = _backgroundTranslationTail.then(
        (_) => _runTranslations(),
      );
      unawaited(_backgroundTranslationTail);
    }
  }

  /// 实时预览：统一工作泵只在没有待处理终稿时执行。
  ///
  /// 与只更新转写草稿不同，这里同时对同一份声学证据跑一次候选匹配，
  /// 让「转写 / 匹配经文 / 译文」三栏在片段进行中就同步刷新；
  /// 预览匹配标注为候选，不落库、不产生历史记录。
  Future<void> _processPreview() async {
    final segmenter = _segmenter;
    if (segmenter == null || _status != BroadcastSessionStatus.running) return;
    final pending = segmenter.pendingSamples;
    if (pending.length < previewIntervalSeconds * transcriber.sampleRate) {
      return;
    }
    if (segmenter.totalSamples - _lastSegmentBoundaryEndSample <
        previewIntervalSeconds * transcriber.sampleRate) {
      return;
    }
    final maxSamples = (previewWindowSeconds * transcriber.sampleRate).round();
    final windowStart = pending.length > maxSamples
        ? pending.length - maxSamples
        : 0;
    final samples = Float32List.sublistView(pending, windowStart);
    final utteranceStart = segmenter.pendingStartSample;
    final audioEnd = segmenter.totalSamples;
    final audioReceivedAtUs = _lastAudioChunkAtUs;
    final audioStart = audioEnd - samples.length;
    final epoch = _sessionEpoch;
    final previewWatch = Stopwatch()..start();
    try {
      final fragment = await transcriber.transcribePreview(
        samples,
        offsetSample: audioStart,
      );
      if (fragment.words.isEmpty ||
          _status != BroadcastSessionStatus.running ||
          _sessionEpoch != epoch ||
          _segmenter != segmenter ||
          segmenter.pendingStartSample != utteranceStart) {
        return;
      }
      final matchWatch = Stopwatch()..start();
      // 与终稿使用同一个匹配器和阈值；仅限制预览音频长度与前向次数。
      final outcome = matcher.match(fragment);
      matchWatch.stop();
      final candidateKey = _candidateKey(outcome.matches);
      final previous = _preview;
      final sameCandidate =
          previous != null &&
          previous.sessionEpoch == epoch &&
          previous.utteranceStartSample == utteranceStart &&
          previous.candidateKey == candidateKey;
      // 候选被替换且旧候选还有在途或已显示的译文：记录一次丢弃。
      // 新预览是不带译文构造出来的，因此必须在这里记，不能等到事后清理——
      // 那时 this._preview 已经是新候选，看不出有过一份被顶替的译文。
      if (!sameCandidate &&
          previous != null &&
          previous.sessionEpoch == epoch &&
          (previous.translationText != null || previous.translationPending)) {
        trace?.record(
          BroadcastLatencyEvent(
            kind: BroadcastLatencyEventKind.translationDropped,
            atUs: _runtimeClock.elapsedMicroseconds,
            sessionEpoch: previous.sessionEpoch,
            revision: previous.revision,
            candidateGeneration: previous.candidateGeneration,
            utteranceStartSample: previous.utteranceStartSample,
            audioStartSample: previous.audioStartSample,
            audioEndSample: previous.audioEndSample,
            candidateRef: previous.outcome.candidateRef,
            status: previous.outcome.status.name,
            sourceKind: previous.translationSourceKind,
            note: previous.translationText == null ? 'pending' : 'shown',
          ),
        );
      }
      _draftText = fragment.text;
      _preview = BroadcastPreview(
        draftText: fragment.text,
        outcome: outcome,
        sessionEpoch: epoch,
        utteranceStartSample: utteranceStart,
        audioStartSample: audioStart,
        audioEndSample: audioEnd,
        audioReceivedAtUs: audioReceivedAtUs,
        revision: ++_previewRevision,
        candidateGeneration: sameCandidate
            ? previous.candidateGeneration
            : ++_candidateGeneration,
        candidateKey: candidateKey,
        translationText: sameCandidate ? previous.translationText : null,
        translationSource: sameCandidate ? previous.translationSource : null,
        translationSourceKind: sameCandidate
            ? previous.translationSourceKind
            : null,
        translationInputScope: sameCandidate
            ? previous.translationInputScope
            : null,
        translationPending: sameCandidate && previous.translationPending,
      );
      previewWatch.stop();
      debugPrint(
        '[Broadcast] 预览 #$_previewRevision 窗口 ${samples.length / transcriber.sampleRate}s：'
        '${outcome.status.name} 候选=${outcome.candidateRef ?? '-'} '
        '覆盖=${outcome.coverage?.toStringAsFixed(2) ?? '-'} '
        '置信=${outcome.confidence?.toStringAsFixed(2) ?? '-'} '
        '匹配 ${matchWatch.elapsedMilliseconds}ms，整轮 ${previewWatch.elapsedMilliseconds}ms'
        '${outcome.rejectionReason == null ? '' : ' 原因=${outcome.rejectionReason}'}',
      );
      trace?.record(
        BroadcastLatencyEvent(
          kind: BroadcastLatencyEventKind.previewPublished,
          atUs: _runtimeClock.elapsedMicroseconds,
          sessionEpoch: epoch,
          revision: _previewRevision,
          candidateGeneration: _candidateGeneration,
          utteranceStartSample: utteranceStart,
          audioStartSample: audioStart,
          audioEndSample: audioEnd,
          audioReceivedAtUs: audioReceivedAtUs,
          candidateRef: outcome.candidateRef,
          status: outcome.status.name,
        ),
      );
      _trackPreviewStability(outcome);
      if (!sameCandidate && _previewStableCount >= 2) {
        _candidateStableAtUs = _runtimeClock.elapsedMicroseconds;
      }
      notifyListeners();
    } catch (error) {
      // 预览失败不影响终稿链路。
      debugPrint('[Broadcast] 预览失败：$error');
    }
  }

  static String _candidateKey(List<MatchedVerse> matches) => matches
      .map(
        (match) =>
            '${match.ref}:${match.wordStart ?? '-'}-${match.wordEnd ?? '-'}',
      )
      .join(',');

  /// 候选经连续两次相同即触发一次预览翻译（与终稿共用缓存，不重复调引擎）。
  ///
  /// 预览译文**只跟随匹配经文**：未命中库内经文（章前求护词、解说、其他章节）时
  /// 不翻译转写 —— 实测诵读者先念求护词的十几秒里，转写内容频繁变化，跟着翻译
  /// 转写只会得到跳动的、与经文无关的译文。未匹配片段的正式译文仍按需求在终稿
  /// 落库时翻译实际转写，并带「机器翻译·识别转写」来源标记。
  void _trackPreviewStability(BroadcastMatchOutcome outcome) {
    if (outcome.matches.isEmpty) {
      _lastPreviewRef = null;
      _previewStableCount = 0;
      _clearPreviewTranslation();
      return;
    }
    // 候选是否稳定按经文引用判断；节内词范围仍在随朗读推进，
    // 只有译文复用与迟到结果校验才使用包含词范围的 candidateKey。
    final refs = outcome.matches.map((match) => match.ref).join(',');
    if (refs.isEmpty || refs != _lastPreviewRef) {
      _lastPreviewRef = refs;
      _previewStableCount = 1;
      _candidateStableAtUs = null;
      // 候选切换：清掉旧候选的译文，避免「新经文配旧译文」。
      _clearPreviewTranslation();
      return;
    }
    _previewStableCount++;
    if (_previewStableCount == 2) {
      _candidateStableAtUs = _runtimeClock.elapsedMicroseconds;
    }
    if (_previewStableCount >= 2 &&
        _preview?.translationText == null &&
        _preview?.translationPending == false) {
      _startPreviewTranslation(outcome);
    }
  }

  void _startPreviewTranslation(BroadcastMatchOutcome outcome) {
    // 保留真正执行中的 Future，关闭会话必须等到缓存写入也已完成。
    if (_previewTranslating) return;
    final task = _translatePreview(outcome);
    _previewTranslationFuture = task;
    unawaited(task);
  }

  void _clearPreviewTranslation() {
    if (_preview == null) return;
    final previous = _preview!;
    if (previous.translationText == null &&
        previous.translationSource == null &&
        !previous.translationPending) {
      return;
    }
    // 候选切换清掉译文：记录一次丢弃，供统计「等待或被取消」的比例。
    // 没有这次记录，端到端时延只会统计成功显示的候选，样本会被系统性偏小。
    trace?.record(
      BroadcastLatencyEvent(
        kind: BroadcastLatencyEventKind.translationDropped,
        atUs: _runtimeClock.elapsedMicroseconds,
        sessionEpoch: previous.sessionEpoch,
        revision: previous.revision,
        candidateGeneration: previous.candidateGeneration,
        utteranceStartSample: previous.utteranceStartSample,
        audioStartSample: previous.audioStartSample,
        audioEndSample: previous.audioEndSample,
        candidateRef: previous.outcome.candidateRef,
        status: previous.outcome.status.name,
        sourceKind: previous.translationSourceKind,
        note: previous.translationText == null ? 'pending' : 'shown',
      ),
    );
    _preview = previous.copyWith(
      translationText: null,
      translationSource: null,
      translationSourceKind: null,
      translationInputScope: null,
      translationPending: false,
    );
    notifyListeners();
  }

  /// 预览译文：命中内存或数据库缓存时零成本返回；未命中调一次引擎并写入缓存，
  /// 片段结束后的正式翻译通常直接命中，不会重复调用。
  Future<void> _translatePreview(BroadcastMatchOutcome outcome) async {
    final snapshot = _preview;
    if (snapshot == null ||
        snapshot.candidateKey.isEmpty ||
        _status != BroadcastSessionStatus.running) {
      return;
    }
    if (_previewTranslating) return;
    final language = _targetLanguage;
    final memoKey = '${language.id}:${snapshot.candidateKey}';
    final memo = _previewTranslationMemo[memoKey];
    if (memo != null) {
      _publishPreviewTranslation(snapshot, language, memo);
      return;
    }
    _previewTranslating = true;
    _preview = _preview?.copyWith(
      translationText: null,
      translationSource: null,
      translationPending: true,
    );
    notifyListeners();
    try {
      final result = await translations.translatePreview(
        matches: outcome.matches,
        asrText: outcome.asrText,
        language: language,
      );
      if (result != null && result.text.trim().isNotEmpty) {
        _previewTranslationMemo[memoKey] = result;
        _publishPreviewTranslation(snapshot, language, result);
      } else if (_samePreviewCandidate(snapshot, language)) {
        _preview = _preview!.copyWith(translationPending: false);
        notifyListeners();
      }
    } catch (error) {
      debugPrint('[Broadcast] 预览翻译失败：$error');
      if (_samePreviewCandidate(snapshot, language)) {
        _preview = _preview!.copyWith(translationPending: false);
        notifyListeners();
      }
    } finally {
      _previewTranslating = false;
      // A 的慢译文返回时，B 可能已稳定；立即启动最新候选，不等下一块音频。
      final current = _preview;
      if (current != null &&
          _status == BroadcastSessionStatus.running &&
          _previewStableCount >= 2 &&
          current.translationText == null &&
          !current.translationPending &&
          (current.candidateGeneration != snapshot.candidateGeneration ||
              '${_targetLanguage.id}:${current.candidateKey}' != memoKey)) {
        _startPreviewTranslation(current.outcome);
      }
    }
  }

  bool _samePreviewCandidate(
    BroadcastPreview snapshot,
    TargetLanguage language,
  ) {
    final current = _preview;
    return current != null &&
        _status == BroadcastSessionStatus.running &&
        _targetLanguage == language &&
        current.sessionEpoch == snapshot.sessionEpoch &&
        current.utteranceStartSample == snapshot.utteranceStartSample &&
        current.candidateGeneration == snapshot.candidateGeneration &&
        current.candidateKey == snapshot.candidateKey;
  }

  void _publishPreviewTranslation(
    BroadcastPreview snapshot,
    TargetLanguage language,
    PreviewTranslation result,
  ) {
    if (!_samePreviewCandidate(snapshot, language)) return;
    _preview = _preview!.copyWith(
      translationText: result.text,
      translationSource:
          '${language.displayName} · ${result.sourceKind.label}'
          '${result.editionLabel == null ? '' : ' · ${result.editionLabel}'}（预览）',
      translationSourceKind: result.sourceKind,
      translationInputScope: result.inputScope,
      translationPending: false,
    );
    trace?.record(
      BroadcastLatencyEvent(
        kind: BroadcastLatencyEventKind.translationPublished,
        atUs: _runtimeClock.elapsedMicroseconds,
        sessionEpoch: snapshot.sessionEpoch,
        revision: snapshot.revision,
        candidateGeneration: snapshot.candidateGeneration,
        utteranceStartSample: snapshot.utteranceStartSample,
        audioStartSample: snapshot.audioStartSample,
        audioEndSample: snapshot.audioEndSample,
        candidateRef: snapshot.outcome.candidateRef,
        status: snapshot.outcome.status.name,
        sourceKind: result.sourceKind,
      ),
    );
    notifyListeners();
  }

  /// 终稿确认或会话结束后清空预览（三栏切换为已确认记录）。
  void _clearPreview() {
    _preview = null;
    _lastPreviewRef = null;
    _previewStableCount = 0;
    _candidateStableAtUs = null;
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
    _sessionEpoch++;
    _sessionId = UtteranceRecord.newUuid();
    _segmenter?.reset();
    _lastSegmentBoundaryEndSample = 0;
    _finalQueue.clear();
    _previewRequested = false;
    _draftText = '';
    _clearPreview();
    _previewTranslationMemo.clear();
    notifyListeners();
  }

  /// 等待收音、推理及由终稿启动的后台翻译完成，再释放监听器。
  Future<void> shutdown() => _shutdownFuture ??= _shutdownInternal();

  Future<void> _shutdownInternal() async {
    await stop();
    await _backgroundTranslationTail;
    await _previewTranslationFuture;
    await translations.waitForIdle();
    dispose();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_audioSubscription?.cancel());
    unawaited(audio.stop());
    unawaited(ScreenKeepOn.setEnabled(false));
    super.dispose();
  }
}
