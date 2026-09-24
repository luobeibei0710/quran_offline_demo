/// 广播片段 → 独立新库经文匹配：召回 + CTC 精排 + 候选裁决 + 可信判定 + 指标。
///
/// 只在注入的 [BroadcastQuranLibrary]（全经 114 章 6236 节）内检索；检索不到时返回
/// [MatchStatus.unmatched] 并保留真实 ASR 转写，**不会**回退旧经文库，也不会
/// 返回「任意最相似的经文」。
///
/// 「一句」不等于「一节」：一个片段可以覆盖半节、跨节或同节复读，因此结果
/// 以 [MatchedVerse] 列表表达范围，而不是只取跨度首节。
///
/// ## 为什么要做候选二次裁决
///
/// 旧库的排序分 = CTC 按帧平均负对数似然 + 跨度惩罚。按帧归一化消除了
/// 「token 多则分母大」的偏好，但它仍然**只衡量候选能否解释音频，不衡量音频
/// 能否被候选解释**。这会带来一个具体错误：
///
/// - 音频：`بسم الله الرحمن الرحيم قل هو الله احد`（112:1，含章首太斯米）
/// - 候选 A：`1:1` = 太斯米本身（5 个 token，全部有强声学证据）
/// - 候选 B：`112:1` = 太斯米 + 正文（10 个 token）
///
/// A 的按帧分数更优（它只用到高概率的前 5 个位置），于是纯太斯米节会抢走所有
/// 以相同开头起诵的长片段。全经有 112 节带章首太斯米前缀，其中 `1:1` 是太斯米
/// 本身，`67:1`、`112:1` 等则是「太斯米 + 正文」结构，这个冲突在真实音频里
/// 会稳定复现。
///
/// 因此这里在 CTC 精排之后增加一层裁决：先按「转写被候选解释的比例」
/// （precision）分带，同带内再比 CTC 排序分。这同时满足需求中的
/// 「相同开头、太斯米、极短节要允许歧义状态，不能用后文尚未听到的内容强补原文」。
library;

import 'dart:convert';

import '../../quran_offline/quran_matcher.dart';
import '../../quran_offline/quran_text.dart';
import '../../quran_offline/word_alignment.dart';
import '../../quran_offline/word_error_rate.dart';
import '../data/broadcast_corpus.dart';
import '../domain/utterance_record.dart';
import 'broadcast_transcriber.dart';

/// 匹配判定参数。
///
/// **这些阈值是待标定起点，不是已验收常数。** 新库的 CTC token 表由本仓库
/// 用确定性分词生成（上游 unigram 分数未公开），因此不能直接沿用旧库的跨度
/// 惩罚与置信度常数，必须用真实广播音频重新标定后再写进结论。
class BroadcastMatchConfig {
  /// 构造配置。
  ///
  /// @param topK 参与 CTC 精排的候选数
  /// @param maxSpan 最大连读跨度（节）
  /// @param spanPenalty 跨度惩罚
  /// @param minPrecision 转写词被候选解释的比例下限
  /// @param minCoverage 候选原文被覆盖比例下限
  /// @param minConfidence 综合可信度下限
  /// @param minContentWords 至少命中多少个内容词才允许确认
  /// @param precisionBand 裁决时「解释比例」的分带宽度（避免浮点抖动）
  /// @param precisionWeight 可信度中解释比例的权重
  /// @param marginWeight 可信度中候选差距的权重
  /// @param minFallbackCoverage 候选回退所需的最低覆盖率
  /// @param minFallbackTextScore 候选回退所需的最低文本得分
  /// @param minFallbackPrecision 候选回退所需的最低解释比例（防止极短节误回退）
  /// @param runnerUpLimit 参与上层裁决的候选数上限（含多节跨度候选）
  /// @param recallLengthFitWeight 召回打分里「长度匹配度」的权重，用于抑制极短节
  /// @param recallBalance 召回打分里「候选被覆盖比例」的权重
  const BroadcastMatchConfig({
    this.topK = 32,
    // 8 而不是 4：全经里有大量极短节（开端章 2–9 词/节、سورة الكوثر 等），
    // 30 秒片段可跨 5–6 节。取 4 时匹配范围会明显窄于转写内容（实测开端章
    // 转写覆盖 6 节、只匹配到 4 节，解释比例被压到 0.6 以下）。
    this.maxSpan = 8,
    this.spanPenalty = 0.1,
    this.minPrecision = 0.6,
    this.minCoverage = 0.5,
    this.minConfidence = 0.35,
    this.minContentWords = 2,
    this.precisionBand = 0.05,
    this.precisionWeight = 0.7,
    this.marginWeight = 0.3,
    this.minFallbackCoverage = 0.4,
    this.minFallbackTextScore = 0.35,
    this.minFallbackPrecision = 0.3,
    this.runnerUpLimit = 1024,
    this.candidateShortlist = 192,
    this.recallLengthFitWeight = 0,
    this.recallBalance = 0.5,
  });

