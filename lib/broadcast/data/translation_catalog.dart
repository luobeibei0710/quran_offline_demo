/// 译本目录与按需加载的译本仓储。
///
/// 数据来自 `assets/broadcast_quran/full/translations/`：`index.json` 记录语言清单
/// 与许可元数据，每个语言一个译本文件（全经 6236 节）。
///
/// 设计要点：
///
/// - **只缓存当前语言**：62 种语言合计约 89 MB，全部常驻内存不可接受。切换语言时
///   丢弃上一个语言的缓存；
/// - **许可义务随数据走**：每个译本都带出版方、版本号、来源与许可全文，
///   界面必须展示署名（QuranEnc 的 7 条条件之一是「署名出版方与 QuranEnc.com」）；
/// - **未匹配片段不受影响**：这里只解决「匹配到经文 → 查权威译本」，未匹配的
///   解说内容仍由机器翻译处理。
library;

import 'dart:convert';

import 'package:flutter/services.dart' show AssetBundle, rootBundle;

import '../domain/utterance_record.dart';
import '../translation/verse_translation_repository.dart';

/// 一个译本的元数据（含许可信息，用于界面署名）。
class BroadcastTranslationEdition {
  /// 构造译本元数据。
  ///
  /// @param languageId 语言标识（与 [TargetLanguage.id] 一致）
  /// @param displayName 语言展示名
  /// @param editionId 译本标识
  /// @param publisher 出版方
  /// @param version 版本号
  /// @param source 数据来源页面
  /// @param license 许可全文
  /// @param licenseUrl 许可链接
  /// @param fileName 译本数据文件名
  const BroadcastTranslationEdition({
    required this.languageId,
    required this.displayName,
    required this.editionId,
    required this.publisher,
    required this.version,
    required this.source,
    required this.license,
    required this.licenseUrl,
    required this.fileName,
  });

  /// 语言标识。
  final String languageId;

  /// 语言展示名。
  final String displayName;

  /// 译本标识。
  final String editionId;

  /// 出版方。
  final String publisher;

  /// 版本号。
  final String version;

  /// 数据来源页面。
  final String source;

  /// 许可全文。
  final String license;

  /// 许可链接。
  final String? licenseUrl;

  /// 译本数据文件名。
  final String fileName;

  /// 界面署名文案（许可要求：署名出版方与版本）。
  String get attribution => '$publisher · $version';

  /// 从目录 JSON 解析。
  ///
  /// @param raw 目录条目
  /// @return 译本元数据
  static BroadcastTranslationEdition fromJson(Map<String, dynamic> raw) =>
      BroadcastTranslationEdition(
        languageId: '${raw['language']}',
        displayName: '${raw['displayName']}',
        editionId: '${raw['editionId']}',
        publisher: '${raw['publisher']}',
        version: '${raw['version']}',
        source: '${raw['source']}',
        license: '${raw['license']}',
        licenseUrl: raw['licenseUrl'] as String?,
        fileName: '${raw['file']}',
      );
}

/// 译本目录。
class BroadcastTranslationCatalog {
  /// 构造目录。
  ///
  /// @param corpusId 关联网语料标识
  /// @param verseCount 每本译本覆盖的节数
  /// @param obligations 许可义务说明
  /// @param editions 语言标识 -> 译本元数据
  const BroadcastTranslationCatalog({
    required this.corpusId,
    required this.verseCount,
    required this.obligations,
    required this.editions,
  });

  /// 资产目录。
  static const String assetDir = 'assets/broadcast_quran/full/translations';

  /// 关联网语料标识。
  final String corpusId;

  /// 每本译本覆盖的节数。
  final int verseCount;

  /// 许可义务说明（界面「关于」展示）。
  final String obligations;

  /// 语言标识 -> 译本元数据。
  final Map<String, BroadcastTranslationEdition> editions;

