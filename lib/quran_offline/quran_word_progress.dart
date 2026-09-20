/// 提词器跟随：把「声学证据 + 候选经文」对齐成「已读到第几个词」。
///
/// 思路
/// ----
/// CTC 要求完整解释整段音频，因此对整节 token 序列做强制对齐时，尚未朗读的 token
/// 会被硬塞到末尾几帧 —— 这恰好是可利用的信号：**被挤到音频内容区之后的 token 就是
/// 「还没念到」**。默认做法即帧级强制对齐（[CtcScorer.alignFrames]）+ 内容区边界
/// （[CtcScorer.lastContentFrame]），不依赖任何容差常数。
///
/// 序列帧数不足（不可行）时退回**前缀可达性**（见 [estimateReadWordsByPrefix]）：
/// 对「前 k 个词」的 token 前缀分别做 CTC 打分，随着 k 增大分数先降（读到更多真实
/// 内容）后升（多出的 token 缺乏声学证据），取「分数在最优值容差内的最长前缀」。
library;

import 'ctc_scorer.dart';
import 'quran_assets.dart';

/// 已读进度的帧级结果。
class QuranReadProgress {
  /// 构造已读进度。
  ///
  /// @param readWords 已读词数
  /// @param endFrame 已读内容在声学证据中的最后一帧；无可用位置时为 -1
  const QuranReadProgress({required this.readWords, required this.endFrame});

  /// 已读词数（0..词数）。
  final int readWords;

  /// 已读内容在证据中的最后一帧（-1 表示不可用，例如走了前缀法回退路径）。
  ///
  /// 会话层用它把窗口前部已读的音频裁掉，使识别随进度推进（见
  /// `QuranStreamingConfig.advanceWindowOnCommit`）。
  final int endFrame;

  @override
  String toString() => 'QuranReadProgress(readWords=$readWords, endFrame=$endFrame)';
}

/// 词级跟随进度。
class QuranWordProgress {
  QuranWordProgress._();

  /// 判定「已读」的分数容差：前缀分数不超过最优值 + 该容差即认为已读到。
  static const double defaultTolerance = 0.35;

  /// 每个词至少需要的 token 数（用于把 token 序列切成词）。
  ///
  /// 词表是 BPE 子词，`▁` 前缀表示新词开始。
  static const String wordBoundaryMarker = '\u2581';

  /// 把 token 序列按 BPE 词边界切成词组。
  ///
  /// @param tokens 候选 token 序列
  /// @param vocab token id -> token 文本
  /// @return 每个词对应的 token 子序列（保持原顺序）
  static List<List<int>> groupByWord(List<int> tokens, Map<int, String> vocab) {
    final groups = <List<int>>[];
    for (final token in tokens) {
      final text = vocab[token] ?? '';
      if (text.startsWith(wordBoundaryMarker) || groups.isEmpty) {
        groups.add(<int>[token]);
      } else {
        groups.last.add(token);
      }
    }
    return groups;
  }

  /// 估算已读词数（帧级强制对齐，默认路径）。
  ///
  /// 做法：对候选序列做强制对齐（[CtcScorer.alignFrames]）得到每个词的发射起始帧，
  /// 取「起始帧落在音频内容区（[CtcScorer.lastContentFrame]）之内」的最长前缀词数。
  /// 尾部没有内容证据的词会被 CTC 挤压到空白帧，因此判为「尚未念到」。
  ///
  /// 相比前缀打分 + 容差的做法，本方法**不依赖任何容差常数**；序列帧数不足
  /// （不可行）时退回 [estimateReadWordsByPrefix]。
  ///
  /// @param evidence 声学证据（本轮窗口）
  /// @param wordTokens 按词分组后的 token 序列
  /// @return 已读词数（0..wordTokens.length）
  static int estimateReadWords(AcousticEvidence evidence, List<List<int>> wordTokens) =>
      estimateReadProgress(evidence, wordTokens).readWords;

  /// 估算已读进度（帧级强制对齐），同时给出已读内容的**结束帧位置**。
  ///
  /// 与 [estimateReadWords] 同一算法，额外返回 [QuranReadProgress.endFrame]，
  /// 供会话层裁剪窗口前部（识别随进度推进）。
  ///
  /// @param evidence 声学证据（本轮窗口）
  /// @param wordTokens 按词分组后的 token 序列
  /// @return 已读词数与结束帧；位置不可用时 [QuranReadProgress.endFrame] 为 -1
  static QuranReadProgress estimateReadProgress(
    AcousticEvidence evidence,
    List<List<int>> wordTokens,
  ) {
    if (wordTokens.isEmpty) return const QuranReadProgress(readWords: 0, endFrame: -1);

    final flat = <int>[];
    final tokenCounts = <int>[];
    for (final group in wordTokens) {
      flat.addAll(group);
      tokenCounts.add(group.length);
    }
    if (flat.isEmpty) return const QuranReadProgress(readWords: 0, endFrame: -1);

    final spans = CtcScorer.alignFrames(evidence, flat);
    if (spans == null) {
      // 帧数不足（序列不可行）：退回前缀法，此时没有可用的帧位置
      return QuranReadProgress(
        readWords: estimateReadWordsByPrefix(evidence, wordTokens),
        endFrame: -1,
      );
    }

    final contentEnd = CtcScorer.lastContentFrame(evidence);
    if (contentEnd < 0) return const QuranReadProgress(readWords: 0, endFrame: -1);

    var readWords = 0;
    var tokenIndex = 0;
    var endFrame = -1;
    for (final count in tokenCounts) {
      if (spans[tokenIndex].start > contentEnd) break;
      endFrame = spans[tokenIndex + count - 1].end;
      readWords++;
      tokenIndex += count;
    }
    return QuranReadProgress(readWords: readWords, endFrame: endFrame);
  }