  /// 参与精排的候选数。
  final int topK;

  /// 最大连读跨度。
  final int maxSpan;

  /// 跨度惩罚。
  final double spanPenalty;

  /// 解释比例下限。
  final double minPrecision;

  /// 覆盖率下限。
  final double minCoverage;

  /// 综合可信度下限。
  final double minConfidence;

  /// 最少内容词数。
  final int minContentWords;

  /// 解释比例分带宽度。
  final double precisionBand;

  /// 可信度中解释比例权重。
  final double precisionWeight;

  /// 可信度中候选差距权重。
  final double marginWeight;

  /// 候选回退的最低覆盖率：解释比例不够、但仍能覆盖大部分候选原文时的兜底门槛。
  final double minFallbackCoverage;

  /// 候选回退的最低文本得分。
  final double minFallbackTextScore;

  /// 候选回退的最低解释比例。
  ///
  /// 真机实测动机：覆盖率对小节有系统性偏向 —— 对 2 个词的节（如 `1:3`
  /// 「الرحمن الرحيم」），长转写里随便命中几个常见词就能得到 0.8+ 覆盖率。
  /// 因此回退必须同时要求候选能解释至少三成转写，否则宁可显示「未匹配」，
  /// 也不要把极短节当成候选经文展示给用户。
  final double minFallbackPrecision;

  /// 参与上层裁决的候选数上限。
  ///
  /// 取 1024（即全部候选）而不是 matcher 默认的 12：预选按 CTC 排序分截断时，
  /// **多节跨度候选会因按帧归一化的分数天然偏低而被整体排除**（实测开端章正确的
  /// 6 节跨度候选排在第 300 名开外），裁决阶段根本看不到它们。既然候选总数只有
  /// topK×maxSpan（64×8=512），不截断即可，代价是裁决阶段多做几百次词级对齐
  /// （实测匹配耗时 200–500 ms，可接受）。
  final int runnerUpLimit;

  /// 召回打分里「候选被覆盖比例」的权重。
  ///
  /// 取 0.5：单看「转写被候选覆盖的比例」时，跨多节的转写会让每个正确单节最多
  /// 只贡献 1/N 的分，正确节与「恰好含常见词的无关节」无法区分；补上「候选被转写
  /// 覆盖的比例」后，只有真正被念到的节才会浮上来。
  final double recallBalance;

  /// 裁决阶段最多做多少次词级对齐。
  ///
  /// 候选总数是 topK×maxSpan（64×8=512），逐一对齐会让匹配耗时升到 1.5 秒以上。
  /// 由于候选已按「词数接近度」排序（见 [QuranMatchService.match]），
  /// 只取前 192 个即可覆盖所有可能解释整段转写的候选。
  final int candidateShortlist;

  /// 召回打分里「长度匹配度」的权重。
  ///
  /// 全经 6236 节里有 553 个 ≤3 词的极短节；按覆盖率召回时它们会垄断候选池
  /// （长转写命中一两个常见词就接近满分覆盖率）。加入长度匹配度后，词数与转写
  /// 接近的经节才会得到高分。设为 0 可退回旧库语义。
  final double recallLengthFitWeight;
}

/// 一次匹配的完整结果。
class BroadcastMatchOutcome {
  /// 构造结果。
  ///
  /// @param asrText 实际 ASR 转写（归一化）
  /// @param status 匹配状态
  /// @param scope 覆盖范围形态
  /// @param matches 命中的经文范围（未确认时为空）
  /// @param metrics 比对指标
  /// @param candidateRef 候选引用（仅用于诊断展示）
  /// @param candidateTextScore 候选文本得分
  /// @param candidateAcousticScore 候选 CTC 平均负对数似然
  /// @param coverage 覆盖率
  /// @param precision 解释比例
  /// @param confidence 综合可信度
  /// @param margin 与其它候选的排序分差
  /// @param rejectionReason 被拒识或未确认的原因
  const BroadcastMatchOutcome({
    required this.asrText,
    required this.status,
    required this.scope,
    required this.matches,
    required this.metrics,
    this.candidateRef,
    this.candidateTextScore,
    this.candidateAcousticScore,
    this.coverage,
    this.precision,
    this.confidence,
    this.margin,
    this.rejectionReason,
  });

