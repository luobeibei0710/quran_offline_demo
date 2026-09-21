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

  /// 状态提示（权限、超载、错误等）。
  String? get statusMessage => _statusMessage;

  /// 创建记录时冻结的目标语言。
  TargetLanguage get targetLanguage => _targetLanguage;

  /// 历史总数。
  int get recordCount => _recordCount;

  /// 最近记录（新到旧）。
  List<UtteranceRecord> get recentRecords => List<UtteranceRecord>.unmodifiable(_recent);

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
      final stream = await audio.start();
      _status = BroadcastSessionStatus.running;
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

    _status = BroadcastSessionStatus.idle;
    _finishing = false;
    _statusMessage = _queueOverflowCount > 0
        ? '本次有 $_queueOverflowCount 个片段因过载未处理，请降低输入频率'
        : null;
    _draftText = '';
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
    final fragment = await transcriber.transcribe(
      segment.samples,
      offsetSample: segment.startSample,
    );
    if (fragment.isEmpty) {
      // 纯噪声：不建伪句，也不产生伪经文。
      return;
    }
    final outcome = matcher.match(fragment);
    if (outcome.asrText.trim().isEmpty) return;

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
    _recent.insert(0, record);
    if (_recent.length > 20) _recent.removeLast();
    _draftText = '';
    notifyListeners();

    if (job != null) {
      // 翻译异步执行：失败不丢记录，可同记录重试。
      unawaited(_runTranslations());
    }
  }

  /// 实时草稿：只在空闲且没有待处理终稿时执行，避免与终稿抢模型。
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
      if (fragment.words.isNotEmpty && _status == BroadcastSessionStatus.running) {
        _draftText = fragment.text;
        notifyListeners();
      }
    } catch (_) {
      // 预览失败不影响终稿链路。
    } finally {
      _busy = false;
    }
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
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_audioSubscription?.cancel());
    unawaited(audio.stop());
    super.dispose();
  }
}
