/// 经文匹配：文本召回 + CTC 约束精排。
///
/// 两步式设计（与 Tilawa 的 discovery 阶段同思路，做了工程化简）：
/// 1. **文本召回**：用识别文本的首词做倒排锚点，再用编辑相似度筛出 top-K 候选，
///    避免对 6236 节全量做昂贵比对；
/// 2. **CTC 精排**：把候选（含 2–6 节连读的跨度）的 token 序列送入 CTC
///    前向后向算法，取平均负对数似然最小的候选作为冠军。
///
/// 实测（6 秒音频）：召回 117 个候选，冠军 acoustic=0.074，与次优差距 1.18。
library;

import 'ctc_scorer.dart';
import 'quran_assets.dart';
import 'quran_text.dart';

/// 匹配候选（可以是单节，也可以是多节连读跨度）。
class VerseMatchCandidate {
  /// 构造候选。
  ///
  /// @param surah 章号
  /// @param ayahStart 起始节
  /// @param ayahEnd 结束节（含）
  /// @param textScore 文本召回得分（0..1）
  /// @param acousticScore CTC 平均负对数似然（越小越好）
  /// @param tokenLength 该跨度 token 数
  /// @param verse 起始节的经文实体
  const VerseMatchCandidate({
    required this.surah,
    required this.ayahStart,
    required this.ayahEnd,
    required this.textScore,
    required this.acousticScore,
    required this.sortScore,
    required this.tokenLength,
    required this.verse,
  });

  /// 章号。
  final int surah;

  /// 起始节。
  final int ayahStart;

  /// 结束节（含）。
  final int ayahEnd;

  /// 文本召回得分。
  final double textScore;

  /// CTC 平均负对数似然（纯声学证据，用于展示与横向比较）。
  final double acousticScore;

  /// 排序分 = [acousticScore] + 跨度惩罚，仅用于候选排序。
  final double sortScore;

  /// token 数。
  final int tokenLength;

  /// 起始节经文。
  final QuranVerse verse;

  /// 是否为多节连读跨度。
  bool get isSpan => ayahEnd > ayahStart;

  /// 人类可读的引用（`2:255` 或 `2:255-257`）。
  String get ref => isSpan ? '$surah:$ayahStart-$ayahEnd' : '$surah:$ayahStart';

  /// 文本形式的展示标签（章名 + 节号）。
  String get label => '${verse.surahNameEn} $surah:$ayahStart${isSpan ? '-$ayahEnd' : ''}';

  @override
  String toString() => 'VerseMatchCandidate($ref, acoustic=$acousticScore)';
}

/// 一次匹配的完整结果。
class VerseMatchResult {
  /// 构造匹配结果。
  const VerseMatchResult({
    required this.champion,
    required this.runnersUp,
    required this.decodedText,
    required this.recallCount,
  });

  /// 冠军候选；无可行候选时为 null。
  final VerseMatchCandidate? champion;

  /// 其余候选（按 acoustic 升序，最多若干条）。
  final List<VerseMatchCandidate> runnersUp;

  /// 本次使用的识别文本。
  final String decodedText;

  /// 文本召回阶段的候选数量。
  final int recallCount;

  /// 冠军的置信度（0..1）：由与次优的 acoustic 差距映射而来。
  ///
  /// 差距越大越可信；无次优候选时按满分处理。
  double get confidence {
    final best = champion;
    if (best == null) return 0.0;
    if (runnersUp.isEmpty) return 1.0;
    final margin = runnersUp.first.sortScore - best.sortScore;
    if (margin <= 0) return 0.0;
    // 经验映射：差距 0.15 以上即认为非常明确
    return (margin / 0.15).clamp(0.0, 1.0);
  }
}

/// 经文匹配器。
class QuranMatcher {
  /// 构造匹配器并建立倒排索引。
  ///
  /// @param assets 已加载的数据资产
  QuranMatcher(this.assets) {
    for (var i = 0; i < assets.verses.length; i++) {
      final words = assets.verses[i].words;
      if (words.isEmpty) continue;
      final wordSet = words.toSet();
      _verseWordSets[i] = wordSet;
      for (final word in wordSet) {
        _byWord.putIfAbsent(word, () => <int>[]).add(i);
      }
    }
  }

  /// 数据资产。
  final QuranAssets assets;

