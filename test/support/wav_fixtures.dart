/// 测试用的 WAV 构造工具。
///
/// 语料验证会校验音频格式，测试里需要一个「合法 / 故意不合法」的 WAV 生成器，
/// 避免依赖真实语料文件（`sample_*.wav` 与模型一样不入版本库）。
library;

import 'dart:typed_data';

/// 构造测试用 WAV。
///
/// @param samples 采样
/// @param sampleRate 采样率
/// @param channels 声道数
/// @param bits 位深
/// @param withExtraChunk 是否在 fmt 与 data 之间插入一个 LIST 块
///   （用于验证解析不依赖固定 44 字节头）
/// @return WAV 字节
Uint8List buildTestWav(
  Float32List samples, {
  int sampleRate = 16000,
  int channels = 1,
  int bits = 16,
  bool withExtraChunk = false,
}) {
  final pcm = Uint8List(samples.length * 2);
  final pcmView = ByteData.sublistView(pcm);
  for (var i = 0; i < samples.length; i++) {
    pcmView.setInt16(i * 2, (samples[i] * 32767).round(), Endian.little);
  }
  final extra = withExtraChunk ? 12 : 0;
  final total = 12 + 24 + extra + 8 + pcm.length;
  final bytes = Uint8List(total);
  final view = ByteData.sublistView(bytes);
  void ascii(int offset, String text) {
    for (var i = 0; i < text.length; i++) {
      bytes[offset + i] = text.codeUnitAt(i);
    }
  }

  ascii(0, 'RIFF');
  view.setUint32(4, total - 8, Endian.little);
  ascii(8, 'WAVE');

  var offset = 12;
  ascii(offset, 'fmt ');
  view.setUint32(offset + 4, 16, Endian.little);
  view.setUint16(offset + 8, 1, Endian.little);
  view.setUint16(offset + 10, channels, Endian.little);
  view.setUint32(offset + 12, sampleRate, Endian.little);
  view.setUint32(offset + 16, sampleRate * channels * bits ~/ 8, Endian.little);
  view.setUint16(offset + 20, channels * bits ~/ 8, Endian.little);
  view.setUint16(offset + 22, bits, Endian.little);
  offset += 24;

  if (withExtraChunk) {
    ascii(offset, 'LIST');
    view.setUint32(offset + 4, 4, Endian.little);
    offset += 12;
  }

  ascii(offset, 'data');
  view.setUint32(offset + 4, pcm.length, Endian.little);
  offset += 8;
  bytes.setRange(offset, offset + pcm.length, pcm);
  return bytes;
}
