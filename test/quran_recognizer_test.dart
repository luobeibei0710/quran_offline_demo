/// [QuranRecognizer] 的一次性识别与 [QuranStreamingSession] 流式会话测试。
///
/// 通过 [ScriptedOrtRunner] 注入合成声学证据，验证「解码 → 召回 → CTC 精排」
/// 全链路，无需真实 ONNX 模型。
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:quran_offline_demo/quran_offline/quran_recognizer.dart';

import 'support/quran_test_fixtures.dart';

void main() {
  group('QuranRecognizer.recognizeOnce', () {
    test('合成证据驱动端到端识别出 1:1', () async {
      final assets = await loadFixtureAssets();
      final runner = ScriptedOrtRunner(
        buildAlignedEvidence(<int>[FixtureTokens.bism, FixtureTokens.allah]),
      );
      final recognizer = QuranRecognizer(assets: assets, runner: runner);

      final result = await recognizer.recognizeOnce(Float32List(QuranRecognizer.sampleRate));

      expect(runner.runCount, 1);
      expect(result.decodedText, 'بسمالله');
      expect(result.champion?.ref, '1:1');
      expect(result.champion?.label, 'Al-Fatihah 1:1');
      expect(result.champion?.isSpan, isFalse);
      expect(result.recallCount, greaterThan(0));
      // 冠军与次优差距极大，置信度应被钳到上限
      expect(result.confidence, 1.0);
    });

    test('精排会跳过帧数不足的多节连读跨度', () async {
      final assets = await loadFixtureAssets();
      final runner = ScriptedOrtRunner(
        buildAlignedEvidence(<int>[FixtureTokens.bism, FixtureTokens.allah]),
      );
      final recognizer = QuranRecognizer(assets: assets, runner: runner);

      final result = await recognizer.recognizeOnce(Float32List(QuranRecognizer.sampleRate));

      // 1:1:2 需要 7 帧，而证据只有 5 帧，不应出现在候选里
      final refs = <String>[
        result.champion!.ref,
        ...result.runnersUp.map((candidate) => candidate.ref),
      ];
      expect(refs, isNot(contains('1:1-2')));
    });
  });

  group('QuranStreamingSession', () {
    test('静音超时触发收尾事件并重置缓冲', () async {
      final assets = await loadFixtureAssets();
      final runner = ScriptedOrtRunner(
        buildAlignedEvidence(<int>[FixtureTokens.bism, FixtureTokens.allah]),
      );
      final recognizer = QuranRecognizer(
        assets: assets,
        runner: runner,
        // 静音阈值设为 1.0，使任何分块都被判定为静音，直接走收尾分支
        config: const QuranStreamingConfig(
          triggerSeconds: 10.0,
          minWindowSeconds: 0.05,
          finalSilenceSeconds: 0.05,
          silenceRmsThreshold: 1.0,
        ),
      );
      final session = recognizer.createSession();
      final events = <QuranRecognitionEvent>[];
      final subscription = session.events.listen(events.add);

      await session.feed(Float32List(1600)); // 0.1 s
      await pumpEventQueue();

      expect(events, hasLength(1));
      expect(events.single.isFinal, isTrue);
      expect(events.single.champion?.ref, '1:1');
      expect(events.single.audioSeconds, closeTo(0.1, 1e-6));
      expect(session.accumulatedSeconds, 0.0);
      expect(session.lastStableRef, isNull);

      await subscription.cancel();
      await session.dispose();
    });

    test('空闲音频不满足最小窗口时不产生事件', () async {
      final assets = await loadFixtureAssets();
      final runner = ScriptedOrtRunner(
        buildAlignedEvidence(<int>[FixtureTokens.bism, FixtureTokens.allah]),
      );
      final recognizer = QuranRecognizer(
        assets: assets,
        runner: runner,
        config: const QuranStreamingConfig(
          triggerSeconds: 0.05,
          minWindowSeconds: 1.0,
          finalSilenceSeconds: 100.0,
          silenceRmsThreshold: 0.0,
        ),
      );
      final session = recognizer.createSession();
      final events = <QuranRecognitionEvent>[];
      final subscription = session.events.listen(events.add);

      await session.feed(Float32List(1600)); // 0.1 s < minWindowSeconds(1.0)
      await pumpEventQueue();

      expect(events, isEmpty);
      expect(runner.runCount, 0);

      await subscription.cancel();
      await session.dispose();
    });

    test('多次喂入相同内容可标记为稳定命中', () async {
      final assets = await loadFixtureAssets();
      final runner = ScriptedOrtRunner(
        buildAlignedEvidence(<int>[FixtureTokens.bism, FixtureTokens.allah]),
      );
      final recognizer = QuranRecognizer(
        assets: assets,
        runner: runner,
        config: const QuranStreamingConfig(
          triggerSeconds: 0.05,
          minWindowSeconds: 0.05,
          finalSilenceSeconds: 100.0,
          silenceRmsThreshold: 0.0,
          stableRounds: 2,
        ),
      );
      final session = recognizer.createSession();
      final events = <QuranRecognitionEvent>[];
      final subscription = session.events.listen(events.add);

      // 首轮：命中但未稳定
      await session.feed(Float32List(1600));
      await pumpEventQueue();
      // 次轮：同一引用连续命中，标记为稳定
      await session.feed(Float32List(1600));
      await pumpEventQueue();

      expect(events, hasLength(2));
      expect(events.first.stable, isFalse);
      expect(events.last.stable, isTrue);
      expect(session.lastStableRef, '1:1');

      await subscription.cancel();
      await session.dispose();
    });
  });
}
