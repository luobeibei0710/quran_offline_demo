/// 经文库（quran.json）、词表（vocab.json）与 CTC token 表（quran_ctc_tokens.json）的加载。
///
/// 资产来自 Tilawa v0.2.0（MIT / 模型 CC-BY-4.0），放置于 `assets/quran_offline/`。
/// 其中 `quran_ctc_tokens.json` 的键为 `surah:ayahStart:ayahEnd`，值为该跨度经文的
/// 完整 token 序列（已预拼接，含 1 节与 2–6 节连读的候选）。
library;

import 'dart:convert';

import 'package:flutter/services.dart' show AssetBundle, rootBundle;

import 'quran_text.dart';

/// 一节经文及其元信息。
class QuranVerse {
  /// 构造经文实体。
  ///
  /// @param surah 章号（1..114）
  /// @param ayah 节号
  /// @param textUthmani 奥斯曼体原文（含音标）
  /// @param textClean 已归一化的文本（用于匹配，可能带 BOM）
  /// @param surahName 章名（阿拉伯语）
  /// @param surahNameEn 章名（英文）
  const QuranVerse({
    required this.surah,
    required this.ayah,
    required this.textUthmani,
    required this.textClean,
    required this.surahName,
    required this.surahNameEn,
  });

  /// 章号。
  final int surah;

  /// 节号。
  final int ayah;

  /// 奥斯曼体原文。
  final String textUthmani;

  /// 归一化文本（匹配用）。
  final String textClean;

  /// 章名（阿拉伯语）。
  final String surahName;

  /// 章名（英文）。
  final String surahNameEn;

  /// `surah:ayah` 形式的引用键。
  String get ref => '$surah:$ayah';

  /// 纯阿拉伯语归一化文本（去掉 BOM 等残留字符）。
  String get normalizedText => QuranText.normalize(textClean.isEmpty ? textUthmani : textClean);

  /// 该节经文包含的词。
  List<String> get words => normalizedText.split(' ').where((w) => w.isNotEmpty).toList();

  @override
  String toString() => 'QuranVerse($ref, $surahNameEn)';
}

/// 经文索引的最小契约：匹配与词进度算法只依赖本接口。
///
/// 旧功能由 [QuranAssets]（Tilawa 分发的 6236 节经文库）实现，
/// 广播功能由独立的全经语料库实现。两者**共用算法、分别注入数据与索引**，
/// 因此广播功能不会隐式读取旧经文库，也不会在未匹配时回退旧库。
abstract interface class VerseIndex {
  /// CTC 词表（token id -> token 文本），用于按词分组索引。
  ///
  /// 这是 ASR 模型侧资源，可被新旧功能共同复用；经文文本与索引不得复用。
  Map<int, String> get vocab;

  /// 全部经文，按章、节升序。
  List<QuranVerse> get verses;

  /// 取指定跨度的 CTC token 序列（`surah:ayahStart:ayahEnd`）。
  ///
  /// @param surah 章号
  /// @param ayahStart 起始节
  /// @param ayahEnd 结束节（含）
  /// @return token 序列；该跨度不存在时返回 null
  List<int>? tokensFor(int surah, int ayahStart, int ayahEnd);

  /// 取一节经文。
  ///
  /// @param surah 章号
  /// @param ayah 节号
  /// @return 经文；不存在时返回 null
  QuranVerse? verse(int surah, int ayah);

  /// 取整章经文。
  ///
  /// @param surah 章号
  /// @return 该章经文；不存在时返回 null
  List<QuranVerse>? versesOfSurah(int surah);
}

/// 古兰经离线识别所需的全部数据资产。
class QuranAssets implements VerseIndex {
  QuranAssets._({
    required this.vocab,
    required this.verses,
    required this.spanTokens,
    required this.blankId,
    required this.versesByRef,
    required this.versesBySurah,
  });

  /// 只加载词表与 blank id，不读取旧经文库。
  ///
  /// 广播功能复用 ASR 模型侧的词表与分词资源，但不得加载 `quran.json` 或
  /// `quran_ctc_tokens.json`。用本方法得到的实例只满足解码需要，[verses]
  /// 与 [spanTokens] 为空，**不能**用于旧功能。
  ///
  /// @param bundle 资产来源，默认 [rootBundle]
  /// @return 只含词表的资产对象
  /// @throws FormatException `vocab.json` 缺少可用 token 时抛出
  static Future<QuranAssets> loadVocabularyOnly({AssetBundle? bundle}) async {
    final assets = bundle ?? rootBundle;
    final vocab = await _loadVocab(assets);
    final blankId = _blankIdOf(vocab);
    return QuranAssets._(
      vocab: vocab,
      verses: const <QuranVerse>[],
      spanTokens: const <String, List<int>>{},
      blankId: blankId,
      versesByRef: const <String, QuranVerse>{},
      versesBySurah: const <int, List<QuranVerse>>{},
    );
  }

