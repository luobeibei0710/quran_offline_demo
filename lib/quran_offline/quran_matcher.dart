/// 经文匹配：文本召回 + CTC 约束精排。
///
/// 两步式设计（与 Tilawa 的 discovery 阶段同思路，做了工程化简）：
/// 1. **文本召回**：用识别文本的首词做倒排锚点，再用编辑相似度筛出 top-K 候选，
///    避免对 6236 节全量做昂贵比对；
/// 2. **CTC 精排**：把候选（含 2–6 节连读的跨度）的 token 序列送入 CTC
///    前向后向算法，取每帧平均负对数似然最小的候选作为冠军。
///
/// 打分与跨度惩罚的标定数据见 `tools/quran_offline/tune_span_penalty.py`。
library;

import 'dart:math' as math;

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

  /// CTC 每帧平均负对数似然（纯声学证据，用于展示与横向比较）。
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

  /// 冠军的置信度（0..1）：由与次优的排序分差距按**相对尺度**映射而来。
  ///
  /// 差距越大越可信；无次优候选时按满分处理；最优分接近 0（完美匹配）时
  /// 直接按满分处理，避免除以近零的尺度。
  double get confidence {
    final best = champion;
    if (best == null) return 0.0;
    if (runnersUp.isEmpty) return 1.0;
    final margin = runnersUp.first.sortScore - best.sortScore;
    if (margin <= 0) return 0.0;
    final scale = best.sortScore.abs() * QuranMatcher.confidenceRelativeMargin;
    if (scale <= 1e-9) return 1.0;
    return (margin / scale).clamp(0.0, 1.0);
  }
}

/// 经文匹配器。
class QuranMatcher {
  /// 构造匹配器并建立倒排索引。
  ///
  /// @param verseIndex 经文索引（旧库或广播新库），只使用其经文与 token 数据
  /// @param lengthFitWeight 召回打分中「长度匹配度」的权重，默认 0（保持旧库语义）
  QuranMatcher(this.verseIndex, {this.lengthFitWeight = 0}) {
    for (var i = 0; i < verseIndex.verses.length; i++) {
      final words = verseIndex.verses[i].words;
      if (words.isEmpty) continue;
      final wordSet = words.toSet();
      _verseWordSets[i] = wordSet;
      for (final word in wordSet) {
        _byWord.putIfAbsent(word, () => <int>[]).add(i);
      }
    }
  }

  /// 经文索引（决定在哪个语料库内检索）。
  final VerseIndex verseIndex;

  /// 召回打分中「长度匹配度」的权重。
  ///
  /// 默认 0 表示完全沿用旧库语义（只看覆盖率与编辑相似度）。全经 6236 节下必须
  /// 打开它：按覆盖率召回时，极短节会系统性占满候选池 —— 实测全经有 553 个
  /// ≤3 词的节，长转写里命中一两个常见词就能让它们覆盖率接近 1.0，而长节因为
  /// 词多、覆盖率天然偏低，于是正确候选根本进不了 topK。
  ///
  /// 打开后打分变为 `覆盖率×(0.85−w) + 编辑相似度×0.15 + 长度匹配度×w`，
  /// 其中长度匹配度 = min(转写词数, 候选词数) / max(两者)。
  final double lengthFitWeight;

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

  /// 长度匹配度低于该值才视为「明显过短」并降权。
  ///
  /// 取 0.35：转写 60 词时，15 词的正常节（比值 0.25）会被轻微降权，
  /// 而 2-3 词的极短节（比值 0.03-0.05）会被显著降权 —— 后者才是要治理的对象。
  static const double lengthFitFloor = 0.35;

  /// 默认返回的次优候选数量上限。
  ///
  /// 旧库沿用 12；广播功能会放大该值，因为它的上层次裁决需要看到**长跨度**候选 ——
  /// 真机实测中短节因按帧归一化的分数更优而占满前 12 名，导致真正的多节跨度候选
  /// 进不了裁决池，长转写被匹配成 7 词单节。
  static const int defaultRunnerUpLimit = 12;

  /// 置信度映射用的**相对**差距：与次优的排序分差距达到最优分的该比例即认为非常明确。
  ///
  /// 用相对值而非绝对值，是为了与打分口径/窗口长度解耦 —— 分数是「每帧」量纲，
  /// 绝对值随窗口长度变化，固定常数会在不同窗口长度下表现不一致（曾出现正确结果
  /// 置信度只有 0.22 的失真）。
  static const double confidenceRelativeMargin = 0.15;

  /// 太斯米（بسم الله الرحمن الرحيم）对应的 token 序列。
  ///
  /// 词表中太斯米固定为这 5 个 token。部分经文的 token 表把太斯米并入「本章
  /// 第 1 节」，而跨度 > 1 的 token 序列不含太斯米；同时实际诵读音频**可能
  /// 不含太斯米**（Tilawa 官方语料中的单节样本即如此）。若候选序列凭空多出
  /// 这 5 个 token，会因匹配不到音频而失分，进而把单节诵读误判为连读。
  static const List<int> bismillahTokens = [351, 7, 59, 982, 986];