  /// 前缀打分法估算已读词数（[estimateReadWords] 的回退路径）。
  ///
  /// 对每个词边界处的前缀做 CTC 打分（按 token 口径），返回「分数处于最优容差内」
  /// 的最长词数；序列整体不可行时返回 0。
  ///
  /// @param evidence 声学证据（本轮窗口）
  /// @param wordTokens 按词分组后的 token 序列
  /// @param tolerance 分数容差
  /// @return 已读词数（0..wordTokens.length）
  static int estimateReadWordsByPrefix(
    AcousticEvidence evidence,
    List<List<int>> wordTokens, {
    double tolerance = defaultTolerance,
  }) {
    if (wordTokens.isEmpty) return 0;

    // 逐词累加 token 前缀并打分（跳过不可行的前缀）
    //
    // 这里沿用**按 token** 口径：最优前缀位置与按帧口径一致（两者只差一个常数
    // 因子），差异只在容差带的尺度 —— 而 [defaultTolerance] 正是在该口径下标定的，
    // 保留口径即可不动这个已调好的常数（见 [CtcNormalization]）。
    final prefix = <int>[];
    final scores = <double>[];
    for (final group in wordTokens) {
      prefix.addAll(group);
      scores.add(
        CtcScorer.scoreSequence(evidence, prefix, normalize: CtcNormalization.perToken),
      );
    }

    // 找到分数最低（最匹配）的前缀位置
    var bestIndex = 0;
    var bestScore = scores[0];
    for (var i = 1; i < scores.length; i++) {
      if (scores[i] < bestScore) {
        bestScore = scores[i];
        bestIndex = i;
      }
    }
    if (bestScore >= CtcScorer.impossibleScore) return 0;

    // 从最优位置向后延伸：只要仍在容差内就认为该词也已读到
    var chosen = bestIndex;
    for (var i = bestIndex + 1; i < scores.length; i++) {
      if (scores[i] < CtcScorer.impossibleScore && scores[i] - bestScore <= tolerance) {
        chosen = i;
      } else {
        break;
      }
    }
    return chosen + 1;
  }

  /// 取某跨度内所有经节的词（用于提词器逐词显示）。
  ///
  /// @param assets 数据资产
  /// @param surah 章号
  /// @param ayahStart 起始节
  /// @param ayahEnd 结束节（含）
  /// @return 词列表；数据缺失时返回空列表
  static List<String> wordsOfSpan(QuranAssets assets, int surah, int ayahStart, int ayahEnd) {
    final words = <String>[];
    for (var ayah = ayahStart; ayah <= ayahEnd; ayah++) {
      final verse = assets.verse(surah, ayah);
      if (verse == null) continue;
      words.addAll(verse.words);
    }
    return words;
  }

  /// 计算某跨度内的 token 词组（与 [wordsOfSpan] 对齐）。
  ///
  /// 当 token 词组数与经文词数不一致时（例如 token 表带太斯米而经文不含），
  /// 以较少的一方为准截断，保证高亮不错位。
  ///
  /// @param assets 数据资产
  /// @param surah 章号
  /// @param ayahStart 起始节
  /// @param ayahEnd 结束节（含）
  /// @return `(经文词列表, token 词组)`，长度一致
  static (List<String>, List<List<int>>) alignedWords(
    QuranAssets assets,
    int surah,
    int ayahStart,
    int ayahEnd,
  ) {
    final words = wordsOfSpan(assets, surah, ayahStart, ayahEnd);
    final tokens = assets.tokensFor(surah, ayahStart, ayahEnd);
    if (tokens == null || tokens.isEmpty) return (words, const []);

    final groups = groupByWord(tokens, assets.vocab);
    if (groups.length == words.length) return (words, groups);

    if (groups.length > words.length) {
      // token 多出的部分（如太斯米前缀）：从头部对齐更稳妥
      final extra = groups.length - words.length;
      return (words, groups.sublist(extra));
    }
    return (words.sublist(0, groups.length), groups);
  }
}