  /// 实际 ASR 转写。
  final String asrText;

  /// 匹配状态。
  final MatchStatus status;

  /// 覆盖范围形态。
  final RecordScope scope;

  /// 命中范围。
  final List<MatchedVerse> matches;

  /// 比对指标。
  final RecordMetrics metrics;

  /// 候选引用。
  final String? candidateRef;

  /// 候选文本得分。
  final double? candidateTextScore;

  /// 候选声学分数。
  final double? candidateAcousticScore;

  /// 覆盖率。
  final double? coverage;

  /// 解释比例。
  final double? precision;

  /// 综合可信度。
  final double? confidence;

  /// 与其它候选的排序分差。
  final double? margin;

  /// 未确认或拒识原因。
  final String? rejectionReason;

  /// 诊断证据（仅开发诊断展示）。
  String get evidenceJson => jsonEncode(<String, Object?>{
    'status': status.name,
    'scope': scope.wireName,
    'candidateRef': candidateRef,
    'textScore': candidateTextScore,
    'acousticScore': candidateAcousticScore,
    'precision': precision,
    'coverage': coverage,
    'confidence': confidence,
    'margin': margin,
    'rejectionReason': rejectionReason,
  });

  /// 是否需要给该记录生成译文任务。
  bool get needsTranslation => asrText.trim().isNotEmpty;
}

/// 新库经文匹配服务。
class QuranMatchService {
  /// 构造匹配服务。
  ///
  /// @param library 全经语料库（114 章 6236 节）
  /// @param config 判定参数
  QuranMatchService({required this.library, this.config = const BroadcastMatchConfig()})
    : _matcher = QuranMatcher(
        library,
        lengthFitWeight: config.recallLengthFitWeight,
        recallBalance: config.recallBalance,
      );

  /// 语料库。
  final BroadcastQuranLibrary library;

  /// 判定参数。
  final BroadcastMatchConfig config;

  final QuranMatcher _matcher;

  /// 归一化口径版本（写入指标元数据）。
  static const String normalizationVersion = 'quran-text-normalize-1';

  /// 候选跨度的参考词数（用于「词数接近度」排序）。
  ///
  /// @param candidate 候选
  /// @return 该跨度覆盖的经文词数
  int _referenceWordCount(VerseMatchCandidate candidate) {
    var total = 0;
    for (var ayah = candidate.ayahStart; ayah <= candidate.ayahEnd; ayah++) {
      total += library.wordsOf(candidate.surah, ayah).length;
    }
    return total;
  }

