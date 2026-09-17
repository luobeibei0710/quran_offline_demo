/// 原文与转写的词级比对：对齐、逐词判定与整体指标。
///
/// 用途：把「朗读原文」（参考答案，来自 `reference_text.txt`）与「端侧转写结果」
/// 逐词对齐，输出对照行与指标，供比对页面（`quran_compare_page.dart`）展示。
///
/// 为什么用动态规划而不是按下标硬比：转写会漏词、多词、把两个词合成一个词，
/// 一旦发生，按下标比较会让后面所有词全部判错。这里用 Needleman–Wunsch 对齐，
/// 词的相似度取归一化后的字符级 Levenshtein 比例（[QuranText.ratio]），
/// 缺词/多词各扣 [WordAlignment.gapPenalty]。
library;

import 'quran_text.dart';

/// 单个对照行的判定状态。
enum WordStatus {
  /// 一致：相似度 ≥ [WordAlignment.matchThreshold]。
  match,

  /// 近似：相似度处于 [[WordAlignment.nearThreshold], [WordAlignment.matchThreshold])。
  near,

  /// 错配：相似度 < [WordAlignment.nearThreshold]。
  mismatch,

  /// 缺失：原文有、转写没有。
  missing,

  /// 多余：转写有、原文没有（多为误识别灌入的词）。
  extra,
}

/// 一行对照结果（左右各一个词，或其中一侧为空）。
class AlignedWord {
  /// 构造对照行。
  ///
  /// @param status 判定状态
  /// @param reference 原文词（[WordStatus.extra] 时为 null）
  /// @param hypothesis 转写词（[WordStatus.missing] 时为 null）
  /// @param score 两词相似度 0..1（单侧为空时为 0）
  const AlignedWord({
    required this.status,
    this.reference,
    this.hypothesis,
    this.score = 0,
  });

  /// 判定状态。
  final WordStatus status;

  /// 原文词。
  final String? reference;

  /// 转写词。
  final String? hypothesis;

  /// 相似度 0..1。
  final double score;

  @override
  String toString() => 'AlignedWord(${status.name}, ${reference ?? '-'} / ${hypothesis ?? '-'})';
}

/// 一次比对的完整结果。
class AlignmentResult {
  const AlignmentResult._({
    required this.rows,
    required this.referenceCount,
    required this.hypothesisCount,
    required this.matchCount,
    required this.nearCount,
    required this.mismatchCount,
    required this.missingCount,
    required this.extraCount,
    required this.coverage,
    required this.precision,
    required this.f1,
    required this.averageScore,
    required this.verdict,
  });

  /// 逐词对照行（按原文顺序）。
  final List<AlignedWord> rows;

  /// 原文词数。
  final int referenceCount;

  /// 转写词数。
  final int hypothesisCount;

  /// 一致词数（相似度 ≥ [WordAlignment.matchThreshold]）。
  final int matchCount;

  /// 近似词数。
  final int nearCount;

  /// 错配词数。
  final int mismatchCount;

  /// 缺失词数（原文有、转写无）。
  final int missingCount;

  /// 多余词数（转写有、原文无）。
  final int extraCount;

  /// 转写覆盖率：原文有多少比例被念到并识别出来（近似词按 0.5 计）。
  final double coverage;

  /// 转写准确率：转写出的词有多少比例确实属于原文（近似词按 0.5 计）。
  final double precision;

  /// 覆盖率与准确率的调和平均。
  final double f1;

  /// 已对齐词对的平均相似度 0..1。
  final double averageScore;

  /// 文字结论（见 [WordAlignment.verdictOf]）。
  final String verdict;

  /// 是否有比对内容。
  bool get isEmpty => rows.isEmpty;
}

/// 原文与转写的词级比对。
class WordAlignment {
  WordAlignment._();

  /// 判定为「一致」的相似度下限。
  static const double matchThreshold = 0.80;

  /// 判定为「近似」的相似度下限（低于此值算错配）。
  static const double nearThreshold = 0.50;

  /// 缺词 / 多词的对齐惩罚（每个词）。
  static const double gapPenalty = 0.5;

  /// 整体结论「优秀」的 F1 下限。
  static const double excellentF1 = 0.90;

  /// 整体结论「良好」的 F1 下限。
  static const double goodF1 = 0.75;

  /// 整体结论「一般」的 F1 下限（低于此值为「较差」）。
  static const double fairF1 = 0.55;