  /// token id -> token 文本。
  @override
  final Map<int, String> vocab;

  /// 全部 6236 节经文（按 surah/ayah 升序）。
  @override
  final List<QuranVerse> verses;

  /// `surah:ayahStart:ayahEnd` -> token 序列。
  final Map<String, List<int>> spanTokens;

  /// blank token id（词表最大 id）。
  final int blankId;

  /// 引用键 -> 经文。
  final Map<String, QuranVerse> versesByRef;

  /// 章号 -> 该章经文。
  final Map<int, List<QuranVerse>> versesBySurah;

  /// 资产目录前缀。
  static const String assetDir = 'assets/quran_offline';

  /// 从 Flutter 资产中加载全部数据。
  ///
  /// 注意：`quran_ctc_tokens.json` 约 12 MB，首次加载会占用一定时间与内存，
  /// Demo 阶段在主 isolate 解析；生产环境建议改为紧凑二进制格式或后台 isolate 解析。
  ///
  /// @param bundle 资产来源，默认 [rootBundle]
  /// @return 加载完成的资产对象
  static Future<QuranAssets> load({AssetBundle? bundle}) async {
    final assets = bundle ?? rootBundle;

    final vocab = await _loadVocab(assets);
    final blankId = _blankIdOf(vocab);

    final quranRaw = jsonDecode(await assets.loadString('$assetDir/quran.json')) as List<dynamic>;
    final verses = <QuranVerse>[];
    final versesByRef = <String, QuranVerse>{};
    final versesBySurah = <int, List<QuranVerse>>{};
    for (final item in quranRaw) {
      final map = item as Map<String, dynamic>;
      final verse = QuranVerse(
        surah: int.parse('${map['surah']}'),
        ayah: int.parse('${map['ayah']}'),
        textUthmani: '${map['text_uthmani'] ?? ''}',
        textClean: '${map['text_clean'] ?? ''}',
        surahName: '${map['surah_name'] ?? ''}',
        surahNameEn: '${map['surah_name_en'] ?? ''}',
      );
      verses.add(verse);
      versesByRef[verse.ref] = verse;
      versesBySurah.putIfAbsent(verse.surah, () => <QuranVerse>[]).add(verse);
    }
    verses.sort((a, b) => a.surah == b.surah ? a.ayah.compareTo(b.ayah) : a.surah.compareTo(b.surah));

    final spanRaw = jsonDecode(await assets.loadString('$assetDir/quran_ctc_tokens.json')) as Map<String, dynamic>;
    final spanTokens = <String, List<int>>{};
    for (final entry in spanRaw.entries) {
      final list = entry.value as List<dynamic>;
      spanTokens[entry.key] = list.map((item) => item as int).toList(growable: false);
    }

    return QuranAssets._(
      vocab: vocab,
      verses: verses,
      spanTokens: spanTokens,
      blankId: blankId,
      versesByRef: versesByRef,
      versesBySurah: versesBySurah,
    );
  }

  /// 取指定跨度的 token 序列。
  ///
  /// @param surah 章号
  /// @param ayahStart 起始节
  /// @param ayahEnd 结束节（含）
  /// @return token 序列；不存在时返回 null
  @override
  List<int>? tokensFor(int surah, int ayahStart, int ayahEnd) =>
      spanTokens['$surah:$ayahStart:$ayahEnd'];

  /// 取一节经文。
  @override
  QuranVerse? verse(int surah, int ayah) => versesByRef['$surah:$ayah'];

  /// 取整章经文。
  ///
  /// @param surah 章号
  /// @return 该章经文；不存在时返回 null
  @override
  List<QuranVerse>? versesOfSurah(int surah) => versesBySurah[surah];

  /// 解析 `vocab.json`。
  ///
  /// @param assets 资产来源
  /// @return token id -> token 文本
  static Future<Map<int, String>> _loadVocab(AssetBundle assets) async {
    final raw = jsonDecode(await assets.loadString('$assetDir/vocab.json')) as Map<String, dynamic>;
    final vocab = <int, String>{};
    for (final entry in raw.entries) {
      vocab[int.parse(entry.key)] = entry.value as String;
    }
    return vocab;
  }

  /// blank id 口径：词表中最大的 token id。
  ///
  /// @param vocab 词表
  /// @return blank token id；词表为空时返回 0
  static int _blankIdOf(Map<int, String> vocab) =>
      vocab.keys.isEmpty ? 0 : vocab.keys.reduce((a, b) => a > b ? a : b);
}
