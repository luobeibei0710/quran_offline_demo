/// 提词器跟随：把「声学证据 + 候选经文」对齐成「已读到第几个词」。
///
/// 思路
/// ----
/// CTC 要求完整解释整段音频，若直接对整节 token 序列做强制对齐，会把还没
/// 朗读的 token 硬塞到末尾几帧，无法反映真实进度。因此改用**前缀可达性**：
/// 对「前 k 个词」的 token 前缀分别做 CTC 打分，随着 k 增大分数先降（读到
/// 更多真实内容）后升（多出的 token 缺乏声学证据）。取「分数在最优值容差内
/// 的最长前缀」即为用户当前读到的位置 —— 与 Tilawa 的稳定前缀选择同思路。
library;

import 'ctc_scorer.dart';
import 'quran_assets.dart';

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

  /// 估算已读词数。
  ///
  /// 对每个词边界处的前缀做 CTC 打分，返回「分数处于最优容差内」的最长词数。
  ///
  /// @param evidence 声学证据（本轮窗口）
  /// @param wordTokens 按词分组后的 token 序列
  /// @param tolerance 分数容差
  /// @return 已读词数（0..wordTokens.length）
  static int estimateReadWords(
    AcousticEvidence evidence,
    List<List<int>> wordTokens, {
    double tolerance = defaultTolerance,
  }) {
    if (wordTokens.isEmpty) return 0;

    // 逐词累加 token 前缀并打分（跳过不可行的前缀）
    final prefix = <int>[];
    final scores = <double>[];
    for (final group in wordTokens) {
      prefix.addAll(group);
      scores.add(CtcScorer.scoreSequence(evidence, prefix));
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
