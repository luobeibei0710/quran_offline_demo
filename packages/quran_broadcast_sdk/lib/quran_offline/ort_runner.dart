/// ONNX Runtime 推理桥（Dart 侧）。
///
/// 路线 B：模型推理由原生侧执行（Android 使用 `onnxruntime-android` AAR，
/// iOS 使用 CocoaPods `onnxruntime-objc`），Dart 仅通过平台通道提交 16 kHz
/// 单声道 float32 音频并接收展开的 log 概率。
///
/// 桥接协议（MethodChannel `quran_offline/ort`）：
///
/// | 方法 | 参数 | 返回 |
/// |------|------|------|
/// | `loadModel` | `{path}` | `true` |
/// | `run` | `{samples: Float32List}` | `{logprobs, timeSteps, vocabSize}` |
/// | `dispose` | — | `null` |
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'ctc_scorer.dart';

/// 推理桥抽象，便于在测试中替换为假实现。
abstract class OrtRunner {
  /// 加载 ONNX 模型。
  ///
  /// @param modelPath 模型文件路径（Android 为解压后的私有目录路径）
  Future<void> loadModel(String modelPath);

  /// 执行一次前向推理。
  ///
  /// @param samples 16 kHz 单声道 float32 PCM
  /// @return 声学证据（含 blankId）
  Future<AcousticEvidence> run(Float32List samples);

  /// 释放原生资源。
  Future<void> dispose();
}

/// 基于平台通道的推理实现。
class PlatformOrtRunner implements OrtRunner {
  /// 构造实例。
  ///
  /// @param blankId blank token id（由词表最大 id 决定）
  PlatformOrtRunner({required this.blankId});

  /// 与原生约定的通道名。
  static const String channelName = 'quran_offline/ort';

  /// blank token id。
  final int blankId;

  static const MethodChannel _channel = MethodChannel(channelName);

  bool _loaded = false;
  bool _loadAttempted = false;

  /// 是否已成功加载模型。
  bool get isLoaded => _loaded;

  @override
  Future<void> loadModel(String modelPath) async {
    _loadAttempted = true;
    final ok = await _channel.invokeMethod<bool>('loadModel', {
      'path': modelPath,
    });
    _loaded = ok ?? false;
    if (!_loaded) {
      throw StateError('ONNX 模型加载失败: $modelPath');
    }
  }

  @override
  Future<AcousticEvidence> run(Float32List samples) async {
    final result = await _channel.invokeMethod<Map<dynamic, dynamic>>('run', {
      'samples': samples,
    });
    if (result == null) {
      throw StateError('推理返回为空');
    }
    final logprobs = result['logprobs'];
    final timeSteps = result['timeSteps'] as int? ?? 0;
    final vocabSize = result['vocabSize'] as int? ?? 0;
    if (logprobs is! Float32List) {
      throw StateError('推理返回的 logprobs 类型异常: ${logprobs.runtimeType}');
    }
    return AcousticEvidence(
      logprobs: logprobs,
      timeSteps: timeSteps,
      vocabSize: vocabSize,
      blankId: blankId,
    );
  }

  @override
  Future<void> dispose() async {
    // A failed native load can still have allocated an ORT environment.
    if (!_loadAttempted) return;
    await _channel.invokeMethod<void>('dispose');
    _loaded = false;
    _loadAttempted = false;
  }
}
