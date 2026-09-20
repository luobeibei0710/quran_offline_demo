/// 语料音频的解码与校验。
///
/// 语料验证绕开麦克风，直接把音频喂进引擎，因此音频格式必须与模型输入一致：
/// **16 kHz / 单声道 / 16-bit PCM 的 WAV**。这里按 RIFF 分块扫描（不假定 44 字节
/// 固定头），并把格式不符的情况报成可读的错误 —— 最常见的是把 mp3 直接改名成
/// `.wav`，那样只有明确的报错才能让人知道该转码。
library;

import 'dart:typed_data';

/// 语料音频不符合要求时抛出。
class CorpusAudioException implements Exception {
  /// 构造异常。
  ///
  /// @param message 面向用户的说明（含实际格式与转码提示）
  const CorpusAudioException(this.message);

  /// 说明文本。
  final String message;

  @override
  String toString() => message;
}

/// 语料音频工具。
class CorpusAudio {
  /// 引擎要求的采样率。
  static const int sampleRate = 16000;

  /// 解码 WAV 为 float32 单声道采样（-1..1）。
  ///
  /// @param bytes WAV 文件字节
  /// @return 采样序列
  /// @throws CorpusAudioException 格式不是 16 kHz / 单声道 / 16-bit PCM 时抛出
  static Float32List decodeWav(Uint8List bytes) {
    if (bytes.length < 44) {
      throw const CorpusAudioException('音频过短，不是有效的 WAV 文件');
    }
    final data = ByteData.sublistView(bytes);
    String tag(int offset) => String.fromCharCodes(bytes.sublist(offset, offset + 4));
    if (tag(0) != 'RIFF' || tag(8) != 'WAVE') {
      throw const CorpusAudioException(
        '不是 WAV 文件（缺少 RIFF/WAVE 标记）。若源文件是 mp3，请先转码：\n'
        'afconvert -f WAVE -d LEI16@16000 -c 1 输入.mp3 corpus_audio.wav',
      );
    }

    int? audioFormat;
    int? channels;
    int? rate;
    int? bits;
    Uint8List? pcm;

    var offset = 12;
    while (offset + 8 <= bytes.length) {
      final id = tag(offset);
      final size = data.getUint32(offset + 4, Endian.little);
      final body = offset + 8;
      if (id == 'fmt ' && size >= 16 && body + 16 <= bytes.length) {
        audioFormat = data.getUint16(body, Endian.little);
        channels = data.getUint16(body + 2, Endian.little);
        rate = data.getUint32(body + 4, Endian.little);
        bits = data.getUint16(body + 14, Endian.little);
      } else if (id == 'data') {
        final end = (body + size).clamp(body, bytes.length);
        pcm = Uint8List.sublistView(bytes, body, end);
      }
      // 块按偶数字节对齐
      offset = body + size + (size.isOdd ? 1 : 0);
    }

    if (audioFormat == null || pcm == null) {
      throw const CorpusAudioException('WAV 缺少 fmt 或 data 块');
    }
    if (audioFormat != 1 || bits != 16 || channels != 1 || rate != sampleRate) {
      throw CorpusAudioException(
        '音频格式不支持：格式=$audioFormat 声道=$channels 采样率=$rate 位深=$bits；'
        '要求 16 kHz / 单声道 / 16-bit PCM。\n'
        '转码：afconvert -f WAVE -d LEI16@16000 -c 1 输入.mp3 corpus_audio.wav',
      );
    }

    final count = pcm.length ~/ 2;
    final pcmData = ByteData.sublistView(pcm);
    final samples = Float32List(count);
    for (var i = 0; i < count; i++) {
      samples[i] = pcmData.getInt16(i * 2, Endian.little) / 32768.0;
    }
    return samples;
  }

  /// 采样时长（秒）。
  ///
  /// @param samples 采样序列
  /// @return 时长
  static double durationSeconds(Float32List samples) => samples.length / sampleRate;
}
