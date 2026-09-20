/// 语料音频解码与格式校验的单元测试。
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:quran_offline_demo/quran_offline/corpus_audio.dart';

import 'support/wav_fixtures.dart';

void main() {
  group('CorpusAudio.decodeWav', () {
    test('解码后与原始采样一致（16 kHz / 单声道 / 16bit）', () {
      final samples = Float32List.fromList(<double>[0, 0.5, -0.5, 1.0, -1.0, 0.25]);

      final decoded = CorpusAudio.decodeWav(buildTestWav(samples));

      expect(decoded.length, samples.length);
      for (var i = 0; i < samples.length; i++) {
        expect(decoded[i], closeTo(samples[i], 1 / 32767));
      }
    });

    test('fmt 与 data 之间夹了其它块也能解码（不依赖固定 44 字节头）', () {
      final samples = Float32List.fromList(<double>[0.1, -0.2, 0.3]);

      final decoded = CorpusAudio.decodeWav(buildTestWav(samples, withExtraChunk: true));

      expect(decoded.length, samples.length);
      expect(decoded[0], closeTo(0.1, 1 / 32767));
    });

    test('非 WAV 内容报出可读错误（含 mp3 转码提示）', () {
      expect(
        () => CorpusAudio.decodeWav(Uint8List(128)),
        throwsA(
          isA<CorpusAudioException>().having(
            (error) => error.message,
            'message',
            allOf(contains('WAV'), contains('afconvert')),
          ),
        ),
      );
    });

    test('采样率不符时报错并给出实际格式', () {
      expect(
        () => CorpusAudio.decodeWav(buildTestWav(Float32List(16), sampleRate: 44100)),
        throwsA(
          isA<CorpusAudioException>().having(
            (error) => error.message,
            'message',
            allOf(contains('44100'), contains('16000')),
          ),
        ),
      );
    });

    test('声道数不符时报错', () {
      expect(
        () => CorpusAudio.decodeWav(buildTestWav(Float32List(16), channels: 2)),
        throwsA(isA<CorpusAudioException>().having(
          (error) => error.message,
          'message',
          contains('单声道'),
        )),
      );
    });

    test('时长换算按 16 kHz 计算', () {
      expect(CorpusAudio.durationSeconds(Float32List(32000)), 2.0);
    });
  });
}
