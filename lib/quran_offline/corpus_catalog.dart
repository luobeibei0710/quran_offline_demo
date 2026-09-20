/// 语料清单：可供「语料验证」选中的音频 + 它的原文（参考答案）。
///
/// 两类来源，走同一套「区间 → 原文」规则：
/// 1. **内置语料**：`assets/quran_offline/corpus/` 下的多节连续诵读，清单由
///    `manifest.json` 描述（由 `tools/quran_offline/download_corpus.sh` 生成，
///    音频与模型一样不入版本库）；
/// 2. **设备语料**：`adb push` 到应用私有目录 `files/corpus/` 的 WAV，
///    可有同名 `.txt` 指定原文；没有 txt 时按文件名 `corpus_SSS_AAA_BBB.wav`
///    解析出章节区间，原文取经文库标准经文。
///
/// 为什么用「章节区间」而不是单节：语料本身是多节连续诵读，参考原文应当是这几节
/// 标准经文的拼接，命中判定也应该按「区间里的节是否都识别到」来算。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show AssetBundle, rootBundle;

import 'reference_text.dart';

/// 语料音频来源。
class CorpusAudioSource {
  /// 内置资产。
  ///
  /// @param assetKey 资产路径
  const CorpusAudioSource.asset(this.assetKey) : filePaths = const <String>[];

  /// 设备文件（按顺序尝试，命中即用）。
  ///
  /// @param filePaths 候选路径
  const CorpusAudioSource.deviceFile(this.filePaths) : assetKey = null;

  /// 资产路径（设备文件来源时为 null）。
  final String? assetKey;

  /// 设备候选路径（资产来源时为空）。
  final List<String> filePaths;

  /// 是否来自内置资产。
  bool get isAsset => assetKey != null;
}

/// 语料原文来源。
class CorpusReference {
  /// 章节区间（原文取经文库标准经文；单节即 start == end）。
  ///
  /// @param surah 章号
  /// @param ayahStart 起始节
  /// @param ayahEnd 结束节（含）
  const CorpusReference.range({
    required this.surah,
    required this.ayahStart,
    required this.ayahEnd,
  }) : textPaths = const <String>[];

  /// 设备文本文件（自定义语料：原文由用户提供）。
  ///
  /// @param textPaths 候选路径
  const CorpusReference.textFile(this.textPaths)
      : surah = null,
        ayahStart = 0,
        ayahEnd = 0;

  /// 章号（自定义文本来源时为 null）。
  final int? surah;

  /// 起始节。
  final int ayahStart;

  /// 结束节（含）。
  final int ayahEnd;

  /// 原文文本候选路径（区间来源时为空）。
  final List<String> textPaths;

  /// 是否按经文库区间取原文。
  bool get isRange => surah != null;

  /// 区间内的节引用（有序）；自定义文本来源时为空。
  List<String> get expectedRefs => isRange
      ? <String>[for (var ayah = ayahStart; ayah <= ayahEnd; ayah++) '$surah:$ayah']
      : const <String>[];

  /// 区间展示名（自定义文本来源时为「自定义原文」）。
  String get label => isRange
      ? (ayahStart == ayahEnd ? '$surah:$ayahStart' : '$surah:$ayahStart-$ayahEnd')
      : '自定义原文';
}

/// 一条语料。
class CorpusItem {
  /// 构造语料条目。
  ///
  /// @param id 唯一标识（界面状态与结果记录用）
  /// @param title 展示名
  /// @param audio 音频来源
  /// @param reference 原文来源
  const CorpusItem({
    required this.id,
    required this.title,
    required this.audio,
    required this.reference,
  });

  /// 唯一标识。
  final String id;

  /// 展示名。
  final String title;

  /// 音频来源。
  final CorpusAudioSource audio;

  /// 原文来源。
  final CorpusReference reference;

  /// 期望章节（区间来源时非空，用于命中判定）。
  List<String> get expectedRefs => reference.expectedRefs;
}

/// 语料清单。
class CorpusCatalog {
  /// 内置语料目录。
  static const String assetDir = 'assets/quran_offline/corpus/';

  /// 内置语料清单文件。
  static const String manifestAsset = '${assetDir}manifest.json';

  /// 设备语料目录候选（应用私有目录与外置私有目录）。
  static const List<String> deviceDirs = <String>[
    '/data/data/com.llvision.quran_offline_demo/files/corpus',
    '/storage/emulated/0/Android/data/com.llvision.quran_offline_demo/files/corpus',
  ];

  /// 文件名解析正则：`corpus_SSS_AAA_BBB.wav`。
  static final RegExp _fileNamePattern =
      RegExp(r'^corpus_(\d{3})_(\d{3})_(\d{3})\.wav$', caseSensitive: false);

  /// 加载清单：内置语料 + 设备语料。
  ///
  /// @param bundle 资产来源，默认 [rootBundle]
  /// @param listDir 目录列举实现，默认用 dart:io（测试可注入）
  /// @param readText 文本读取实现（读取设备语料的同名 .txt）
  /// @return 语料条目列表（内置在前）
  static Future<List<CorpusItem>> load({
    AssetBundle? bundle,
    Future<List<String>> Function(String dir)? listDir,
    Future<String?> Function(String path)? readText,
  }) async {
    final assets = bundle ?? rootBundle;
    final items = <CorpusItem>[];
    items.addAll(await _loadBuiltin(assets));
    items.addAll(await _loadDevice(listDir ?? _listFiles, readText ?? _readText));
    return items;
  }

