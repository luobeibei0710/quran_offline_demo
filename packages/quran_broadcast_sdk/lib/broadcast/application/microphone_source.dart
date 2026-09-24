/// 麦克风音源：把 `record` 的 PCM16 字节流转换为 16 kHz 单声道 float32。
///
/// 收音生命周期由会话控制器持有，页面只订阅状态；同时提供接口以便测试注入
/// 脚本化音频，不为测试改动生产路径。
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';

import 'audio_pcm_dump.dart';

/// 音源契约。
abstract interface class AudioCaptureSource {
  /// 是否已获得麦克风权限。
  ///
  /// @param request 未授权时是否发起申请
  /// @return 是否可用
  Future<bool> ensurePermission({bool request = true});

  /// 开始采集，返回 16 kHz 单声道 float32 分块流。
  ///
  /// @return 音频分块流
  Future<Stream<Float32List>> start();

  /// 停止采集并释放底层资源（幂等）。
  Future<void> stop();
}

/// 基于 `record` 插件的真实麦克风音源。
class MicrophoneCaptureSource implements AudioCaptureSource {
  /// 构造音源。
  ///
  /// @param sampleRate 目标采样率，必须与 ASR 模型一致
  /// @param pcmDump 诊断用 PCM 转储；为 null（默认）时不写任何文件
  MicrophoneCaptureSource({this.sampleRate = 16000, this.pcmDump});

  /// 目标采样率。
  final int sampleRate;

  /// 诊断用 PCM 转储；默认不启用。
  final AudioPcmDump? pcmDump;

  final AudioRecorder _recorder = AudioRecorder();
  bool _streaming = false;

  @override
  Future<bool> ensurePermission({bool request = true}) =>
      _recorder.hasPermission(request: request);

  @override
  Future<Stream<Float32List>> start() async {
    if (_streaming) await stop();
    final dump = pcmDump;
    if (dump != null && !dump.isActive) await dump.open();
    final stream = await _recorder.startStream(
      RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRate,
        numChannels: 1,
      ),
    );
    _streaming = true;
    return stream.map((bytes) {
      // 转储发生在归一化之前：写的是插件交付的原始 PCM16，不改变推理输入。
      dump?.write(bytes);
      return pcm16ToFloat32(bytes);
    });
  }

  @override
  Future<void> stop() async {
    if (!_streaming) return;
    _streaming = false;
    await _recorder.stop();
    await pcmDump?.close();
  }

  /// 把 PCM16 小端字节转成归一化 float32。
  ///
  /// 只改变量名而不重采样会被视为「假重采样」，因此采样率在 [start] 中显式
  /// 交给采集层，采集层直接产出目标采样率。
  ///
  /// @param bytes PCM16 小端字节
  /// @return 归一化到 [-1, 1] 的采样
  static Float32List pcm16ToFloat32(Uint8List bytes) {
    final usable = bytes.length - (bytes.length % 2);
    final data = ByteData.sublistView(bytes, 0, usable);
    final samples = Float32List(usable ~/ 2);
    for (var index = 0; index < samples.length; index++) {
      samples[index] = data.getInt16(index * 2, Endian.little) / 32768.0;
    }
    return samples;
  }
}
