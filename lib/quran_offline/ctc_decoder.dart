/// CTC 解码：把声学模型的逐帧 log 概率还原为阿拉伯语文本。
///
/// 本文件与 Tilawa 的 `text-ctc-decode.ts` 等价，输入输出规格已在实际模型上验证：
/// 模型输出 `log_probs` 形状 `[1, frames, vocab]`，其中 `vocab` 最后一维即 blank。
library;

import 'dart:typed_data';

import 'quran_text.dart';

/// 一次 CTC 解码的结果。
class TextCtcResult {
  /// 构造解码结果。
  ///
  /// @param text 归一化后的阿拉伯语文本
  /// @param tokenIds 去除重复与 blank 后的 token 序列
  /// @param wordEnds 每个词结束位置在 [tokenIds] 中的下标
  const TextCtcResult({
    required this.text,
    required this.tokenIds,
    required this.wordEnds,
    this.tokenStarts = const [],
    this.tokenEnds = const [],
  });

  /// 归一化后的文本。
  final String text;

  /// token 序列（已合并相邻重复并去除 blank）。
  final List<int> tokenIds;

  /// 词结束下标，用于词级进度展示。
  final List<int> wordEnds;

  /// 每个折叠 token 对应的起止帧（含端点），用于跨窗口时间对齐。
  final List<int> tokenStarts;
  final List<int> tokenEnds;
}

/// 文本 CTC 解码器。
class TextCtcDecoder {
  /// 词边界前缀符（SentencePiece 的 `▁`）。
  static const String wordPrefix = '\u2581';

  /// 构建解码器。
  ///
  /// @param vocab token id -> token 文本（来自 `vocab.json`）
  /// @param blankId blank token 的 id，默认为词表最大 id
  TextCtcDecoder(Map<int, String> vocab, {int? blankId})
    : _vocab = vocab,
      _blankId = blankId ?? (vocab.keys.isEmpty ? 0 : vocab.keys.reduce((a, b) => a > b ? a : b));

  final Map<int, String> _vocab;
  final int _blankId;

  /// blank token 的 id。
  int get blankId => _blankId;

  /// 执行贪心 CTC 解码。
  ///
  /// 逐帧取 argmax，再合并相邻重复并去除 blank（标准 CTC 折叠），
  /// 最后拼接 token 文本并做阿拉伯语归一化。
  ///
  /// @param logprobs 行主序展开的 `[timeSteps, vocabSize]` log 概率
  /// @param timeSteps 帧数
  /// @param vocabSize 词表大小
  /// @return 解码结果
  TextCtcResult decode(Float32List logprobs, int timeSteps, int vocabSize) {
    final tokenIds = <int>[];
    final starts = <int>[];
    final ends = <int>[];
    var previous = -1;

    for (var t = 0; t < timeSteps; t++) {
      final offset = t * vocabSize;
      var bestIndex = 0;
      var bestValue = logprobs[offset];
      for (var v = 1; v < vocabSize; v++) {
        final value = logprobs[offset + v];
        if (value > bestValue) {
          bestValue = value;
          bestIndex = v;
        }
      }
      if (bestIndex != previous && bestIndex != _blankId) {
        tokenIds.add(bestIndex);
        starts.add(t);
        ends.add(t);
      } else if (bestIndex == previous && bestIndex != _blankId && ends.isNotEmpty) {
        ends[ends.length - 1] = t;
      }
      previous = bestIndex;
    }

    return TextCtcResult(
      text: tokenIdsToText(tokenIds),
      tokenIds: tokenIds,
      wordEnds: tokenIdsToWordEnds(tokenIds),
      tokenStarts: starts,
      tokenEnds: ends,
    );
  }

  /// token 序列转归一化文本。
  String tokenIdsToText(List<int> tokenIds) {
    final buffer = StringBuffer();
    for (final id in tokenIds) {
      if (id == _blankId) continue;
      final token = _vocab[id];
      if (token == null || token.isEmpty || token == '<unk>' || token == '<blank>') {
        continue;
      }
      buffer.write(token);
    }
    return QuranText.normalize(buffer.toString().replaceAll(wordPrefix, ' '));
  }

  /// 计算每个词的结束下标（用于词级进度）。
  ///
  /// 规则：遇到以 `▁` 开头的 token 表示新词开始，前一个词在此结束。
  List<int> tokenIdsToWordEnds(List<int> tokenIds) {
    final tokens = <String>[];
    for (final id in tokenIds) {
      if (id == _blankId) continue;
      final token = _vocab[id];
      if (token == null || token.isEmpty || token == '<unk>') continue;
      tokens.add(token);
    }

    final ends = <int>[];
    var inWord = false;
    for (var i = 0; i < tokens.length; i++) {
      final token = tokens[i];
      if (token == wordPrefix || token.startsWith(wordPrefix)) {
        if (inWord) ends.add(i);
        inWord = token != wordPrefix;
        continue;
      }
      inWord = true;
    }
    if (inWord) ends.add(tokens.length);
    return ends;
  }
}
