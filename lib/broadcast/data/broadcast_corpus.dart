/// 广播功能专用经文语料库：Tanzil 1.1 奥斯曼体第 1、67、112 章，共 41 节。
///
/// 与旧经文库（`assets/quran_offline/quran.json`，6236 节）完全独立：
///
/// - 文本来自 `assets/broadcast_quran/tanzil_1_1/`，上游为 Tanzil 官方下载；
/// - CTC token 表由 `tools/broadcast_quran/generate_verse_tokens.py` 从同一
///   词表与本节语料独立生成，不含旧库的文本或索引；
/// - 本库只包含 41 节，匹配不到时**不会**回退旧库，直接返回未匹配。
///
/// 上游 Tanzil 的 67:1、112:1 把章首太斯米写在首节文本之前。原始文本按
/// [BroadcastVerseStructure.sourceText] 原样保留，另建派生结构把章首引导与
/// 首节主体分开，节数仍为 41，不把引导多算一节。
library;

import 'dart:convert';

import 'package:flutter/services.dart' show AssetBundle, rootBundle;

import '../../quran_offline/quran_assets.dart';
import '../../quran_offline/quran_text.dart';

/// 一节经文的派生结构：区分章首引导与首节主体。
///
/// 章首引导（太斯米）由上游源文件的章节行携带，不属于新增经文；[bodyWords]
/// 才是该节的实际主体。识别到「只有章首引导」时必须视为未确认，不能确认章节。
class BroadcastVerseStructure {
  /// 构造派生结构。
  ///
  /// @param surah 章号
  /// @param ayah 节号
  /// @param sourceText 上游原始文本（含章首引导，未改写）
  /// @param openingWords 章首引导词（无前缀时为空）
  /// @param bodyWords 首节主体词
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

  /// 章首引导词（归一化后；无前缀时为空）。
  final List<String> openingWords;

  /// 首节主体词（归一化后）。
  final List<String> bodyWords;

  /// 该节是否带章首引导前缀。
  bool get hasOpening => openingWords.isNotEmpty;

  /// 归一化后的整节词序列（章首引导 + 主体）。
  List<String> get allWords => <String>[...openingWords, ...bodyWords];

  /// `surah:ayah` 引用键。
  String get ref => '$surah:$ayah';
}

