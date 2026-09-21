/// 广播语料库：Tanzil 全经（114 章 / 6236 节）及其实例内独立索引。
///
/// 与旧经文库（`assets/quran_offline/quran.json`，Tilawa 分发）完全独立：
/// 原文来自 Tanzil 官方快照，CTC token 表由本仓库用同一词表独立生成。广播功能
/// **不读取旧库的文本、索引或 token 表**，检索不到就是未匹配，没有隐式回退。
///
/// 设计要点：
///
/// 1. **数据驱动**：章名、章数、节数与「章首太斯米前缀」全部来自语料文件，
///    代码里没有任何章节硬编码；
/// 2. **按需构造**：只有真正带章首引导的节才缓存派生结构（全经 112 节），
///    其余节的词序列在加载时一次性算好，避免匹配过程中反复做归一化；
/// 3. **加载即校验**：节数必须与 manifest 一致、span 表条目数不得少于节数，
///    不符即抛 [FormatException]，不用不完整的语料静默降级。
library;

import 'dart:convert';

import 'package:flutter/services.dart' show AssetBundle, rootBundle;

import '../../quran_offline/quran_assets.dart';
import '../../quran_offline/quran_text.dart';

/// 一节的派生结构：区分章首引导（太斯米）与正文主体。
///
/// 章首引导不属于新增经文 —— 它由上游章节行携带，[bodyWords] 才是该节主体。
/// 识别到「只有章首引导」时必须视为未确认，不能确认章节。
class BroadcastVerseStructure {
  /// 构造派生结构。
  ///
  /// @param surah 章号
  /// @param ayah 节号
  /// @param sourceText 上游原始文本（含章首引导，未改写）
  /// @param openingWords 章首引导词（归一化后；无前缀时为空）
  /// @param bodyWords 该节主体词（归一化后）
  const BroadcastVerseStructure({
    required this.surah,
    required this.ayah,
    required this.sourceText,
    required this.openingWords,
    required this.bodyWords,
  });

  /// 章号。
  final int surah;

  /// 节号。
  final int ayah;

  /// 上游原始文本（含章首引导，保持原样）。
  final String sourceText;

  /// 章首引导词（归一化后）。
  final List<String> openingWords;

  /// 该节主体词（归一化后）。
  final List<String> bodyWords;

  /// 该节是否带章首引导前缀。
  bool get hasOpening => openingWords.isNotEmpty;

  /// 归一化后的整节词序列（章首引导 + 主体）。
  List<String> get allWords => <String>[...openingWords, ...bodyWords];

  /// `surah:ayah` 引用键。
  String get ref => '$surah:$ayah';
}

/// 一章的元数据。
class BroadcastChapter {
  /// 构造章元数据。
  ///
  /// @param surah 章号
  /// @param nameArabic 阿拉伯语章名
  /// @param nameTransliterated 拉丁转写章名
  /// @param nameEnglish 英文章名
  /// @param ayahCount 节数
  const BroadcastChapter({
    required this.surah,
    required this.nameArabic,
    required this.nameTransliterated,
    required this.nameEnglish,
    required this.ayahCount,
  });

  /// 章号。
  final int surah;

  /// 阿拉伯语章名。
  final String nameArabic;

  /// 拉丁转写章名。
  final String nameTransliterated;

  /// 英文章名。
  final String nameEnglish;

  /// 节数。
  final int ayahCount;

  /// `第 N 章 名称` 形式的中文标签。
  String get label => '第 $surah 章 $nameTransliterated';
}

/// 语料库元信息（来自 `manifest.json`）。
class BroadcastCorpusManifest {
  /// 构造元信息。
  ///
  /// @param corpusId 语料标识，随每条记录与缓存键落库
  /// @param corpusVersion 语料版本
  /// @param provider 数据提供方
  /// @param licenseUrl 许可说明地址
  /// @param sourceSha256 上游原文快照哈希
  /// @param verseCount 节数
  /// @param surahCount 章数
  /// @param normalizationVersion 规范化口径版本
  const BroadcastCorpusManifest({
    required this.corpusId,
    required this.corpusVersion,
    required this.provider,
    required this.licenseUrl,
    required this.sourceSha256,
    required this.verseCount,
    required this.surahCount,
    required this.normalizationVersion,
  });

  /// 语料标识。
  final String corpusId;

  /// 语料版本。
  final String corpusVersion;

  /// 数据提供方。
  final String provider;

  /// 许可说明地址。
  final String licenseUrl;

  /// 上游原文快照 SHA-256。
  final String sourceSha256;

  /// 节数。
  final int verseCount;

  /// 章数。
  final int surahCount;

  /// 规范化口径版本。
  final String normalizationVersion;

