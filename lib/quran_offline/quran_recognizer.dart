/// 古兰经离线识别器：封装「音频 → 经文章节」的完整流程，并提供流式识别会话。
///
/// 流程：16 kHz float32 音频 → ONNX 推理（原生）→ 贪心 CTC 解码 →
/// 文本召回 → CTC 约束精排 → 章节结果。
///
/// 流式策略（工程化简版，便于在移动端稳定运行）：
/// - 累积音频缓冲，按触发间隔对「最近窗口」重复识别；
/// - 连续若干轮识别到同一节才提交稳定结果，避免逐帧抖动；
/// - 同时输出候选列表、词进度与原始文本，供 UI 展示。
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'ctc_decoder.dart';
import 'ort_runner.dart';
import 'quran_assets.dart';
import 'quran_matcher.dart';

/// 一次识别的输出事件。
class QuranRecognitionEvent {
  /// 构造事件。
  const QuranRecognitionEvent({
    required this.match,
    required this.decodedText,
    required this.stable,
    required this.isFinal,
    required this.audioSeconds,
  });

  /// 匹配结果（含冠军与候选）。
  final VerseMatchResult match;

  /// 本轮识别文本。
  final String decodedText;

  /// 是否已连续多轮稳定命中同一节。
  final bool stable;

  /// 是否为收尾（静音超时或手动结束）时的事件。
  final bool isFinal;

  /// 本轮参与识别的音频时长（秒）。
  final double audioSeconds;

  /// 当前冠军（可能为 null）。
  VerseMatchCandidate? get champion => match.champion;
}

/// 流式识别配置。
class QuranStreamingConfig {
  /// 构造配置。
  const QuranStreamingConfig({
    this.triggerSeconds = 0.75,
    this.maxWindowSeconds = 15.0,
    this.minWindowSeconds = 1.2,
    this.stableRounds = 2,
    this.silenceRmsThreshold = 0.005,
    this.finalSilenceSeconds = 1.2,
    this.topK = QuranMatcher.defaultTopK,
    this.maxSpan = QuranMatcher.defaultMaxSpan,
  });

  /// 每累积多少秒音频触发一次识别。
  final double triggerSeconds;

  /// 单次识别窗口上限（秒），避免窗外内容干扰。
  final double maxWindowSeconds;

  /// 触发识别所需的最短音频长度（秒）。
  final double minWindowSeconds;

  /// 连续多少轮命中同一节才标记为稳定。
  final int stableRounds;

  /// 静音判定阈值（RMS）。
  final double silenceRmsThreshold;

  /// 静音多久后判定一次诵读结束。
  final double finalSilenceSeconds;

  /// 参与 CTC 精排的候选数。
  final int topK;

  /// 最大连读跨度（节）。
  final int maxSpan;
}

/// 一次性识别 + 流式识别的统一入口。
class QuranRecognizer {
  /// 构造识别器。
  ///
  /// @param assets 已加载的数据资产
  /// @param runner 推理桥实现
  /// @param config 流式配置
  QuranRecognizer({
    required this.assets,
    required this.runner,
    this.config = const QuranStreamingConfig(),
  })  : decoder = TextCtcDecoder(assets.vocab, blankId: assets.blankId),
        matcher = QuranMatcher(assets);

  /// 数据资产。
  final QuranAssets assets;

  /// 推理桥。
  final OrtRunner runner;

  /// 流式配置。
  final QuranStreamingConfig config;

  /// CTC 解码器。
  final TextCtcDecoder decoder;

  /// 经文匹配器。
  final QuranMatcher matcher;

  /// 采样率。
  static const int sampleRate = 16000;

  /// 对一段完整音频做一次性识别。
  ///
  /// @param samples 16 kHz 单声道 float32 音频
  /// @return 匹配结果
  Future<VerseMatchResult> recognizeOnce(Float32List samples) async {
    final evidence = await runner.run(samples);
    final decoded = decoder.decode(evidence.logprobs, evidence.timeSteps, evidence.vocabSize);
    return matcher.match(
      evidence,
      decoded.text,
      topK: config.topK,
      maxSpan: config.maxSpan,
    );
  }

  /// 创建一个流式识别会话。
  QuranStreamingSession createSession() => QuranStreamingSession(this);
}

/// 流式识别会话：持续喂入音频分块，异步产出识别事件。
class QuranStreamingSession {
  QuranStreamingSession(this._recognizer);