  /// 载入内置语料（读 `manifest.json`；缺失或格式不符时返回空列表）。
  static Future<List<CorpusItem>> _loadBuiltin(AssetBundle bundle) async {
    try {
      final content = await bundle.loadString(manifestAsset);
      final decoded = jsonDecode(content);
      if (decoded is! List) return const <CorpusItem>[];
      final items = <CorpusItem>[];
      for (final entry in decoded) {
        if (entry is! Map) continue;
        final file = entry['file'];
        final surah = entry['surah'];
        final start = entry['ayahStart'];
        final end = entry['ayahEnd'];
        if (file is! String || surah is! int || start is! int || end is! int) continue;
        items.add(
          CorpusItem(
            id: file,
            title: '内置语料 · '
                '${CorpusReference.range(surah: surah, ayahStart: start, ayahEnd: end).label}',
            audio: CorpusAudioSource.asset('$assetDir$file'),
            reference: CorpusReference.range(surah: surah, ayahStart: start, ayahEnd: end),
          ),
        );
      }
      return items;
    } catch (_) {
      // 清单不存在或不是合法 JSON：视为没有内置语料，不影响设备语料
      return const <CorpusItem>[];
    }
  }

  /// 载入设备语料：`files/corpus/*.wav`，同名 `.txt` 作为原文。
  static Future<List<CorpusItem>> _loadDevice(
    Future<List<String>> Function(String dir) listDir,
    Future<String?> Function(String path) readText,
  ) async {
    final items = <CorpusItem>[];
    for (final dir in deviceDirs) {
      final files = await listDir(dir);
      final wavs = files.where((path) => path.toLowerCase().endsWith('.wav')).toList()..sort();
      for (final wav in wavs) {
        final name = _baseName(wav);
        final textPath = '${wav.substring(0, wav.length - 4)}.txt';
        final text = await readText(textPath);
        final range = parseRangeFromFileName(name);
        final reference = text != null && text.trim().isNotEmpty
            ? CorpusReference.textFile(<String>[textPath])
            : (range == null
                ? null
                : CorpusReference.range(
                    surah: range.$1,
                    ayahStart: range.$2,
                    ayahEnd: range.$3,
                  ));
        if (reference == null) continue; // 既没有原文也没有可解析的区间：跳过
        items.add(
          CorpusItem(
            id: wav,
            title: '设备语料 · ${name.replaceAll('.wav', '')}',
            audio: CorpusAudioSource.deviceFile(<String>[wav]),
            reference: reference,
          ),
        );
      }
    }
    return items;
  }

  /// 从文件名解析章节区间（`corpus_036_001_005.wav`）。
  ///
  /// @param fileName 文件名
  /// @return `(章号, 起始节, 结束节)`；不符合命名规则时返回 null
  static (int, int, int)? parseRangeFromFileName(String fileName) {
    final match = _fileNamePattern.firstMatch(fileName);
    if (match == null) return null;
    return (
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
    );
  }

  /// 太斯米（归一化后的词形，与经文库 `text_clean` 一致）。
  static const List<String> bismillahWords = <String>['بسم', 'الله', 'الرحمن', 'الرحيم'];

  /// 语料原文的候选变体：完整原文 + 去掉太斯米前缀的版本。
  ///
  /// 经文库把太斯米并入部分章节的原文（`1:1`、`36:1`、`112:1` 等），而语料音频
  /// 不一定包含太斯米。若只按完整原文比对，会凭空多出 4 个「缺失词」把 F1 压下去；
  /// 因此给出两个变体，比对时取更贴合音频的那个，并在比对页来源上标明。
  ///
  /// @param full 完整原文
  /// @return 候选原文列表（至少一条；无太斯米前缀时只有一条）
  static List<ReferenceText> referenceVariants(ReferenceText full) {
    final words = full.words;
    if (words.length <= bismillahWords.length) return <ReferenceText>[full];
    for (var i = 0; i < bismillahWords.length; i++) {
      if (words[i] != bismillahWords[i]) return <ReferenceText>[full];
    }
    final trimmedWords = words.sublist(bismillahWords.length);
    final rawTokens = full.rawText
        .split(RegExp(r'\s+'))
        .where((token) => token.trim().isNotEmpty)
        .toList(growable: false);
    final trimmedRaw = rawTokens.length > bismillahWords.length
        ? rawTokens.sublist(bismillahWords.length).join(' ')
        : trimmedWords.join(' ');
    return <ReferenceText>[
      full,
      ReferenceText(
        words: trimmedWords,
        rawText: trimmedRaw,
        source: '${full.source}（去掉太斯米前缀）',
      ),
    ];
  }

  /// 取文件名。
  static String _baseName(String path) {
    final index = path.lastIndexOf('/');
    return index < 0 ? path : path.substring(index + 1);
  }

  /// 默认目录列举实现。
  static Future<List<String>> _listFiles(String dir) async {
    try {
      final directory = Directory(dir);
      if (!await directory.exists()) return const <String>[];
      return directory
          .listSync()
          .whereType<File>()
          .map((file) => file.path)
          .toList(growable: false);
    } catch (_) {
      return const <String>[];
    }
  }

  /// 默认文本读取实现。
  static Future<String?> _readText(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      return await file.readAsString();
    } catch (_) {
      return null;
    }
  }
}