  /// 对一段已转写的片段做匹配。
  ///
  /// @param fragment 片段转写结果（含声学证据）
  /// @return 匹配结果
  BroadcastMatchOutcome match(BroadcastFragment fragment) {
    final asrText = QuranText.normalize(fragment.text);
    if (fragment.isEmpty || asrText.isEmpty) {
      return _reject(asrText, '片段无有效语音内容');
    }
    final asrWords = asrText.split(' ').where((word) => word.isNotEmpty).toList(growable: false);
    if (_isBismillahOnly(asrWords)) {
      // 只听到太斯米不能确认章节：小库会造成虚假确定性，必须等到更多上下文。
      return _reject(asrText, '仅识别到章首太斯米，证据不足');
    }

    // 用**整段**音频的原生证据做一次匹配。
    //
    // 不能按子窗匹配再合并：CTC 可行性要求「候选 token 数 × 2 + 1 ≤ 帧数」，
    // 分段后的子窗（实测 3–10 秒）只够短候选 —— 49 token 的正确跨节候选会被判
    // 不可行直接跳过，只剩 2 token 的碎片能参与裁决（表现为「转写覆盖 6 节、
    // 却只匹配到 2 节」）。整段证据（30 秒）帧数充足，跨节候选才是可评估的。
    final evidence = fragment.matchEvidence;
    if (evidence == null) return _reject(asrText, '缺少可用于匹配的声学证据');
    final result = _matcher.match(
      evidence,
      asrText,
      topK: config.topK,
      maxSpan: config.maxSpan,
      spanPenalty: config.spanPenalty,
      runnerUpLimit: config.runnerUpLimit,
    );
    if (result.champion == null) return _reject(asrText, '全经语料内没有候选');

    // 裁决前的候选筛选：按「参考词数与被转写词数的接近程度」优先。
    //
    // 不能直接按 CTC 排序分取前 N —— 按帧归一化的分数系统性偏好极短候选
    // （实测 champion 是 2 token 的碎片，正确的 49 token 跨度排在第 130 名之后）。
    // 用词数接近度排序后，真正可能解释整段转写的候选会浮到前面，因此可以安全地
    // 只对前 [BroadcastMatchConfig.candidateShortlist] 个做词级对齐，
    // 把裁决成本压回可用范围。
    final champion = result.champion!;
    final raw = <VerseMatchCandidate>[champion, ...result.runnersUp];
    raw.sort((a, b) {
      final distanceA = (_referenceWordCount(a) - asrWords.length).abs();
      final distanceB = (_referenceWordCount(b) - asrWords.length).abs();
      if (distanceA != distanceB) return distanceA.compareTo(distanceB);
      return a.sortScore.compareTo(b.sortScore);
    });
    final shortlist = raw.length > config.candidateShortlist
        ? raw.sublist(0, config.candidateShortlist)
        : raw;
    // champion 始终参与裁决，避免筛选把唯一可用的声学最优解排除掉。
    if (!shortlist.contains(champion)) shortlist.add(champion);
    final candidates = <_Candidate>[
      for (final candidate in shortlist) _evaluate(candidate, asrWords),
    ];
    final viable = <_Candidate>[
      for (final candidate in candidates)
        if (candidate.precision >= config.minPrecision &&
            candidate.alignment.matchCount + candidate.alignment.nearCount >= config.minContentWords)
          candidate,
    ];
    // 候选裁决：优先在「解释比例达标」的候选里选；若一个都没有，但存在
    // 「覆盖率与文本得分都不错」的候选，就退化为**候选展示**而不是直接判未匹配。
    //
    // 真机实测动机：诵读者念 67:4 时，转写里混入库外词使解释比例掉到 0.54（低于 0.6），
    // 但该候选覆盖率已达 0.80 —— 内容确实在库里，旧逻辑却把经文栏清空，
    // 用户看到的是「未匹配」远多于实际未匹配量。候选状态会明确标注未确认，
    // 不违反「低可信时不得随便确认经文」。
    _Candidate best;
    var fallbackCandidate = false;
    if (viable.isEmpty) {
      final fallback = <_Candidate>[
        for (final candidate in candidates)
          if (candidate.coverage >= config.minFallbackCoverage &&
              candidate.precision >= config.minFallbackPrecision &&
              candidate.match.textScore >= config.minFallbackTextScore &&
              candidate.alignment.matchCount + candidate.alignment.nearCount >=
                  config.minContentWords)
            candidate,
      ]..sort((a, b) => b.coverage.compareTo(a.coverage));
      if (fallback.isEmpty) {
        final weakest = candidates.reduce((a, b) => b.sortScore < a.sortScore ? b : a);
        return _reject(
          asrText,
          '没有任何候选能解释这段转写（最高解释比例 '
          '${weakest.precision.toStringAsFixed(2)}、文本得分 '
          '${weakest.match.textScore.toStringAsFixed(2)}、覆盖率 '
          '${weakest.coverage.toStringAsFixed(2)}）',
          metrics: _metricsOf(weakest, asrWords),
          candidateRef: weakest.ref,
          textScore: weakest.match.textScore,
          acousticScore: weakest.match.acousticScore,
          precision: weakest.precision,
          coverage: weakest.coverage,
          confidence: 0,
          margin: null,
        );
      }
      best = fallback.first;
      fallbackCandidate = true;
    } else {
      viable.sort((a, b) {
        final bandA = (a.precision / config.precisionBand).round();
        final bandB = (b.precision / config.precisionBand).round();
        if (bandA != bandB) return bandB.compareTo(bandA);
        return a.sortScore.compareTo(b.sortScore);
      });
      best = viable.first;
    }

    // 候选差距：与「其它引用」中排序分最接近者的距离；只有唯一候选时视为无冲突。
    double? margin;
    for (final candidate in <_Candidate>[...candidates]) {
      if (candidate.ref == best.ref) continue;
      final difference = candidate.sortScore - best.sortScore;
      if (margin == null || difference < margin) margin = difference;
    }
    final scale = best.sortScore.abs() * QuranMatcher.confidenceRelativeMargin;
    final marginScore = margin == null
        ? 1.0
        : (scale <= 1e-9 ? 1.0 : (margin / scale).clamp(0.0, 1.0));
    final confidence = (config.precisionWeight * best.precision + config.marginWeight * marginScore)
        .clamp(0.0, 1.0);

    final metrics = _metricsOf(best, asrWords);
    final covered = _coveredVerses(best, asrWords);
    if (covered.isEmpty) {
      return _reject(
        asrText,
        '对齐后没有可确认的经文范围',
        metrics: metrics,
        candidateRef: best.ref,
        textScore: best.match.textScore,
        acousticScore: best.match.acousticScore,
        precision: best.precision,
        coverage: best.coverage,
        confidence: confidence,
        margin: margin,
      );
    }

    final wholeVerses = covered.where((item) => item.isWholeVerse).length;
    final scope = wholeVerses == covered.length
        ? RecordScope.completeVerses
        : (wholeVerses == 0 ? RecordScope.partialVerse : RecordScope.mixed);

    // 确认条件：解释比例、覆盖率与综合可信度都要过线；否则只作为候选展示。
    // 候选回退路径一律不确认（它是「内容像在库里但证据不足」的兜底展示）。
    final confident =
        !fallbackCandidate &&
        best.coverage >= config.minCoverage &&
        confidence >= config.minConfidence;
    return BroadcastMatchOutcome(
      asrText: asrText,
      status: confident
          ? (scope == RecordScope.completeVerses ? MatchStatus.confirmed : MatchStatus.partial)
          : MatchStatus.candidate,
      scope: scope,
      matches: covered,
      metrics: metrics,
      candidateRef: best.ref,
      candidateTextScore: best.match.textScore,
      candidateAcousticScore: best.match.acousticScore,
      precision: best.precision,
      coverage: best.coverage,
      confidence: confidence,
      margin: margin,
      rejectionReason: confident
          ? null
          : fallbackCandidate
          ? '候选未确认（解释比例 ${best.precision.toStringAsFixed(2)} 低于 '
                '${config.minPrecision.toStringAsFixed(2)}，但覆盖率 '
                '${best.coverage.toStringAsFixed(2)}）'
          : '证据不足以确认（覆盖率 ${best.coverage.toStringAsFixed(2)}、'
                '可信度 ${confidence.toStringAsFixed(2)}）',
    );
  }

