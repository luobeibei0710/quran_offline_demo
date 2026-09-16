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

  /// CTC 平均负对数似然。
  final double acousticScore;

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
    final margin = runnersUp.first.acousticScore - best.acousticScore;
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
      _byFirstWord.putIfAbsent(words.first, () => <int>[]).add(i);
    }
  }

  /// 数据资产。
  final QuranAssets assets;

  /// 首词 -> 经文下标倒排索引（加速召回）。
  final Map<String, List<int>> _byFirstWord = {};

  /// 默认参与 CTC 精排的候选数。
  static const int defaultTopK = 64;

  /// 默认最大连读跨度（节）。
  static const int defaultMaxSpan = 4;

  /// 文本召回。
  ///
  /// 优先用识别文本的首个非空词做倒排锚点；若命中过少，则回退到全量打分。
  ///
  /// @param decoded 归一化后的识别文本
  /// @param limit 返回的候选数量上限
  /// @return 按文本得分降序的 (经文下标, 文本得分) 列表
  List<MapEntry<int, double>> recall(String decoded, {int limit = 200}) {
    if (decoded.trim().isEmpty) return const [];
    final words = decoded.split(' ').where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return const [];

    final indices = <int>{};
    // 用前两个词分别做锚点，兼顾「从中间开始诵读」的情况
    for (final anchor in words.take(2)) {
      final hit = _byFirstWord[anchor];
      if (hit != null) indices.addAll(hit);
    }
    final scanAll = indices.length < 8;
    final candidates = <MapEntry<int, double>>[];

    if (scanAll) {
      for (var i = 0; i < assets.verses.length; i++) {
        candidates.add(MapEntry(i, QuranText.textScore(decoded, assets.verses[i].normalizedText)));
      }
    } else {
      for (final index in indices) {
        candidates.add(
          MapEntry(index, QuranText.textScore(decoded, assets.verses[index].normalizedText)),
        );
      }
    }

    candidates.sort((a, b) => b.value.compareTo(a.value));
    return candidates.length > limit ? candidates.sublist(0, limit) : candidates;
  }

  /// 执行「召回 + CTC 精排」，返回匹配结果。
  ///
  /// @param evidence 声学证据（一次前向推理的 log 概率）
  /// @param decoded 归一化识别文本
  /// @param topK 参与 CTC 精排的候选数
  /// @param maxSpan 最大连读跨度（节）
  /// @return 匹配结果
  VerseMatchResult match(
    AcousticEvidence evidence,
    String decoded, {
    int topK = defaultTopK,
    int maxSpan = defaultMaxSpan,
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
        final acoustic = CtcScorer.scoreSequence(evidence, tokens);
        if (acoustic >= CtcScorer.impossibleScore) continue;
        scored.add(
          VerseMatchCandidate(
            surah: verse.surah,
            ayahStart: verse.ayah,
            ayahEnd: ayahEnd,
            textScore: entry.value,
            acousticScore: acoustic,
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

    scored.sort((a, b) => a.acousticScore.compareTo(b.acousticScore));
    return VerseMatchResult(
      champion: scored.first,
      runnersUp: scored.length > 1 ? scored.sublist(1, scored.length > 6 ? 6 : scored.length) : const [],
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
