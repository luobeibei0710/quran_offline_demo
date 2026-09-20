/// 语料验证页的渲染与交互测试。
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quran_offline_demo/quran_offline/corpus_catalog.dart';
import 'package:quran_offline_demo/quran_offline/corpus_verify_page.dart';
import 'package:quran_offline_demo/quran_offline/quran_recognizer.dart';
import 'package:quran_offline_demo/quran_offline/reference_text.dart';

import 'support/quran_test_fixtures.dart';
import 'support/wav_fixtures.dart';

void main() {
  /// 构造测试页：夹具资产 + 脚本化推理桥 + 注入的语料/音频/原文。
  Future<Widget> buildPage() async {
    final assets = await loadFixtureAssets();
    final recognizer = QuranRecognizer(
      assets: assets,
      runner: ScriptedOrtRunner(
        buildAlignedEvidence(<int>[FixtureTokens.bism, FixtureTokens.allah]),
      ),
      config: const QuranStreamingConfig(
        triggerSeconds: 0.05,
        minWindowSeconds: 0.05,
        finalSilenceSeconds: 100.0,
        stableRounds: 1,
      ),
    );
    return MaterialApp(
      home: CorpusVerifyPage(
        assets: assets,
        recognizer: recognizer,
        chunkMs: 5,
        catalogLoader: () async => const <CorpusItem>[
          CorpusItem(
            id: 'test',
            title: '测试语料 1:1',
            audio: CorpusAudioSource.asset('assets/test.wav'),
            reference: CorpusReference.range(surah: 1, ayahStart: 1, ayahEnd: 1),
          ),
        ],
        audioLoader: (_) async => buildTestWav(buildSpeechLikeSamples(0.2)),
        referenceLoader: (_) async => const ReferenceText(
          words: <String>['بسم', 'الله'],
          rawText: 'بسم الله',
          source: '测试原文',
        ),
      ),
    );
  }

  testWidgets('语料列表渲染出条目与来源说明', (tester) async {
    await tester.pumpWidget(await buildPage());
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('测试语料 1:1'), findsOneWidget);
    expect(find.textContaining('测试原文'), findsOneWidget);
    expect(find.textContaining('不使用麦克风'), findsOneWidget);
  });

  testWidgets('选中语料后灌音完成并自动进入比对页', (tester) async {
    await tester.pumpWidget(await buildPage());
    await tester.pump();
    await tester.pump();

    await tester.tap(find.textContaining('测试语料 1:1'));
    // 灌音 0.2s（5ms 分块 → 40 块）+ 对齐 + 导航
    for (var i = 0; i < 120; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }

    expect(find.text('原文 / 转写比对'), findsOneWidget);
    expect(find.textContaining('F1'), findsWidgets);
    expect(find.textContaining('原文'), findsWidgets);
  });

  testWidgets('音频格式不合法时在列表上标出错误而不崩溃', (tester) async {
    final assets = await loadFixtureAssets();
    final recognizer = QuranRecognizer(
      assets: assets,
      runner: ScriptedOrtRunner(buildAlignedEvidence(<int>[FixtureTokens.bism])),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: CorpusVerifyPage(
          assets: assets,
          recognizer: recognizer,
          catalogLoader: () async => const <CorpusItem>[
            CorpusItem(
              id: 'bad',
              title: '坏音频',
              audio: CorpusAudioSource.asset('assets/bad.wav'),
              reference: CorpusReference.range(surah: 1, ayahStart: 1, ayahEnd: 1),
            ),
          ],
          audioLoader: (_) async => buildTestWav(Float32List(64), sampleRate: 44100),
          referenceLoader: (_) async => const ReferenceText(
            words: <String>['بسم'],
            rawText: 'بسم',
            source: '测试原文',
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('坏音频'), findsWidgets);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
  });
}