  /// 可选语言（按展示名排序，中文与英语在最前）。
  List<TargetLanguage> get languages {
    final others = editions.values
        .where((edition) => edition.languageId != TargetLanguage.chinese.id &&
            edition.languageId != TargetLanguage.english.id)
        .map((edition) => TargetLanguage(id: edition.languageId, displayName: edition.displayName))
        .toList()
      ..sort((a, b) => a.displayName.compareTo(b.displayName));
    return <TargetLanguage>[
      if (editions.containsKey(TargetLanguage.chinese.id)) TargetLanguage.chinese,
      if (editions.containsKey(TargetLanguage.english.id)) TargetLanguage.english,
      ...others,
    ];
  }

  /// 从资产加载目录并注册语言。
  ///
  /// @param bundle 资产来源，默认 [rootBundle]
  /// @return 目录
  static Future<BroadcastTranslationCatalog> load({AssetBundle? bundle}) async {
    final assets = bundle ?? rootBundle;
    final raw =
        jsonDecode(await assets.loadString('$assetDir/index.json')) as Map<String, dynamic>;
    final editions = <String, BroadcastTranslationEdition>{};
    for (final item in raw['editions'] as List<dynamic>) {
      final edition = BroadcastTranslationEdition.fromJson(item as Map<String, dynamic>);
      editions[edition.languageId] = edition;
    }
    final catalog = BroadcastTranslationCatalog(
      corpusId: '${raw['corpusId']}',
      verseCount: int.tryParse('${raw['verseCount']}') ?? 0,
      obligations: '${raw['obligations']}',
      editions: Map<String, BroadcastTranslationEdition>.unmodifiable(editions),
    );
    TargetLanguage.register(catalog.languages);
    return catalog;
  }
}

/// 基于 JSON 数据的校订译本仓储。
///
/// 命中即返回整节权威译本；未匹配语言或缺失节返回 null，由上层回退到机器翻译。
class JsonVerseTranslationRepository implements VerseTranslationRepository {
  /// 构造仓储。
  ///
  /// @param catalog 译本目录
  /// @param bundle 资产来源，默认 [rootBundle]
  JsonVerseTranslationRepository({required this.catalog, AssetBundle? bundle})
    : _assets = bundle ?? rootBundle;

  /// 译本目录。
  final BroadcastTranslationCatalog catalog;

  final AssetBundle _assets;

  /// 当前已加载语言（只保留一份，避免 89 MB 译本常驻内存）。
  String? _loadedLanguage;

  /// 当前语言的节 -> 译文。
  Map<String, String>? _loadedVerses;

  @override
  String? editionIdFor(TargetLanguage language) =>
      catalog.editions[language.id]?.editionId;

  @override
  Future<VerseTranslation?> find({
    required String verseKey,
    required TargetLanguage language,
  }) async {
    final edition = catalog.editions[language.id];
    if (edition == null) return null;
    final verses = await _versesFor(language.id, edition.fileName);
    final text = verses[verseKey];
    if (text == null || text.isEmpty) return null;
    return VerseTranslation(
      editionId: edition.editionId,
      translator: edition.publisher,
      version: edition.version,
      language: language,
      verseKey: verseKey,
      text: text,
    );
  }

  @override
  Set<String>? availableVerseKeys(TargetLanguage language) {
    if (!catalog.editions.containsKey(language.id)) return null;
    // 未加载时返回 null（表示「范围未知」，不声称覆盖）：目录已声明每本译本
    // 覆盖全部语料节，缺节会在 find 时返回 null，由上层回退机器翻译。
    if (_loadedLanguage == language.id && _loadedVerses != null) {
      return _loadedVerses!.keys.toSet();
    }
    return null;
  }

  Future<Map<String, String>> _versesFor(String languageId, String fileName) async {
    if (_loadedLanguage == languageId && _loadedVerses != null) return _loadedVerses!;
    final raw =
        jsonDecode(await _assets.loadString('${BroadcastTranslationCatalog.assetDir}/$fileName'))
            as Map<String, dynamic>;
    final verses = <String, String>{
      for (final entry in (raw['verses'] as Map<String, dynamic>).entries)
        entry.key: '${entry.value}',
    };
    // 切换语言：丢弃上一个语言的缓存。
    _loadedLanguage = languageId;
    _loadedVerses = verses;
    return verses;
  }
}
