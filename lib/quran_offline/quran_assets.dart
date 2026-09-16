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

/// 古兰经离线识别所需的全部数据资产。
class QuranAssets {
  QuranAssets._({
    required this.vocab,
    required this.verses,
    required this.spanTokens,
    required this.blankId,
    required this.versesByRef,
    required this.versesBySurah,
  });

  /// token id -> token 文本。
  final Map<int, String> vocab;

  /// 全部 6236 节经文（按 surah/ayah 升序）。
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

    final vocabRaw = jsonDecode(await assets.loadString('$assetDir/vocab.json')) as Map<String, dynamic>;
    final vocab = <int, String>{};
    for (final entry in vocabRaw.entries) {
      vocab[int.parse(entry.key)] = entry.value as String;
    }
    final blankId = vocab.keys.isEmpty ? 0 : vocab.keys.reduce((a, b) => a > b ? a : b);

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
  List<int>? tokensFor(int surah, int ayahStart, int ayahEnd) =>
      spanTokens['$surah:$ayahStart:$ayahEnd'];

  /// 取一节经文。
  QuranVerse? verse(int surah, int ayah) => versesByRef['$surah:$ayah'];
}
