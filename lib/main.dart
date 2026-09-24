/// 应用入口。
///
/// 产品首页是广播识别（[BroadcastHomePage]）：外部广播收音 → 离线 ASR →
/// 全经 6236 节匹配 → 端侧翻译 → 持久化历史。
///
/// 旧 Demo（[QuranOfflineDemoPage]）保留为「开发诊断」，不再充当产品首页：
/// 它承载实时贯音、语料离线校核与流式诊断等回归入口，启动时不执行内置样本
/// 自测，避免占用推理资源并污染历史。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:quran_broadcast_sdk/quran_broadcast_sdk.dart';
import 'package:quran_broadcast_sdk/broadcast/ui/broadcast_home_page.dart';
import 'quran_offline/quran_offline_demo_page.dart';

/// 无人值守真机长测的自动启停时长（秒）。
///
/// 通过 `--dart-define=quran_auto_run_seconds=2100` 注入，仅在 Debug 包生效。
/// 真机上禁止输入注入（MIUI 拒绝 `INJECT_EVENTS`），无法用 adb 点击界面按钮，
/// 因此长时连续测试需要这条**仅 Debug 编译期生效**的入口；Release 与默认
/// Debug 构建均为 0，不会自动开始或停止收音。
const int kAutoRunSeconds = int.fromEnvironment('quran_auto_run_seconds');

/// 程序入口。
void main() {
  runApp(const QuranBroadcastApp());
}

/// 广播识别应用根组件。
class QuranBroadcastApp extends StatelessWidget {
  /// 构造根组件。
  const QuranBroadcastApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '古兰经广播识别',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: const BroadcastBootstrapPage(),
    );
  }
}

/// 旧 Demo 应用根组件（开发诊断入口，保留给回归与冒烟测试使用）。
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

/// 启动引导页：初始化依赖（新库、数据库、模型、翻译引擎）后再进入首页。
///
/// 模型约 130 MB，首次加载需要数秒；失败时给出可重试入口，并允许直接进入
/// 旧 Demo 诊断，不把失败状态隐藏掉。
class BroadcastBootstrapPage extends StatefulWidget {
  /// 构造引导页。
  const BroadcastBootstrapPage({super.key});

  @override
  State<BroadcastBootstrapPage> createState() => _BroadcastBootstrapPageState();
}

class _BroadcastBootstrapPageState extends State<BroadcastBootstrapPage> {
  QuranBroadcastSdk? _sdk;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_bootstrap());
  }

  Future<void> _bootstrap() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final sdk = await QuranBroadcastSdk.initialize();
      if (!mounted) {
        await sdk.dispose();
        return;
      }
      setState(() {
        _sdk = sdk;
        _loading = false;
      });
      unawaited(_maybeAutoRun(sdk));
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _loading = false;
      });
    }
  }

  /// 无人值守长测：依赖就绪后自动开始收音，到时自动停止。
  ///
  /// 仅 `kDebugMode` 且显式注入 `quran_auto_run_seconds` 时执行；自动停止走
  /// 正常 [QuranBroadcastSdk.stop] 流程，保证末句落库。
  ///
  /// @param sdk 已初始化的 SDK
  Future<void> _maybeAutoRun(QuranBroadcastSdk sdk) async {
    if (!kDebugMode || kAutoRunSeconds <= 0) return;
    debugPrint('[Broadcast] 自动长测已启用：${kAutoRunSeconds}s 后自动停止（仅 Debug）');
    final started = await sdk.start();
    debugPrint('[Broadcast] 自动长测开始结果：$started');
    if (!started) {
      return;
    }
    await Future<void>.delayed(Duration(seconds: kAutoRunSeconds));
    await sdk.stop();
    debugPrint('[Broadcast] 自动长测已停止');
  }

  @override
  void dispose() {
    unawaited(_sdk?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sdk = _sdk;
    if (sdk != null) {
      return sdk.homePage(
        diagnosticPageBuilder: (_) => const QuranOfflineDemoPage(),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('古兰经广播识别')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (_loading) ...<Widget>[
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                const Text('正在加载独立经文库、数据库与 ASR 模型…'),
                const SizedBox(height: 8),
                const Text(
                  '首次启动需要解压模型，请稍候。',
                  style: TextStyle(fontSize: 12, color: Colors.black54),
                ),
              ] else ...<Widget>[
                const Icon(
                  Icons.error_outline,
                  size: 40,
                  color: Colors.redAccent,
                ),
                const SizedBox(height: 12),
                Text('初始化失败：$_error', textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () => unawaited(_bootstrap()),
                  child: const Text('重试'),
                ),
              ],
              const SizedBox(height: 24),
              TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const QuranOfflineDemoPage(),
                  ),
                ),
                child: const Text('进入开发诊断（旧 Demo）'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