  /// 拒识结果：没有任何可信匹配，但保留真实转写与（可用的）诊断信息。
  BroadcastMatchOutcome _reject(
    String asrText,
    String reason, {
    RecordMetrics? metrics,
    String? candidateRef,
    double? textScore,
    double? acousticScore,
    double? precision,
    double? coverage,
    double? confidence,
    double? margin,
  }) => BroadcastMatchOutcome(
    asrText: asrText,
    status: MatchStatus.unmatched,
    scope: RecordScope.unknown,
    matches: const <MatchedVerse>[],
    metrics:
        metrics ??
        RecordMetrics.unavailable(
          metricScope: 'unmatched',
          normalizationVersion: normalizationVersion,
        ),
    candidateRef: candidateRef,
    candidateTextScore: textScore,
    candidateAcousticScore: acousticScore,
    precision: precision,
    coverage: coverage,
    confidence: confidence,
    margin: margin,
    rejectionReason: reason,
  );

  /// 片段是否只包含章首太斯米。
  static bool _isBismillahOnly(List<String> words) {
    if (words.isEmpty) return false;
    for (final word in words) {
      if (!BroadcastQuranLibrary.bismillahWords.contains(word)) return false;
    }
    return true;
  }

  /// 计算某个候选对转写的解释程度。
  _Candidate _evaluate(VerseMatchCandidate candidate, List<String> asrWords) {
    final referenceWords = _referenceWords(candidate.surah, candidate.ayahStart, candidate.ayahEnd);
    final alignment = WordAlignment.align(referenceWords, asrWords);
    final wer = WordErrorRate.compare(referenceWords, asrWords);
    return _Candidate(
      match: candidate,
      referenceWords: referenceWords,
      alignment: alignment,
      wer: wer,
    );
  }