  /// 词 -> 经文下标倒排索引（**全文**分词，不只用首词）。
  ///
  /// 只用首词做锚点会漏召回：诵读音频常以「太斯米」开头，而部分经文的文本
  /// 本身也带太斯米前缀，导致其「首词」与实际诵读的首词不一致（例如 36:1
  /// 文本为「بسم الله الرحمن الرحيم يس」，实际诵读正文首词是「يس」）。
  final Map<String, List<int>> _byWord = {};

  /// 每节经文的词集合缓存（用于覆盖率打分，避免重复构造）。
  final Map<int, Set<String>> _verseWordSets = {};

  /// 默认参与 CTC 精排的候选数。
  static const int defaultTopK = 64;

  /// 默认最大连读跨度（节）。
  static const int defaultMaxSpan = 4;

  /// 太斯米（بسم الله الرحمن الرحيم）对应的 token 序列。
  ///
  /// 词表中太斯米固定为这 5 个 token。部分经文的 token 表把太斯米并入「本章
  /// 第 1 节」，而跨度 > 1 的 token 序列不含太斯米；同时实际诵读音频**可能
  /// 不含太斯米**（Tilawa 官方语料中的单节样本即如此）。若候选序列凭空多出
  /// 这 5 个 token，会因匹配不到音频而失分，进而把单节诵读误判为连读。
  static const List<int> bismillahTokens = [351, 7, 59, 982, 986];

  /// 连读跨度惩罚系数（每多连读一节，加在排序分上的惩罚）。
  ///
  /// CTC 平均对数似然对长序列存在系统性偏好：token 越多，分母越大，且多出的
  /// token 还能「吸收」音频中的前缀/噪声帧，从而把平均损失压低。结果是单节
  /// 诵读容易被判成多节连读。加一个与跨度成正比的惩罚，使多节候选必须在声学
  /// 上明显更优（差 > 该系数）时才胜出。
  static const double defaultSpanPenalty = 0.35;

  /// 文本召回。
  ///
  /// 打分口径：**识别文本的词在经文中的覆盖率**（命中词数 / 识别词数）为主，
  /// 整句编辑相似度为辅。覆盖率对「识别文本只是经文一部分」的场景更可靠：
  /// 诵读常从太斯米后开念、或只念了节首几词，此时整句编辑相似度会因长度悬殊
  /// 接近 0，导致正确经节被挤出候选，而覆盖率仍接近 1。
  ///
  /// 若倒排命中过少，则回退到全量扫描（同样用覆盖率打分）。
  ///
  /// @param decoded 归一化后的识别文本
  /// @param limit 返回的候选数量上限
  /// @return 按文本得分降序的 (经文下标, 文本得分) 列表
  List<MapEntry<int, double>> recall(String decoded, {int limit = 200}) {
    if (decoded.trim().isEmpty) return const [];
    final words = decoded.split(' ').where((w) => w.isNotEmpty).toSet();
    if (words.isEmpty) return const [];

    // 全文倒排：统计每个经节命中了识别文本里的几个词
    final hitCount = <int, int>{};
    for (final word in words) {
      final hits = _byWord[word];
      if (hits == null) continue;
      for (final index in hits) {
        hitCount[index] = (hitCount[index] ?? 0) + 1;
      }
    }

    final candidates = <MapEntry<int, double>>[];
    if (hitCount.length < 8) {
      // 命中过少（识别文本生僻或含噪声）→ 全量覆盖率扫描
      for (var i = 0; i < assets.verses.length; i++) {
        candidates.add(MapEntry(i, _textScoreOf(i, words, decoded)));
      }
    } else {
      for (final index in hitCount.keys) {
        candidates.add(MapEntry(index, _textScoreOf(index, words, decoded)));
      }
    }

    candidates.sort((a, b) => b.value.compareTo(a.value));
    return candidates.length > limit ? candidates.sublist(0, limit) : candidates;
  }