  final QuranRecognizer _recognizer;

  final StreamController<QuranRecognitionEvent> _controller =
      StreamController<QuranRecognitionEvent>.broadcast();

  Float32List _accumulated = Float32List(0);
  double _secondsSinceTrigger = 0;
  double _silenceSeconds = 0;
  bool _running = true;
  bool _busy = false;
  String? _lastStableRef;
  int _stableCount = 0;

  /// 识别事件流。
  Stream<QuranRecognitionEvent> get events => _controller.stream;

  /// 已累积的音频时长（秒）。
  double get accumulatedSeconds => _accumulated.length / QuranRecognizer.sampleRate;

  /// 最近一次稳定命中的引用（`surah:ayah`）。
  String? get lastStableRef => _lastStableRef;

  /// 喂入一段音频（16 kHz 单声道 float32）。
  ///
  /// @param chunk 音频分块
  Future<void> feed(Float32List chunk) async {
    if (!_running || chunk.isEmpty) return;

    final merged = Float32List(_accumulated.length + chunk.length)
      ..setAll(0, _accumulated)
      ..setAll(_accumulated.length, chunk);
    _accumulated = merged;

    final chunkSeconds = chunk.length / QuranRecognizer.sampleRate;
    _secondsSinceTrigger += chunkSeconds;
    _silenceSeconds = _rms(chunk) < _recognizer.config.silenceRmsThreshold ? _silenceSeconds + chunkSeconds : 0;

    if (_silenceSeconds >= _recognizer.config.finalSilenceSeconds) {
      await _flush(finalEvent: true);
      return;
    }
    if (_secondsSinceTrigger >= _recognizer.config.triggerSeconds) {
      await _flush(finalEvent: false);
    }
  }

  /// 结束会话并发起一次收尾识别。
  Future<void> finish() async {
    if (!_running) return;
    await _flush(finalEvent: true);
    _running = false;
    await _controller.close();
  }

  /// 重置会话状态（开始新一次诵读）。
  void reset() {
    _accumulated = Float32List(0);
    _secondsSinceTrigger = 0;
    _silenceSeconds = 0;
    _lastStableRef = null;
    _stableCount = 0;
  }

  Future<void> _flush({required bool finalEvent}) async {
    if (_busy) return;
    final config = _recognizer.config;
    if (_accumulated.length / QuranRecognizer.sampleRate < config.minWindowSeconds) {
      if (!finalEvent) return;
      if (_accumulated.isEmpty) return;
    }
    _busy = true;
    _secondsSinceTrigger = 0;
    try {
      final windowSamples = (config.maxWindowSeconds * QuranRecognizer.sampleRate).round();
      final audio = _accumulated.length > windowSamples
          ? Float32List.sublistView(_accumulated, _accumulated.length - windowSamples)
          : _accumulated;

      final evidence = await _recognizer.runner.run(audio);
      final decoded = _recognizer.decoder.decode(evidence.logprobs, evidence.timeSteps, evidence.vocabSize);
      final match = _recognizer.matcher.match(
        evidence,
        decoded.text,
        topK: config.topK,
        maxSpan: config.maxSpan,
      );

      final champion = match.champion;
      var stable = false;
      if (champion != null) {
        if (_lastStableRef == champion.ref) {
          _stableCount++;
        } else {
          _lastStableRef = champion.ref;
          _stableCount = 1;
        }
        stable = _stableCount >= config.stableRounds;
      }

      _controller.add(
        QuranRecognitionEvent(
          match: match,
          decodedText: decoded.text,
          stable: stable,
          isFinal: finalEvent,
          audioSeconds: audio.length / QuranRecognizer.sampleRate,
        ),
      );
    } catch (error, stackTrace) {
      _controller.addError(error, stackTrace);
    } finally {
      _busy = false;
      if (finalEvent) {
        reset();
      }
    }
  }

  /// 计算分块 RMS，用于静音检测。
  double _rms(Float32List samples) {
    if (samples.isEmpty) return 0.0;
    var sum = 0.0;
    final step = math.max(1, samples.length ~/ 512);
    var count = 0;
    for (var i = 0; i < samples.length; i += step) {
      sum += samples[i] * samples[i];
      count++;
    }
    return count == 0 ? 0.0 : math.sqrt(sum / count);
  }

  /// 释放会话资源。
  Future<void> dispose() async {
    _running = false;
    if (!_controller.isClosed) {
      await _controller.close();
    }
  }
}
