/// [QuranRecognizer] 的一次性识别与 [QuranStreamingSession] 流式会话测试。
///
/// 通过 [ScriptedOrtRunner] 注入合成声学证据，验证「解码 → 召回 → CTC 精排」
/// 全链路，无需真实 ONNX 模型。
///
/// 流式部分同时覆盖能量 VAD 门控：只有「类语音」音频（见
/// [buildSpeechLikeSamples]）才会触发识别，纯静音不会产生臆测结果。
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

    test('识别结果携带提词器所需的词列表与已读进度', () async {
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
        ),
      );
      final session = recognizer.createSession();
      final events = <QuranRecognitionEvent>[];
      final subscription = session.events.listen(events.add);

      // 语音块足够长以通过 VAD，且累积量满足最小窗口
      await session.feed(buildSpeechLikeSamples(0.2));
      await pumpEventQueue();

      expect(events, hasLength(1));
      final event = events.single;
      // 冠军为 1:1；提词器会附带下一节（1:2），因此词数多于单节
      expect(event.words.length, greaterThanOrEqualTo(2));
      // 夹具中 1:1 的 token 序列 [1, 2] 只构成 1 个词，故已读进度为 1
      expect(event.readWords, 1);

      await subscription.cancel();
      await session.dispose();
    });
  });

  group('QuranStreamingSession', () {
    /// 构造一个「静音超时收尾」用的识别器。
    ///
    /// @param runner 脚本化推理桥
    /// @param assets 夹具资产
    Future<QuranRecognizer> buildRecognizer(
      ScriptedOrtRunner runner, {
      required QuranStreamingConfig config,
    }) async {
      final assets = await loadFixtureAssets();
      return QuranRecognizer(assets: assets, runner: runner, config: config);
    }

    test('静音超时触发收尾事件并重置缓冲', () async {
      final runner = ScriptedOrtRunner(
        buildAlignedEvidence(<int>[FixtureTokens.bism, FixtureTokens.allah]),
      );
      final recognizer = await buildRecognizer(
        runner,
        config: const QuranStreamingConfig(
          triggerSeconds: 10.0, // 关闭周期性触发，只考察静音收尾
          minWindowSeconds: 0.1,
          finalSilenceSeconds: 0.2,
          silenceRmsThreshold: 0.012,
        ),
      );
      final session = recognizer.createSession();
      final events = <QuranRecognitionEvent>[];
      final subscription = session.events.listen(events.add);

      // 先喂入语音：不累加静音时长，也不触发识别（triggerSeconds 很大）
      await session.feed(buildSpeechLikeSamples(0.5));
      await pumpEventQueue();
      expect(events, isEmpty);

      await session.feed(Float32List(1600)); // 0.1 s 静音
      await pumpEventQueue();
      expect(events, isEmpty);

      await session.feed(Float32List(1600)); // 静音累计 0.2 s ≥ finalSilenceSeconds
      await pumpEventQueue();

      expect(events, hasLength(1));
      expect(events.single.isFinal, isTrue);
      expect(events.single.champion?.ref, '1:1');
      expect(events.single.audioSeconds, closeTo(0.7, 1e-6));
      expect(session.accumulatedSeconds, 0.0);
      expect(session.lastStableRef, isNull);

      await subscription.cancel();
      await session.dispose();
    });

    test('纯静音不产生事件（VAD 门控）', () async {
      final runner = ScriptedOrtRunner(
        buildAlignedEvidence(<int>[FixtureTokens.bism, FixtureTokens.allah]),
      );
      final recognizer = await buildRecognizer(
        runner,
        config: const QuranStreamingConfig(
          triggerSeconds: 10.0,
          minWindowSeconds: 0.1,
          finalSilenceSeconds: 0.2,
          silenceRmsThreshold: 0.012,
        ),
      );
      final session = recognizer.createSession();
      final events = <QuranRecognitionEvent>[];
      final subscription = session.events.listen(events.add);

      await session.feed(Float32List(3200)); // 0.2 s 全零：无语音特征
      await pumpEventQueue();
      await session.feed(Float32List(3200));
      await pumpEventQueue();

      expect(events, isEmpty);
      expect(runner.runCount, 0);

      await subscription.cancel();
      await session.dispose();
    });

    test('累积音频不足最小窗口时不产生事件', () async {
      final runner = ScriptedOrtRunner(
        buildAlignedEvidence(<int>[FixtureTokens.bism, FixtureTokens.allah]),
      );
      final recognizer = await buildRecognizer(
        runner,
        config: const QuranStreamingConfig(
          triggerSeconds: 0.05,
          minWindowSeconds: 1.0,
          finalSilenceSeconds: 100.0,
        ),
      );
      final session = recognizer.createSession();
      final events = <QuranRecognitionEvent>[];
      final subscription = session.events.listen(events.add);

      // 有语音（可通过 VAD），但 0.2 s < minWindowSeconds(1.0)
      await session.feed(buildSpeechLikeSamples(0.2));
      await pumpEventQueue();

      expect(events, isEmpty);
      expect(runner.runCount, 0);

      await subscription.cancel();
      await session.dispose();
    });

    test('多次喂入相同内容可标记为稳定命中', () async {
      final runner = ScriptedOrtRunner(
        buildAlignedEvidence(<int>[FixtureTokens.bism, FixtureTokens.allah]),
      );
      final recognizer = await buildRecognizer(
        runner,
        config: const QuranStreamingConfig(
          triggerSeconds: 0.05,
          minWindowSeconds: 0.05,
          finalSilenceSeconds: 100.0,
          stableRounds: 2,
        ),
      );
      final session = recognizer.createSession();
      final events = <QuranRecognitionEvent>[];
      final subscription = session.events.listen(events.add);

      // 首轮：命中但未稳定
      await session.feed(buildSpeechLikeSamples(0.2));
      await pumpEventQueue();
      // 次轮：同一引用连续命中，标记为稳定
      await session.feed(buildSpeechLikeSamples(0.2));
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
