/// 语料清单：可供「语料验证」选中的音频 + 它的原文（参考答案）。
///
/// 两类来源：
/// 1. **官方语料**：Tilawa v0.2.0 的测试语料（文件名即答案），随包内置，
///    原文取经文库里的标准经文（不是识别结果，可作为独立参考答案）；
/// 2. **自定义语料**：`adb push` 到应用私有目录的 WAV + 该段朗读的原文 txt，
///    换语料不必重新构建（原文路径复用 [ReferenceText] 的设备覆盖机制）。
library;

import 'dart:io';

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
  /// 章节（官方语料：原文取该节的标准经文）。
  ///
  /// @param ref `surah:ayah`
  const CorpusReference.verse(this.ref) : textPaths = const <String>[];

  /// 设备文本文件（自定义语料）。
  ///
  /// @param textPaths 候选路径
  const CorpusReference.textFile(this.textPaths) : ref = null;

  /// 期望章节（自定义语料时为 null）。
  final String? ref;

  /// 原文文本候选路径（官方语料时为空）。
  final List<String> textPaths;

  /// 是否有「标准答案章节」可用于命中判定。
  bool get hasExpectedRef => ref != null;
}

/// 一条语料。
class CorpusItem {
  /// 构造语料条目。
  ///
  /// @param id 唯一标识（用于界面状态与结果记录）
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
}

/// 语料清单。
class CorpusCatalog {
  /// 官方语料：资产路径 → 期望章节（文件名 SSSAAA 即章号与节号）。
  static const List<({String assetKey, String ref})> officialSamples =
      <({String assetKey, String ref})>[
    (assetKey: 'assets/quran_offline/sample_001001.wav', ref: '1:1'),
    (assetKey: 'assets/quran_offline/sample_001002.wav', ref: '1:2'),
    (assetKey: 'assets/quran_offline/sample_002255.wav', ref: '2:255'),
    (assetKey: 'assets/quran_offline/sample_036001.wav', ref: '36:1'),
    (assetKey: 'assets/quran_offline/sample_112001.wav', ref: '112:1'),
  ];

  /// 自定义语料的音频候选路径（Android 私有目录与外部私有目录）。
  ///
  /// 推送方式（debug 包）：
  /// ```bash
  /// adb push corpus_audio.wav /data/local/tmp/corpus_audio.wav
  /// adb shell run-as com.llvision.quran_offline_demo \
  ///   cp /data/local/tmp/corpus_audio.wav files/corpus_audio.wav
  /// ```
  static const List<String> customAudioPaths = <String>[
    '/data/data/com.llvision.quran_offline_demo/files/corpus_audio.wav',
    '/storage/emulated/0/Android/data/com.llvision.quran_offline_demo/files/corpus_audio.wav',
  ];

  /// 自定义语料的条目 id。
  static const String customId = 'custom';

  /// 太斯米（归一化后的词形，与经文库 `text_clean` 一致）。
  static const List<String> bismillahWords = <String>['بسم', 'الله', 'الرحمن', 'الرحيم'];

  /// 官方语料原文的候选变体：完整经文 + 去掉太斯米前缀的版本。
  ///
  /// 经文库把太斯米并入部分章节的原文（如 `36:1` = 「太斯米 + يس」共 5 词、
  /// `112:1` = 「太斯米 + قل هو الله احد」共 8 词），但**官方语料的部分音频并不含
  /// 太斯米**（`36:1` 音频 4.6 s 里只有 يس）。若只按完整经文比对，会凭空多出 4 个
  /// 「缺失词」，F1 结构性偏低；因此这里给出两个变体，比对时取更贴合音频的那个，
  /// 并在比对页的来源上标明用的是哪一个。
  ///
  /// @param full 经文库的完整原文
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

  /// 构建清单：官方语料始终在列；检测到自定义音频时追加一条。
  ///
  /// @param fileExists 设备文件存在性判断，默认用 dart:io（测试可注入）
  /// @return 语料条目列表
  static Future<List<CorpusItem>> load({
    Future<bool> Function(String path)? fileExists,
  }) async {
    final exists = fileExists ?? _fileExists;
    final items = <CorpusItem>[
      for (final sample in officialSamples)
        CorpusItem(
          id: sample.assetKey,
          title: '官方语料 · ${sample.ref}',
          audio: CorpusAudioSource.asset(sample.assetKey),
          reference: CorpusReference.verse(sample.ref),
        ),
    ];

    for (final path in customAudioPaths) {
      if (await exists(path)) {
        items.add(
          CorpusItem(
            id: customId,
            title: '自定义语料（设备文件）',
            audio: CorpusAudioSource.deviceFile(customAudioPaths),
            reference: CorpusReference.textFile(ReferenceText.overridePaths),
          ),
        );
        break;
      }
    }
    return items;
  }

  /// 默认的文件存在性判断。
  static Future<bool> _fileExists(String path) async {
    try {
      return await File(path).exists();
    } catch (_) {
      return false;
    }
  }
}
