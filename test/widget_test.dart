/// Demo 应用首帧渲染与加载流程的冒烟测试。
///
/// 资产通道（`flutter/assets`）、ONNX 推理通道（`quran_offline/ort`）与
/// 录音插件通道（`com.llfbandit.record/messages`）均以假实现替换，
/// 因此测试不依赖 99 MB 真实模型资产，也不需要真机。
library;

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quran_offline_demo/main.dart';
import 'package:quran_offline_demo/quran_offline/ort_runner.dart';
import 'package:quran_offline_demo/quran_offline/quran_offline_demo_page.dart';

import 'support/quran_test_fixtures.dart';

/// 录音插件使用的方法通道名（见 `record_platform_interface`）。
const String _recordChannelName = 'com.llfbandit.record/messages';

void main() {
  final files = buildFixtureAssetFiles();

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    // 用内存资产替换真实资产包
    messenger.setMockMessageHandler('flutter/assets', (ByteData? message) async {
      if (message == null) return null;
      final key = utf8.decode(message.buffer.asUint8List(message.offsetInBytes, message.lengthInBytes));
      final content = files[key];
      if (content == null) return null;
      return ByteData.sublistView(Uint8List.fromList(utf8.encode(content)));
    });

    // ONNX 推理桥：仅需 loadModel 成功
    messenger.setMockMethodCallHandler(
      const MethodChannel(PlatformOrtRunner.channelName),
      (MethodCall call) async => call.method == 'loadModel' ? true : null,
    );

    // 录音插件：构造与销毁会触发通道调用，这里统一吞掉
    messenger.setMockMethodCallHandler(
      const MethodChannel(_recordChannelName),
      (MethodCall call) async => call.method == 'hasPermission' ? false : null,
    );
  });

  tearDownAll(() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMessageHandler('flutter/assets', null);
    messenger.setMockMethodCallHandler(const MethodChannel(PlatformOrtRunner.channelName), null);
    messenger.setMockMethodCallHandler(const MethodChannel(_recordChannelName), null);
  });

  setUp(() {
    // 清空 rootBundle 的字符串缓存：缓存里的 Future 由上一个测试的
    // FakeAsync 区域创建，直接复用会导致本测试中 await 永久挂起。
    rootBundle.clear();
  });

  testWidgets('首帧渲染 Demo 页面骨架', (WidgetTester tester) async {
    await tester.pumpWidget(const QuranOfflineDemoApp());

    expect(find.byType(QuranOfflineDemoPage), findsOneWidget);
    expect(find.text('古兰经离线识别 Demo'), findsOneWidget);

    // 进入页面即自动加载，等待其结束后再退出，避免残留异步回调
    await pumpUntilFound(tester, find.text('开始识别'));
  });

  testWidgets('资产与模型加载成功后进入就绪态', (WidgetTester tester) async {
    await tester.pumpWidget(const QuranOfflineDemoApp());
    await pumpUntilFound(tester, find.text('开始识别'));

    expect(find.text('开始识别'), findsOneWidget);
    expect(find.textContaining('就绪'), findsOneWidget);
    expect(find.textContaining('经文库 3 节'), findsOneWidget);
    expect(find.textContaining('词表 6 项'), findsOneWidget);
  });
}

/// 反复 pump 直到 [finder] 命中；用于等待页面内的异步加载落地。
///
/// @param tester 测试用的 WidgetTester
/// @param finder 目标查找器
/// @param maxPumps 最大 pump 次数，超出后直接返回由调用方断言失败
Future<void> pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  int maxPumps = 100,
}) async {
  for (var i = 0; i < maxPumps; i++) {
    if (finder.evaluate().isNotEmpty) return;
    await tester.pump(const Duration(milliseconds: 20));
  }
}