  /// 从 JSON 解析。
  ///
  /// @param raw `manifest.json` 解析后的映射
  /// @return 元信息
  static BroadcastCorpusManifest fromJson(Map<String, dynamic> raw) => BroadcastCorpusManifest(
    corpusId: '${raw['corpusId']}',
    corpusVersion: '${raw['corpusVersion']}',
    provider: '${raw['provider']}',
    licenseUrl: '${raw['licenseUrl']}',
    sourceSha256: '${raw['sourceSha256']}',
    verseCount: int.tryParse('${raw['verseCount']}') ?? 0,
    surahCount: int.tryParse('${raw['surahCount']}') ?? 0,
    normalizationVersion: '${raw['normalizationVersion']}',
  );
}

/// 广播语料库（全经）及其独立索引。
class BroadcastQuranLibrary implements VerseIndex {
  BroadcastQuranLibrary._({
    required this.manifest,
    required this.vocab,
    required this.verses,
    required this.chapters,
    required Map<String, BroadcastVerseStructure> structures,
    required Map<String, List<int>> spanTokens,
    required Map<String, QuranVerse> versesByRef,
    required Map<int, List<QuranVerse>> versesBySurah,
    required Map<String, List<String>> wordsByRef,
  }) : _structures = structures,
       _spanTokens = spanTokens,
       _versesByRef = versesByRef,
       _versesBySurah = versesBySurah,
       _wordsByRef = wordsByRef;

  /// Tanzil 原文中的太斯米词形（归一化后）。
  static const List<String> bismillahWords = <String>['بسم', 'الله', 'الرحمن', 'الرحيم'];

  /// 资产目录。
  static const String assetDir = 'assets/broadcast_quran/full';

  /// 语料元信息。
  final BroadcastCorpusManifest manifest;

  /// ASR 词表（模型侧资源，按需求允许新旧功能共用）。
  @override
  final Map<int, String> vocab;

  /// 全部经文（按章、节升序）。
  @override
  final List<QuranVerse> verses;

  /// 章号 -> 章元数据。
  final Map<int, BroadcastChapter> chapters;

  final Map<String, BroadcastVerseStructure> _structures;
  final Map<String, List<int>> _spanTokens;
  final Map<String, QuranVerse> _versesByRef;
  final Map<int, List<QuranVerse>> _versesBySurah;
  final Map<String, List<String>> _wordsByRef;

  /// blank token id（词表中最大的 token id）。
  int get blankId => vocab.keys.isEmpty ? 0 : vocab.keys.reduce((a, b) => a > b ? a : b);

  /// 从资产加载全经语料库。
  ///
  /// 只读取 `assets/broadcast_quran/`，不接触旧经文库。
  ///
  /// @param bundle 资产来源，默认 [rootBundle]
  /// @return 已加载的语料库
  /// @throws FormatException 清单节数与语料不一致时抛出
  static Future<BroadcastQuranLibrary> load({AssetBundle? bundle}) async {
    final assets = bundle ?? rootBundle;
    final vocabulary = await QuranAssets.loadVocabularyOnly(bundle: assets);
    final manifest = BroadcastCorpusManifest.fromJson(
      jsonDecode(await assets.loadString('$assetDir/manifest.json')) as Map<String, dynamic>,
    );
    final corpus = jsonDecode(await assets.loadString('$assetDir/quran.json')) as Map<String, dynamic>;
    final tokensRaw =
        jsonDecode(await assets.loadString('$assetDir/verse_ctc_tokens.json'))
            as Map<String, dynamic>;

    final chapters = <int, BroadcastChapter>{};
    for (final item in corpus['chapters'] as List<dynamic>) {
      final map = item as Map<String, dynamic>;
      final surah = int.parse('${map['surah']}');
      chapters[surah] = BroadcastChapter(
        surah: surah,
        nameArabic: '${map['nameArabic']}',
        nameTransliterated: '${map['nameTransliterated']}',
        nameEnglish: '${map['nameEnglish']}',
        ayahCount: int.tryParse('${map['ayahCount']}') ?? 0,
      );
    }

    final verses = <QuranVerse>[];
    final structures = <String, BroadcastVerseStructure>{};
    final versesByRef = <String, QuranVerse>{};
    final versesBySurah = <int, List<QuranVerse>>{};
    final wordsByRef = <String, List<String>>{};
    for (final item in corpus['verses'] as List<dynamic>) {
      final map = item as Map<String, dynamic>;
      final surah = int.parse('${map['surah']}');
      final ayah = int.parse('${map['ayah']}');
      final sourceText = '${map['sourceText']}';
      final chapter = chapters[surah] ?? const BroadcastChapter(
        surah: 0,
        nameArabic: '',
        nameTransliterated: '',
        nameEnglish: '',
        ayahCount: 0,
      );
      final normalized = QuranText.normalize(sourceText);
      final verse = QuranVerse(
        surah: surah,
        ayah: ayah,
        textUthmani: sourceText,
        textClean: normalized,
        surahName: chapter.nameArabic,
        surahNameEn: chapter.nameEnglish,
      );
      verses.add(verse);
      versesByRef[verse.ref] = verse;
      versesBySurah.putIfAbsent(surah, () => <QuranVerse>[]).add(verse);
      // 词序列一次算好：匹配与范围切片会反复用到，避免每次归一化。
      wordsByRef[verse.ref] = normalized.split(' ').where((word) => word.isNotEmpty).toList(
        growable: false,
      );
      if (map['hasChapterOpeningPrefix'] == true) {
        structures[verse.ref] = buildStructure(
          surah: surah,
          ayah: ayah,
          sourceText: sourceText,
          words: wordsByRef[verse.ref]!,
        );
      }
    }
    verses.sort(
      (a, b) => a.surah == b.surah ? a.ayah.compareTo(b.ayah) : a.surah.compareTo(b.surah),
    );

    final spanTokens = <String, List<int>>{};
    for (final entry in (tokensRaw['tokens'] as Map<String, dynamic>).entries) {
      spanTokens[entry.key] = <int>[
        for (final id in entry.value as List<dynamic>) id as int,
      ];
    }

    if (verses.length != manifest.verseCount) {
      throw FormatException(
        '广播语料清单与语料 JSON 不一致：${verses.length} 节 vs 声称 ${manifest.verseCount} 节',
      );
    }
    if (spanTokens.length < verses.length) {
      throw FormatException(
        'token 表条目（${spanTokens.length}）少于节数（${verses.length}），语料与 token 表不匹配',
      );
    }
    return BroadcastQuranLibrary._(
      manifest: manifest,
      vocab: vocabulary.vocab,
      verses: List<QuranVerse>.unmodifiable(verses),
      chapters: Map<int, BroadcastChapter>.unmodifiable(chapters),
      structures: Map<String, BroadcastVerseStructure>.unmodifiable(structures),
      spanTokens: Map<String, List<int>>.unmodifiable(spanTokens),
      versesByRef: versesByRef,
      versesBySurah: versesBySurah,
      wordsByRef: Map<String, List<String>>.unmodifiable(wordsByRef),
    );
  }