  /// 连读跨度惩罚系数（每多连读一节，加在排序分上的惩罚）。
  ///
  /// 打分已按**帧数**归一化（见 [CtcScorer.scoreSequence]），「token 越多分母越大」
  /// 的系统性偏好已消除，因此这里只需一个很小的安全余量：多节候选必须在声学上
  /// 更优（每多一节差 > 该系数）才胜出。
  ///
  /// 取值依据 `tools/quran_offline/tune_span_penalty.py`：官方 5 条样本下，「正确单节」
  /// 与「最佳跨度扩展」的按帧分数差距最小为 0.335（`1:2`），故系数必须 < 0.335；
  /// 取 0.1 为跨平台（x86 / ARM）差异留出余量。
  static const double defaultSpanPenalty = 0.1;

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
    final wordList = decoded.split(' ').where((w) => w.isNotEmpty).toList(growable: false);
    final words = wordList.toSet();
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
      for (var i = 0; i < verseIndex.verses.length; i++) {
        candidates.add(MapEntry(i, _textScoreOf(i, words, decoded, wordList.length)));
      }
    } else {
      for (final index in hitCount.keys) {
        candidates.add(MapEntry(index, _textScoreOf(index, words, decoded, wordList.length)));
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
  /// [lengthFitWeight] 为 0 时与旧库语义逐位一致；大于 0 时额外计入长度匹配度，
  /// 用于在全经规模下抑制极短节对候选池的垄断。
  ///
  /// @param verseIndex 经节下标
  /// @param words 识别文本的词集合
  /// @param decoded 识别文本
  /// @param decodedWordCount 识别文本的词数（调用方预算，避免重复分词）
  /// @return 0..1 的召回得分；完全无词命中时为 0
  double _textScoreOf(int verseIndex, Set<String> words, String decoded, int decodedWordCount) {
    final verseWords = _verseWordSets[verseIndex];
    if (verseWords == null || verseWords.isEmpty) return 0.0;
    var matched = 0;
    for (final word in words) {
      if (verseWords.contains(word)) matched++;
    }
    final coverage = matched / words.length;
    if (coverage == 0.0) return 0.0;
    final edit = QuranText.textScore(decoded, this.verseIndex.verses[verseIndex].normalizedText);
    if (lengthFitWeight <= 0) return coverage * 0.85 + edit * 0.15;
    final verseWordCount = verseWords.length;
    final longer = math.max(decodedWordCount, verseWordCount);
    final lengthFit = longer == 0 ? 0.0 : math.min(decodedWordCount, verseWordCount) / longer;
    // 只惩罚「明显过短」的候选。若按 lengthFit 全额加权，正确的中等长度节也会因
    // 「长转写 vs 中节」被一起挤出召回池（实测会让 67:14 输给 67:15）。
    final shortfall = math.max(0.0, lengthFitFloor - lengthFit);
    return coverage * 0.85 + edit * 0.15 - shortfall * lengthFitWeight;
  }

  /// 执行「召回 + CTC 精排」，返回匹配结果。
  ///
  /// @param evidence 声学证据（一次前向推理的 log 概率）
  /// @param decoded 归一化识别文本
  /// @param topK 参与 CTC 精排的候选数
  /// @param maxSpan 最大连读跨度（节）
  /// @param spanPenalty 跨度惩罚系数（见 [defaultSpanPenalty]）
  /// @param runnerUpLimit 返回的次优候选数量上限；调用方可放大以扩大上层裁决池
  /// @return 匹配结果
  VerseMatchResult match(
    AcousticEvidence evidence,
    String decoded, {
    int topK = defaultTopK,
    int maxSpan = defaultMaxSpan,
    double spanPenalty = defaultSpanPenalty,
    int runnerUpLimit = defaultRunnerUpLimit,
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
      final verse = verseIndex.verses[entry.key];
      for (var span = 1; span <= maxSpan; span++) {
        final ayahEnd = verse.ayah + span - 1;
        final tokens = verseIndex.tokensFor(verse.surah, verse.ayah, ayahEnd);
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
      runnersUp: scored.length > 1
          ? scored.sublist(1, scored.length > runnerUpLimit ? runnerUpLimit : scored.length)
          : const [],
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
    final list = verseIndex.versesOfSurah(surah);
    if (list == null) return const [];
    final result = <QuranVerse>[];
    for (var a = ayah - context; a <= ayah + context; a++) {
      final verse = verseIndex.verse(surah, a);
      if (verse != null) result.add(verse);
    }
    return result;
  }
}
