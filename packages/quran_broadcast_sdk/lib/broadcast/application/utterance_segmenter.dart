/// 断句状态机：把连续音频切成「有明确起止时间的已确认语音片段」。
///
/// 「一句」不等于「一节经文」，也不等于每次模型回调。本状态机的判据全部来自
/// 音频本身（能量与静音长度），不使用任何经文标签。
///
/// 噪声门限沿用现有实现的思路：不假设远场信号强，也不用固定绝对阈值 ——
/// 阈值取自「会话内最安静的窗口本底」与一个绝对下限的较大者，本底向下立即跟随、
/// 向上缓慢回升，因此既适应环境噪声，也不会被一段朗读立刻抬高。
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// 断句参数。
///
/// **这些是待标定起点，不是已验收常数**：真实外放场景的信噪比、停顿长度与
/// 语速都要用广播样本重新标定。
class UtteranceSegmenterConfig {
  /// 构造参数。
  ///
  /// @param silenceSeconds 判定一句结束所需的静音时长
  /// @param minSpeechSeconds 有效片段最短时长（更短的直接丢弃）
  /// @param maxSeconds 片段最长时长，超过则强制切分
  /// @param overlapSeconds 强制切分时保留的重叠时长
  /// @param silenceRmsFactor 静音判据相对本底的倍数
  /// @param minRms 静音判据的绝对下限
  /// @param speechRmsFactor 判定「片段内有语音」相对本底的倍数
  const UtteranceSegmenterConfig({
    this.silenceSeconds = 1.2,
    this.minSpeechSeconds = 0.8,
    this.maxSeconds = 30,
    this.overlapSeconds = 1,
    this.silenceRmsFactor = 2,
    this.minRms = 0.008,
    this.speechRmsFactor = 3,
  });

  /// 结束静音时长。
  final double silenceSeconds;

  /// 最短有效片段。
  final double minSpeechSeconds;

  /// 最长片段。
  final double maxSeconds;

  /// 强制切分时的重叠。
  final double overlapSeconds;

  /// 静音判据倍数。
  final double silenceRmsFactor;

  /// 静音判据绝对下限。
  final double minRms;

  /// 语音判据倍数。
  final double speechRmsFactor;
}

/// 片段结束原因。
enum SegmentBoundary {
  /// 停在自然停顿处。
  silence,

  /// 达到最长时长被强制切分。
  maxDuration,

  /// 用户停止或会话收尾。
  stopped,
}

/// 一个已确认的语音片段。
class SpeechSegment {
  /// 构造片段。
  ///
  /// @param samples 片段音频
  /// @param startSample 会话内绝对起始采样
  /// @param endSample 会话内绝对结束采样
  /// @param reason 结束原因
  /// @param hasSpeech 是否检测到语音（否则不应产生记录）
  const SpeechSegment({
    required this.samples,
    required this.startSample,
    required this.endSample,
    required this.reason,
    required this.hasSpeech,
  });

  /// 片段音频。
  final Float32List samples;

  /// 绝对起始采样。
  final int startSample;

  /// 绝对结束采样。
  final int endSample;

  /// 结束原因。
  final SegmentBoundary reason;

  /// 是否检测到语音。
  final bool hasSpeech;

  /// 时长（秒）。
  double seconds(int sampleRate) => (endSample - startSample) / sampleRate;
}

/// 断句状态机。
class UtteranceSegmenter {
  /// 构造状态机。
  ///
  /// @param sampleRate 采样率
  /// @param config 断句参数
  UtteranceSegmenter({
    required this.sampleRate,
    this.config = const UtteranceSegmenterConfig(),
  });

  /// 采样率。
  final int sampleRate;

  /// 断句参数。
  final UtteranceSegmenterConfig config;

  Float32List _pending = Float32List(0);
  int _pendingStartSample = 0;
  int _totalSamples = 0;
  double _silenceSeconds = 0;
  double _baseline = 0;
  bool _baselineReady = false;
  double _pendingPeak = 0;

  /// 会话内累计采样（单调时间源）。
  int get totalSamples => _totalSamples;

  /// 当前待确认片段的采样。
  Float32List get pendingSamples => _pending;

  /// 当前待确认片段在本次收音中的绝对起点。
  int get pendingStartSample => _pendingStartSample;

  /// 当前待确认片段时长（秒）。
  double get pendingSeconds => _pending.length / sampleRate;

