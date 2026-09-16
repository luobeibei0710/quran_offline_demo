/// 古兰经离线识别 Demo 入口。
///
/// 端侧全离线：麦克风 → ONNX 推理（原生）→ CTC 解码 → 经文约束匹配 → 展示。
library;

import 'package:flutter/material.dart';

import 'quran_offline/quran_offline_demo_page.dart';

/// 程序入口。
void main() {
  runApp(const QuranOfflineDemoApp());
}

/// Demo 应用根组件。
class QuranOfflineDemoApp extends StatelessWidget {
  /// 构造根组件。
  const QuranOfflineDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '古兰经离线识别 Demo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: const QuranOfflineDemoPage(),
    );
  }
}