/// 广播语料库的元信息（来自 `manifest.json`）。
class BroadcastCorpusManifest {
  /// 构造元信息。
  ///
  /// @param corpusId 语料标识，随每条记录与缓存键落库
  /// @param corpusVersion 语料版本
  /// @param provider 数据提供方
  /// @param licenseUrl 许可说明地址
  /// @param sourceSha256 上游原文快照哈希
  /// @param verseCount 声称的节数
  /// @param normalizationVersion 规范化口径版本
  /// @param surahs 覆盖的章号
  const BroadcastCorpusManifest({
    required this.corpusId,
    required this.corpusVersion,
    required this.provider,
    required this.licenseUrl,
    required this.sourceSha256,
    required this.verseCount,
    required this.normalizationVersion,
    required this.surahs,
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

  /// 声称的节数（应为 41）。
  final int verseCount;

  /// 规范化口径版本。
  final String normalizationVersion;

  /// 覆盖章号（应为 [1, 67, 112]）。
  final List<int> surahs;

  /// 从 JSON 解析。
  ///
  /// @param raw `manifest.json` 解析后的映射
  /// @return 元信息
  static BroadcastCorpusManifest fromJson(Map<String, dynamic> raw) {
    return BroadcastCorpusManifest(
      corpusId: '${raw['corpusId']}',
      corpusVersion: '${raw['corpusVersion']}',
      provider: '${raw['provider']}',
      licenseUrl: '${raw['licenseUrl']}',
      sourceSha256: '${raw['sourceSha256']}',
      verseCount: int.tryParse('${raw['verseCount']}') ?? 0,
      normalizationVersion: '${raw['normalizationVersion']}',
      surahs: <int>[
        for (final item in (raw['surahs'] as List<dynamic>? ?? const <dynamic>[]))
          int.tryParse('$item') ?? 0,
      ],
    );
  }
}

/// 广播三章语料库（41 节）及其独立索引。
class BroadcastQuranLibrary implements VerseIndex {
  BroadcastQuranLibrary._({
    required this.manifest,
    required this.vocab,
    required this.verses,
    required this.structures,
    required this.spanTokens,
    required Map<String, QuranVerse> versesByRef,
    required Map<int, List<QuranVerse>> versesBySurah,
  }) : _versesByRef = versesByRef,
       _versesBySurah = versesBySurah;

  /// Tanzil 原文中的太斯米词形（归一化后）。
  static const List<String> bismillahWords = <String>['بسم', 'الله', 'الرحمن', 'الرحيم'];

  /// 资产目录。
  static const String assetDir = 'assets/broadcast_quran/tanzil_1_1';

  /// 三章的章名（新库自带元数据，不取自旧库）。
  static const Map<int, (String, String)> surahNames = <int, (String, String)>{
    1: ('سورة الفاتحة', 'Al-Fatihah'),
    67: ('سورة الملك', 'Al-Mulk'),
    112: ('سورة الإخلاص', 'Al-Ikhlas'),
  };

  /// 语料元信息。
  final BroadcastCorpusManifest manifest;

  /// ASR 词表（token id -> token 文本）。
  ///
  /// 这是模型侧资源，按需求允许新旧功能共用；本库不因此读取旧经文的任何
  /// 文本或索引。
  @override
  final Map<int, String> vocab;

  /// blank token id（词表中最大的 token id）。
  int get blankId => vocab.keys.isEmpty ? 0 : vocab.keys.reduce((a, b) => a > b ? a : b);

  /// 41 节经文（按章、节升序）。
  @override
  final List<QuranVerse> verses;

  /// `surah:ayah` -> 派生结构。
  final Map<String, BroadcastVerseStructure> structures;

  /// `surah:ayahStart:ayahEnd` -> CTC token 序列。
  final Map<String, List<int>> spanTokens;

  final Map<String, QuranVerse> _versesByRef;
  final Map<int, List<QuranVerse>> _versesBySurah;

  /// 从资产加载三章语料库。
  ///
  /// 只读取 `assets/broadcast_quran/`，不接触 `assets/quran_offline/quran.json`。
  ///
  /// @param bundle 资产来源，默认 [rootBundle]
  /// @return 已加载的语料库
  /// @throws FormatException 清单节数与 `verseCount` 不一致时抛出
  static Future<BroadcastQuranLibrary> load({AssetBundle? bundle}) async {
    final assets = bundle ?? rootBundle;
    // 只取词表，不加载旧经文库（quran.json / quran_ctc_tokens.json）。
    final vocabulary = await QuranAssets.loadVocabularyOnly(bundle: assets);
    final manifest = BroadcastCorpusManifest.fromJson(
      jsonDecode(await assets.loadString('$assetDir/manifest.json')) as Map<String, dynamic>,
    );
    final versesRaw =
        jsonDecode(await assets.loadString('$assetDir/verses_001_067_112.json'))
            as Map<String, dynamic>;
    final tokensRaw =
        jsonDecode(await assets.loadString('$assetDir/verse_ctc_tokens.json'))
            as Map<String, dynamic>;

    final verses = <QuranVerse>[];
    final structures = <String, BroadcastVerseStructure>{};
    final versesByRef = <String, QuranVerse>{};
    final versesBySurah = <int, List<QuranVerse>>{};
    for (final item in versesRaw['verses'] as List<dynamic>) {
      final map = item as Map<String, dynamic>;
      final surah = int.parse('${map['surah']}');
      final ayah = int.parse('${map['ayah']}');
      final sourceText = '${map['sourceText']}';
      final structure = buildStructure(
        surah: surah,
        ayah: ayah,
        sourceText: sourceText,
        hasChapterOpeningPrefix: map['hasChapterOpeningPrefix'] == true,
      );
      final names = surahNames[surah] ?? ('', '');
      final verse = QuranVerse(
        surah: surah,
        ayah: ayah,
        textUthmani: sourceText,
        textClean: QuranText.normalize(sourceText),
        surahName: names.$1,
        surahNameEn: names.$2,
      );
      verses.add(verse);
      structures[structure.ref] = structure;
      versesByRef[verse.ref] = verse;
      versesBySurah.putIfAbsent(surah, () => <QuranVerse>[]).add(verse);
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
        '广播语料清单与派生 JSON 不一致：${verses.length} 节 vs 声称 ${manifest.verseCount} 节',
      );
    }
    return BroadcastQuranLibrary._(
      manifest: manifest,
      vocab: vocabulary.vocab,
      verses: List<QuranVerse>.unmodifiable(verses),
      structures: Map<String, BroadcastVerseStructure>.unmodifiable(structures),
      spanTokens: Map<String, List<int>>.unmodifiable(spanTokens),
      versesByRef: versesByRef,
      versesBySurah: versesBySurah,
    );
  }

  /// 把一节上游文本拆成章首引导与首节主体。
  ///
  /// 仅当上游标记了章首前缀、且前四个词确实是太斯米时才剥离，避免误伤
  /// 正文本身以「بسم」开头的节（如 1:1 的太斯米属于该节）。
  ///
  /// @param surah 章号
  /// @param ayah 节号
  /// @param sourceText 上游原始文本
  /// @param hasChapterOpeningPrefix 上游是否标记章首前缀
  /// @return 派生结构
  static BroadcastVerseStructure buildStructure({
    required int surah,
    required int ayah,
    required String sourceText,
    required bool hasChapterOpeningPrefix,
  }) {
    final parts = sourceText.split(RegExp(r'\s+')).where((word) => word.isNotEmpty).toList();
    var opening = const <String>[];
    var body = <String>[for (final word in parts) QuranText.normalize(word)];
    if (hasChapterOpeningPrefix && parts.length > bismillahWords.length) {
      final head = <String>[
        for (final word in parts.take(bismillahWords.length)) QuranText.normalize(word),
      ];
      if (_listEquals(head, bismillahWords)) {
        opening = head;
        body = <String>[
          for (final word in parts.skip(bismillahWords.length)) QuranText.normalize(word),
        ];
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
      spanTokens['$surah:$ayahStart:$ayahEnd'];

  /// 取一节经文。
  @override
  QuranVerse? verse(int surah, int ayah) => _versesByRef['$surah:$ayah'];

  /// 取整章经文。
  @override
  List<QuranVerse>? versesOfSurah(int surah) => _versesBySurah[surah];

  /// 取一章的派生结构（按节升序）。
  ///
  /// @param surah 章号
  /// @return 该章派生结构；无该章时返回空列表
  List<BroadcastVerseStructure> structuresOfSurah(int surah) => <BroadcastVerseStructure>[
    for (final verse in _versesBySurah[surah] ?? const <QuranVerse>[])
      structures[verse.ref]!,
  ];

  /// 取一节派生结构。
  ///
  /// @param surah 章号
  /// @param ayah 节号
  /// @return 派生结构；不存在时返回 null
  BroadcastVerseStructure? structure(int surah, int ayah) => structures['$surah:$ayah'];

  /// 供匹配范围使用的整库词序列（章首引导 + 主体，按节顺序）。
  List<String> wordsOf(int surah, int ayah) => structures['$surah:$ayah']?.allWords ?? const [];

  static bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