  /// 对齐两组词并统计指标。
  ///
  /// @param reference 原文词序列（可含音标/书写变体，内部会归一化）
  /// @param hypothesis 转写词序列
  /// @return 对齐结果（含逐词对照行与指标）
  static AlignmentResult align(List<String> reference, List<String> hypothesis) {
    final refWords = _clean(reference);
    final hypWords = _clean(hypothesis);
    final refNormalized = refWords.map(QuranText.normalize).toList(growable: false);
    final hypNormalized = hypWords.map(QuranText.normalize).toList(growable: false);

    final n = refWords.length;
    final m = hypWords.length;
    // dp[i][j]：前 i 个原文词与前 j 个转写词的最优对齐得分
    final dp = List<List<double>>.generate(n + 1, (_) => List<double>.filled(m + 1, 0), growable: false);
    for (var i = 1; i <= n; i++) {
      dp[i][0] = -gapPenalty * i;
    }
    for (var j = 1; j <= m; j++) {
      dp[0][j] = -gapPenalty * j;
    }
    for (var i = 1; i <= n; i++) {
      for (var j = 1; j <= m; j++) {
        final similarity = _similarity(refNormalized[i - 1], hypNormalized[j - 1]);
        final diag = dp[i - 1][j - 1] + similarity;
        final up = dp[i - 1][j] - gapPenalty;
        final left = dp[i][j - 1] - gapPenalty;
        // 同分时优先对角：能形成「词对词」而不是「缺失 + 多余」
        dp[i][j] = diag >= up ? (diag >= left ? diag : left) : (up >= left ? up : left);
      }
    }

    final rows = <AlignedWord>[];
    var i = n;
    var j = m;
    while (i > 0 || j > 0) {
      if (i > 0 && j > 0) {
        final similarity = _similarity(refNormalized[i - 1], hypNormalized[j - 1]);
        if (dp[i][j] == dp[i - 1][j - 1] + similarity) {
          rows.add(
            AlignedWord(
              status: statusOf(similarity),
              reference: refWords[i - 1],
              hypothesis: hypWords[j - 1],
              score: similarity,
            ),
          );
          i--;
          j--;
          continue;
        }
      }
      if (i > 0 && (j == 0 || dp[i][j] == dp[i - 1][j] - gapPenalty)) {
        rows.add(AlignedWord(status: WordStatus.missing, reference: refWords[i - 1]));
        i--;
        continue;
      }
      rows.add(AlignedWord(status: WordStatus.extra, hypothesis: hypWords[j - 1]));
      j--;
    }
    final ordered = rows.reversed.toList(growable: false);

    var matchCount = 0;
    var nearCount = 0;
    var mismatchCount = 0;
    var missingCount = 0;
    var extraCount = 0;
    var scoreSum = 0.0;
    var pairCount = 0;
    for (final row in ordered) {
      switch (row.status) {
        case WordStatus.match:
          matchCount++;
        case WordStatus.near:
          nearCount++;
        case WordStatus.mismatch:
          mismatchCount++;
        case WordStatus.missing:
          missingCount++;
        case WordStatus.extra:
          extraCount++;
      }
      if (row.reference != null && row.hypothesis != null) {
        scoreSum += row.score;
        pairCount++;
      }
    }

    final hitWeight = matchCount + 0.5 * nearCount;
    final coverage = n == 0 ? 0.0 : hitWeight / n;
    final precision = m == 0 ? 0.0 : hitWeight / m;
    final f1 = (coverage + precision) == 0 ? 0.0 : 2 * coverage * precision / (coverage + precision);

    return AlignmentResult._(
      rows: ordered,
      referenceCount: n,
      hypothesisCount: m,
      matchCount: matchCount,
      nearCount: nearCount,
      mismatchCount: mismatchCount,
      missingCount: missingCount,
      extraCount: extraCount,
      coverage: coverage,
      precision: precision,
      f1: f1,
      averageScore: pairCount == 0 ? 0.0 : scoreSum / pairCount,
      verdict: verdictOf(f1),
    );
  }

  /// 按相似度给出单行判定状态。
  ///
  /// @param similarity 归一化词相似度 0..1
  /// @return 判定状态
  static WordStatus statusOf(double similarity) {
    if (similarity >= matchThreshold) return WordStatus.match;
    if (similarity >= nearThreshold) return WordStatus.near;
    return WordStatus.mismatch;
  }

  /// 按 F1 给出整体结论。
  ///
  /// @param f1 覆盖率与准确率的调和平均
  /// @return 「优秀」/「良好」/「一般」/「较差」
  static String verdictOf(double f1) {
    if (f1 >= excellentF1) return '优秀';
    if (f1 >= goodF1) return '良好';
    if (f1 >= fairF1) return '一般';
    return '较差';
  }

  /// 去除空词并保留原始书写形式。
  static List<String> _clean(List<String> words) =>
      words.map((w) => w.trim()).where((w) => w.isNotEmpty).toList(growable: false);

  /// 两词相似度；完全相同直接返回 1，避免重复计算。
  static double _similarity(String a, String b) {
    if (a.isEmpty || b.isEmpty) return 0;
    if (a == b) return 1;
    return QuranText.ratio(a, b);
  }
}
