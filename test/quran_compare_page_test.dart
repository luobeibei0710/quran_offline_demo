/// 比对页面的渲染测试（注入固定原文，不依赖真实资产与真机）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quran_offline_demo/quran_offline/quran_compare_page.dart';
import 'package:quran_offline_demo/quran_offline/reference_text.dart';

void main() {
  /// 渲染比对页并等待原文加载完成。
  Future<void> pumpComparePage(
    WidgetTester tester, {
    required List<String> reference,
    required List<String> hypothesis,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: QuranComparePage(
          hypothesisWords: hypothesis,
          referenceLoader: () async => ReferenceText(
            words: reference,
            rawText: reference.join(' '),
            source: '测试原文',
          ),
        ),
      ),
    );
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 10));
      if (find.text('转写').evaluate().isNotEmpty) return;
    }
  }

  testWidgets('左右两栏分别显示原文与转写，并汇总指标', (WidgetTester tester) async {
    await pumpComparePage(
      tester,
      reference: <String>['بسم', 'الله', 'الرحمن'],
      hypothesis: <String>['بسم', 'الرحمن'],
    );

    // 两列表头
    expect(find.text('原文'), findsOneWidget);
    expect(find.text('转写'), findsOneWidget);

    // 一行对照：原文「الله」缺失，转写侧显示占位符
    expect(find.text('—'), findsOneWidget);
    // 「بسم」与「الرحمن」在左右两栏各出现一次
    expect(find.text('بسم'), findsNWidgets(2));
    expect(find.text('الرحمن'), findsNWidgets(2));

    // 指标：一致 2 / 缺失 1 → F1 = 0.8，结论「良好」
    expect(find.text('良好'), findsOneWidget);
    expect(find.textContaining('F1 0.800'), findsOneWidget);
    expect(find.textContaining('缺失 1'), findsOneWidget);
    expect(find.textContaining('原文 3 词'), findsOneWidget);
    expect(find.textContaining('测试原文'), findsOneWidget);
  });

  testWidgets('原文加载失败时给出可用的原文来源提示', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: QuranComparePage(
          hypothesisWords: const <String>['بسم'],
          referenceLoader: () async => throw StateError('原文为空'),
        ),
      ),
    );
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 10));
      if (find.textContaining('原文加载失败').evaluate().isNotEmpty) break;
    }

    expect(find.textContaining('原文加载失败'), findsOneWidget);
    expect(find.textContaining(ReferenceText.assetPath), findsOneWidget);
    expect(find.textContaining('run-as com.llvision.quran_offline_demo'), findsOneWidget);
  });
}
