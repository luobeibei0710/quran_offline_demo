/// 比对用「原文」（参考答案）的加载。
///
/// 两条来源，按优先级：
/// 1. **设备文件覆盖**（联调换语料用，不必重新构建）：把 txt 推到下列任一
///    路径即可，应用重启后生效；路径对应 debug 包的私有目录与外部私有目录。
///    ```bash
///    adb push 1阿拉伯.txt /data/local/tmp/reference_text.txt
///    adb shell run-as com.llvision.quran_offline_demo \
///      cp /data/local/tmp/reference_text.txt files/reference_text.txt
///    ```
/// 2. **内置资产**：`assets/quran_reference/reference_text.txt`（随包发布，
///    也是设备文件缺失时的回退）。
///
/// 注意：[overridePaths] 为 Android 应用的私有目录；iOS 沙盒路径不同且未接入，
/// 因此在 iOS 上固定使用内置资产。
library;

import 'dart:io';

import 'package:flutter/services.dart' show AssetBundle, rootBundle;

/// 已加载的原文。
class ReferenceText {
  /// 构造原文。
  ///
  /// @param words 原文词序列（保留原始书写形式）
  /// @param rawText 原文全文
  /// @param source 来源说明（展示在比对页面，便于确认用的哪份原文）
  const ReferenceText({required this.words, required this.rawText, required this.source});

  /// 原文词序列。
  final List<String> words;

  /// 原文全文。
  final String rawText;

  /// 来源说明。
  final String source;

  /// 内置原文的资产路径。
  static const String assetPath = 'assets/quran_reference/reference_text.txt';

  /// 设备文件覆盖路径（按顺序尝试，命中即用）。
  static const List<String> overridePaths = <String>[
    '/data/data/com.llvision.quran_offline_demo/files/reference_text.txt',
    '/storage/emulated/0/Android/data/com.llvision.quran_offline_demo/files/reference_text.txt',
  ];

  /// 加载原文：设备文件优先，缺失时回退内置资产。
  ///
  /// @param bundle 资产来源，默认 [rootBundle]
  /// @param readFile 设备文件读取实现，默认用 dart:io（测试可注入假实现）
  /// @return 原文对象
  /// @throws StateError 设备文件与内置资产都取不到内容时抛出
  static Future<ReferenceText> load({
    AssetBundle? bundle,
    Future<String?> Function(String path)? readFile,
  }) async {
    final reader = readFile ?? _readDeviceFile;
    for (final path in overridePaths) {
      final content = await reader(path);
      if (content != null && content.trim().isNotEmpty) {
        return _parse(content, '设备文件：$path');
      }
    }

    final assets = bundle ?? rootBundle;
    final content = await assets.loadString(assetPath);
    if (content.trim().isEmpty) {
      throw StateError('原文为空：$assetPath');
    }
    return _parse(content, '内置文件：$assetPath');
  }

  /// 解析文本为词序列。
  static ReferenceText _parse(String content, String source) {
    final words = content
        .split(RegExp(r'\s+'))
        .map((word) => word.trim())
        .where((word) => word.isNotEmpty)
        .toList(growable: false);
    return ReferenceText(words: words, rawText: content, source: source);
  }

  /// 读取设备上的文件；不存在或不可读时返回 null。
  static Future<String?> _readDeviceFile(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      return await file.readAsString();
    } catch (_) {
      // 权限或路径不可用：交给下一来源
      return null;
    }
  }
}