  /// 会话内估计的安静本底（RMS），可用于界面提示收音强度。
  double get quietBaseline => _baseline;

  /// 喂入一块音频。
  ///
  /// @param chunk 16 kHz 单声道 PCM
  void addChunk(Float32List chunk) {
    if (chunk.isEmpty) return;
    _totalSamples += chunk.length;
    if (_pending.isEmpty) _pendingStartSample = _totalSamples - chunk.length;
    final merged = Float32List(_pending.length + chunk.length)
      ..setAll(0, _pending)
      ..setAll(_pending.length, chunk);
    _pending = merged;

    final rms = _rms(chunk);
    final peak = _peak(chunk);
    _pendingPeak = math.max(_pendingPeak, peak);
    if (!_baselineReady) {
      // 起步不得高于绝对下限：否则「一开始就在朗读」会把本底抬到语音量级，
      // 之后所有语音都会被判成静音（实测会让整场录音 0 片段）。
      _baseline = math.min(rms, config.minRms);
      _baselineReady = true;
    } else if (rms < _baseline) {
      _baseline = rms;
    } else {
      _baseline = math.min(rms, _baseline * 1.02);
    }
    _silenceSeconds = _isQuiet(rms)
        ? _silenceSeconds + chunk.length / sampleRate
        : 0;
  }

  /// 片段是否已到达自然停顿终点。
  bool get shouldCloseOnSilence =>
      _silenceSeconds >= config.silenceSeconds &&
      _pending.length / sampleRate >= config.minSpeechSeconds;

  /// 片段是否已超过最长时长。
  bool get shouldForceSplit =>
      _pending.length / sampleRate >= config.maxSeconds;

  /// 取走自然停顿处的完整片段。
  ///
  /// @return 片段；不满足条件时返回 null
  SpeechSegment? takeOnSilence() {
    if (!shouldCloseOnSilence) return null;
    return _take(SegmentBoundary.silence, keepOverlap: false);
  }

  /// 强制切分超长片段（保留重叠，避免把词切断）。
  ///
  /// @return 片段；不满足条件时返回 null
  SpeechSegment? takeOnMaxDuration() {
    if (!shouldForceSplit) return null;
    return _take(SegmentBoundary.maxDuration, keepOverlap: true);
  }

  /// 停止时收尾：交出剩余音频（不做最短时长过滤，避免丢掉最后一个字）。
  ///
  /// @return 片段；无剩余内容时返回 null
  SpeechSegment? flush() {
    if (_pending.isEmpty) return null;
    if (_pending.length / sampleRate < config.minSpeechSeconds * 0.5) {
      _reset();
      return null;
    }
    return _take(SegmentBoundary.stopped, keepOverlap: false);
  }

  /// 丢弃当前待确认片段（取消或重置）。
  void reset() => _reset();

  SpeechSegment _take(SegmentBoundary reason, {required bool keepOverlap}) {
    final segment = SpeechSegment(
      samples: _pending,
      startSample: _pendingStartSample,
      endSample: _pendingStartSample + _pending.length,
      reason: reason,
      hasSpeech: _hasSpeech(),
    );
    if (keepOverlap) {
      final overlapSamples = math.min(
        _pending.length,
        (config.overlapSeconds * sampleRate).round(),
      );
      final keep = Float32List.sublistView(
        _pending,
        _pending.length - overlapSamples,
      );
      _pending = Float32List.fromList(keep);
      _pendingStartSample = segment.endSample - overlapSamples;
    } else {
      _reset();
    }
    _silenceSeconds = 0;
    _pendingPeak = 0;
    return segment;
  }

  bool _hasSpeech() =>
      _pendingPeak >=
      math.max(
        config.minRms * config.speechRmsFactor,
        _baseline * config.speechRmsFactor,
      );

  bool _isQuiet(double rms) =>
      rms < math.max(config.minRms, _baseline * config.silenceRmsFactor);

  void _reset() {
    _pending = Float32List(0);
    _pendingStartSample = _totalSamples;
    _silenceSeconds = 0;
    _pendingPeak = 0;
  }

  static double _rms(Float32List samples) {
    if (samples.isEmpty) return 0;
    var sum = 0.0;
    for (final sample in samples) {
      sum += sample * sample;
    }
    return math.sqrt(sum / samples.length);
  }

  static double _peak(Float32List samples) {
    var peak = 0.0;
    for (final sample in samples) {
      final value = sample.abs();
      if (value > peak) peak = value;
    }
    return peak;
  }
}