  /// 取候选跨度的参考词序列。
  List<String> _referenceWords(int surah, int ayahStart, int ayahEnd) {
    final words = <String>[];
    for (var ayah = ayahStart; ayah <= ayahEnd; ayah++) {
      words.addAll(library.wordsOf(surah, ayah));
    }
    return words;
  }

  /// 从对齐结果推断每个节的覆盖情况。
  ///
  /// 只有真正出现转写证据的节才保留，因此不会把「后文还没听到」的内容算成
  /// 已识别，也不会只显示跨度首节。
  ///
  /// @param candidate 裁决后的候选
  /// @param asrWords 实际转写词
  /// @return 命中的经文范围
  List<MatchedVerse> _coveredVerses(_Candidate candidate, List<String> asrWords) {
    final surah = candidate.match.surah;
    final spans = <int, (int, int)>{};
    var cursor = 0;
    for (var ayah = candidate.match.ayahStart; ayah <= candidate.match.ayahEnd; ayah++) {
      final length = library.wordsOf(surah, ayah).length;
      spans[ayah] = (cursor, cursor + length);
      cursor += length;
    }

    final covered = List<bool>.filled(cursor, false);
    var referenceIndex = 0;
    for (final row in candidate.alignment.rows) {
      if (row.reference == null) continue;
      if (referenceIndex >= cursor) break;
      // 与转写对上的参考词视为「已听到」；被判定为缺失的保持未覆盖。
      if (row.status != WordStatus.missing) covered[referenceIndex] = true;
      referenceIndex++;
    }

    final result = <MatchedVerse>[];
    var ordinal = 0;
    for (final entry in spans.entries) {
      final (start, end) = entry.value;
      if (end <= start) continue;
      var hits = 0;
      var firstHit = -1;
      var lastHit = -1;
      for (var i = start; i < end; i++) {
        if (!covered[i]) continue;
        hits++;
        if (firstHit < 0) firstHit = i;
        lastHit = i;
      }
      if (hits == 0) continue;
      final whole = hits == end - start;
      result.add(
        MatchedVerse(
          ordinal: ordinal++,
          surah: surah,
          ayah: entry.key,
          // 词范围用**节内**下标表达，便于按节切分原文与译本，不跨节累计。
          wordStart: whole ? null : firstHit - start,
          wordEnd: whole ? null : lastHit - start,
          canonicalTextSnapshot: library.verse(surah, entry.key)?.textUthmani ?? '',
          matchedTextSnapshot: asrWords.join(' '),
          corpusVersion: library.manifest.corpusVersion,
        ),
      );
    }
    return result;
  }

  /// 组装指标快照（含逐词对照与严格 WER）。
  RecordMetrics _metricsOf(_Candidate candidate, List<String> asrWords) {
    final alignment = candidate.alignment;
    final wer = candidate.wer;
    return RecordMetrics(
      metricScope: candidate.ref,
      precision: alignment.precision,
      recall: alignment.coverage,
      f1: alignment.f1,
      strictWer: wer.rate,
      substitutions: wer.substitutions,
      deletions: wer.deletions,
      insertions: wer.insertions,
      referenceWords: alignment.referenceCount,
      hypothesisWords: alignment.hypothesisCount,
      matchCount: alignment.matchCount,
      nearCount: alignment.nearCount,
      mismatchCount: alignment.mismatchCount,
      missingCount: alignment.missingCount,
      extraCount: alignment.extraCount,
      normalizationVersion: normalizationVersion,
      alignmentJson: jsonEncode(<Map<String, Object?>>[
        for (final row in alignment.rows)
          <String, Object?>{
            'status': row.status.name,
            'reference': row.reference,
            'hypothesis': row.hypothesis,
            'score': double.parse(row.score.toStringAsFixed(4)),
          },
      ]),
    );
  }
}

/// 一个候选及其对转写的解释程度。
class _Candidate {
  const _Candidate({
    required this.match,
    required this.referenceWords,
    required this.alignment,
    required this.wer,
  });

  /// CTC 精排候选。
  final VerseMatchCandidate match;

  /// 候选参考词。
  final List<String> referenceWords;

  /// 与转写的对齐结果。
  final AlignmentResult alignment;

  /// 严格词错误率。
  final WordErrorRate wer;

  /// 候选引用。
  String get ref => match.ref;

  /// CTC 排序分。
  double get sortScore => match.sortScore;

  /// 转写被该候选解释的比例。
  double get precision => alignment.precision;

  /// 该候选被转写覆盖的比例。
  double get coverage => alignment.coverage;
}