  /// 把一节文本拆成章首引导与主体。
  ///
  /// 仅当前 [words] 以完整太斯米开头**且后面还有词**时才剥离：1:1 的太斯米属于
  /// 该节本身，不能当成章首引导额外剥掉（否则该节会变成空节）。
  ///
  /// @param surah 章号
  /// @param ayah 节号
  /// @param sourceText 上游原始文本
  /// @param words 归一化后的词序列
  /// @return 派生结构
  static BroadcastVerseStructure buildStructure({
    required int surah,
    required int ayah,
    required String sourceText,
    required List<String> words,
  }) {
    var opening = const <String>[];
    var body = words;
    if (words.length > bismillahWords.length) {
      var matches = true;
      for (var index = 0; index < bismillahWords.length; index++) {
        if (words[index] != bismillahWords[index]) {
          matches = false;
          break;
        }
      }
      if (matches) {
        opening = words.sublist(0, bismillahWords.length);
        body = words.sublist(bismillahWords.length);
      }
    }
    return BroadcastVerseStructure(
      surah: surah,
      ayah: ayah,
      sourceText: sourceText,
      openingWords: List<String>.unmodifiable(opening),
      bodyWords: List<String>.unmodifiable(body),
    );
  }

  /// 取指定跨度的 CTC token 序列。
  @override
  List<int>? tokensFor(int surah, int ayahStart, int ayahEnd) =>
      _spanTokens['$surah:$ayahStart:$ayahEnd'];

  /// 取一节经文。
  @override
  QuranVerse? verse(int surah, int ayah) => _versesByRef['$surah:$ayah'];

  /// 取整章经文。
  @override
  List<QuranVerse>? versesOfSurah(int surah) => _versesBySurah[surah];

  /// 取一节派生结构；无章首引导时也返回结构（引导为空）。
  ///
  /// 只有带引导的节在加载时缓存，其余按需从词序列组装，避免为 6236 节常驻
  /// 三份列表。
  ///
  /// @param surah 章号
  /// @param ayah 节号
  /// @return 派生结构；该节不存在时返回 null
  BroadcastVerseStructure? structure(int surah, int ayah) {
    final ref = '$surah:$ayah';
    final cached = _structures[ref];
    if (cached != null) return cached;
    final verse = _versesByRef[ref];
    if (verse == null) return null;
    return buildStructure(
      surah: surah,
      ayah: ayah,
      sourceText: verse.textUthmani,
      words: _wordsByRef[ref] ?? const <String>[],
    );
  }

  /// 取章元数据。
  ///
  /// @param surah 章号
  /// @return 章元数据；不存在时返回 null
  BroadcastChapter? chapter(int surah) => chapters[surah];

  /// 取某节归一化后的完整词序列（章首引导 + 主体）。
  ///
  /// @param surah 章号
  /// @param ayah 节号
  /// @return 词序列；该节不存在时返回空列表
  List<String> wordsOf(int surah, int ayah) => _wordsByRef['$surah:$ayah'] ?? const <String>[];

  /// 该节是否带章首太斯米引导（用于界面标注）。
  ///
  /// @param surah 章号
  /// @param ayah 节号
  /// @return 是否带引导
  bool hasChapterOpening(int surah, int ayah) => _structures.containsKey('$surah:$ayah');
}