  /// 给候选 token 序列打声学分（自动容忍音频缺失太斯米前缀）。
  ///
  /// 若候选序列以 [bismillahTokens] 开头，则额外评估一次「剥离太斯米后」的
  /// 序列，取两者中更优（更小）的分数，避免因音频未念太斯米而误罚该候选。
  ///
  /// @param evidence 声学证据
  /// @param tokens 候选 token 序列
  /// @return 平均负对数似然；不可行时返回 [CtcScorer.impossibleScore]
  double _scoreTokens(AcousticEvidence evidence, List<int> tokens) {
    var best = CtcScorer.scoreSequence(evidence, tokens);
    if (tokens.length > bismillahTokens.length && _startsWith(tokens, bismillahTokens)) {
      final trimmed = CtcScorer.scoreSequence(evidence, tokens.sublist(bismillahTokens.length));
      if (trimmed < best) best = trimmed;
    }
    return best;
  }

  static bool _startsWith(List<int> tokens, List<int> prefix) {
    if (tokens.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (tokens[i] != prefix[i]) return false;
    }
    return true;
  }

  /// 计算某经节对识别文本的召回得分（覆盖率为主、编辑相似度为辅）。
  ///
  /// @param index 经节下标
  /// @param words 识别文本的词集合
  /// @param decoded 识别文本
  /// @return 0..1 的召回得分；完全无词命中时为 0
  double _textScoreOf(int index, Set<String> words, String decoded) {
    final verseWords = _verseWordSets[index];
    if (verseWords == null || verseWords.isEmpty) return 0.0;
    var matched = 0;
    for (final word in words) {
      if (verseWords.contains(word)) matched++;
    }
    final coverage = matched / words.length;
    if (coverage == 0.0) return 0.0;
    final edit = QuranText.textScore(decoded, assets.verses[index].normalizedText);
    return coverage * 0.85 + edit * 0.15;
  }

  /// 执行「召回 + CTC 精排」，返回匹配结果。
  ///
  /// @param evidence 声学证据（一次前向推理的 log 概率）
  /// @param decoded 归一化识别文本
  /// @param topK 参与 CTC 精排的候选数
  /// @param maxSpan 最大连读跨度（节）
  /// @param spanPenalty 跨度惩罚系数（见 [defaultSpanPenalty]）
  /// @return 匹配结果
  VerseMatchResult match(
    AcousticEvidence evidence,
    String decoded, {
    int topK = defaultTopK,
    int maxSpan = defaultMaxSpan,
    double spanPenalty = defaultSpanPenalty,
  }) {
    final recalled = recall(decoded);
    if (recalled.isEmpty) {
      return VerseMatchResult(
        champion: null,
        runnersUp: const [],
        decodedText: decoded,
        recallCount: 0,
      );
    }

    final scored = <VerseMatchCandidate>[];
    for (final entry in recalled.take(topK)) {
      final verse = assets.verses[entry.key];
      for (var span = 1; span <= maxSpan; span++) {
        final ayahEnd = verse.ayah + span - 1;
        final tokens = assets.tokensFor(verse.surah, verse.ayah, ayahEnd);
        if (tokens == null || tokens.isEmpty) continue;
        final acoustic = _scoreTokens(evidence, tokens);
        if (acoustic >= CtcScorer.impossibleScore) continue;
        scored.add(
          VerseMatchCandidate(
            surah: verse.surah,
            ayahStart: verse.ayah,
            ayahEnd: ayahEnd,
            textScore: entry.value,
            acousticScore: acoustic,
            sortScore: acoustic + spanPenalty * (span - 1),
            tokenLength: tokens.length,
            verse: verse,
          ),
        );
      }
    }

    if (scored.isEmpty) {
      return VerseMatchResult(
        champion: null,
        runnersUp: const [],
        decodedText: decoded,
        recallCount: recalled.length,
      );
    }

    scored.sort((a, b) => a.sortScore.compareTo(b.sortScore));
    return VerseMatchResult(
      champion: scored.first,
      runnersUp: scored.length > 1 ? scored.sublist(1, scored.length > 12 ? 12 : scored.length) : const [],
      decodedText: decoded,
      recallCount: recalled.length,
    );
  }

  /// 取某节经文前后若干节，用于上下文展示。
  ///
  /// @param surah 章号
  /// @param ayah 节号
  /// @param context 前后各取几节
  /// @return 上下文经文（含当前节）
  List<QuranVerse> surrounding(int surah, int ayah, {int context = 2}) {
    final list = assets.versesBySurah[surah];
    if (list == null) return const [];
    final result = <QuranVerse>[];
    for (var a = ayah - context; a <= ayah + context; a++) {
      final verse = assets.verse(surah, a);
      if (verse != null) result.add(verse);
    }
    return result;
  }
}
