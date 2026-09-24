/// [TextCtcDecoder] 的贪心 CTC 解码测试。
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:quran_broadcast_sdk/quran_offline/ctc_decoder.dart';

/// 构造「逐帧 argmax 命中指定 token」的 log 概率矩阵。
///
/// @param frames 每帧的 argmax token id
/// @param vocabSize 词表大小
/// @param peak 命中位置的 log 概率
/// @param floor 其余位置的 log 概率
/// @return 行主序展开的 `[frames.length, vocabSize]` log 概率
Float32List buildFrameWiseLogprobs(
  List<int> frames,
  int vocabSize, {
  double peak = 0.0,
  double floor = -10.0,
}) {
  final logprobs = Float32List(frames.length * vocabSize)..fillRange(0, frames.length * vocabSize, floor);
  for (var t = 0; t < frames.length; t++) {
    logprobs[t * vocabSize + frames[t]] = peak;
  }
  return logprobs;
}

void main() {
  const Map<int, String> vocab = <int, String>{
    1: '\u2581بسم',
    2: 'الله',
    3: '\u2581الحمد',
  };
  const int blankId = 99;
  const int vocabSize = 100;

  group('TextCtcDecoder.blankId', () {
    test('未显式指定时取词表最大 id', () {
      expect(TextCtcDecoder(vocab).blankId, 3);
    });

    test('显式指定时以参数为准', () {
      expect(TextCtcDecoder(vocab, blankId: blankId).blankId, blankId);
    });
  });

  group('TextCtcDecoder.decode', () {
    test('合并相邻重复 token 并丢弃 blank', () {
      final decoder = TextCtcDecoder(vocab, blankId: blankId);
      // 帧序列：blank,1,1,blank,2,2,blank,3
      final frames = <int>[blankId, 1, 1, blankId, 2, 2, blankId, 3];
      final result = decoder.decode(buildFrameWiseLogprobs(frames, vocabSize), frames.length, vocabSize);

      expect(result.tokenIds, <int>[1, 2, 3]);
      expect(result.text, 'بسمالله الحمد');
    });

    test('相同 token 被 blank 分隔时视为两次出现', () {
      final decoder = TextCtcDecoder(vocab, blankId: blankId);
      final frames = <int>[1, blankId, 1];
      final result = decoder.decode(buildFrameWiseLogprobs(frames, vocabSize), frames.length, vocabSize);

      expect(result.tokenIds, <int>[1, 1]);
    });

    test('全 blank 帧产出空结果', () {
      final decoder = TextCtcDecoder(vocab, blankId: blankId);
      final frames = <int>[blankId, blankId, blankId];
      final result = decoder.decode(buildFrameWiseLogprobs(frames, vocabSize), frames.length, vocabSize);

      expect(result.tokenIds, isEmpty);
      expect(result.text, '');
      expect(result.wordEnds, isEmpty);
    });

    test('零帧输入不抛异常', () {
      final decoder = TextCtcDecoder(vocab, blankId: blankId);
      final result = decoder.decode(Float32List(0), 0, vocabSize);

      expect(result.tokenIds, isEmpty);
      expect(result.text, '');
    });
  });

  group('TextCtcDecoder.tokenIdsToWordEnds', () {
    final decoder = TextCtcDecoder(vocab, blankId: blankId);

    test('词边界前缀标记新词开始', () {
      // tokens: ▁بسم | الله | ▁الحمد → 两个词，结束下标分别为 2 与 3
      expect(decoder.tokenIdsToWordEnds(<int>[1, 2, 3]), <int>[2, 3]);
    });

    test('单个词在序列末尾收尾', () {
      expect(decoder.tokenIdsToWordEnds(<int>[1, 2]), <int>[2]);
    });

    test('忽略 blank 与未知 token 后按剩余 token 计数', () {
      // 过滤掉 blank 与 id 0（<unk>）后仅剩 2 个 token，故末尾词结束下标为 2
      expect(decoder.tokenIdsToWordEnds(<int>[blankId, 1, blankId, 2, 0]), <int>[2]);
    });
  });

  group('TextCtcDecoder.tokenIdsToText', () {
    test('词边界前缀转为空格并归一化', () {
      final decoder = TextCtcDecoder(vocab, blankId: blankId);
      expect(decoder.tokenIdsToText(<int>[1, 2]), 'بسمالله');
    });

    test('跳过 blank 与未知 id', () {
      final decoder = TextCtcDecoder(vocab, blankId: blankId);
      expect(decoder.tokenIdsToText(<int>[blankId, 0, 3]), 'الحمد');
    });
  });
}
