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

    test('声学上明显更优的多节连读仍能胜出（防止跨度惩罚过重）', () async {
      final assets = await loadFixtureAssets();
      // 证据对齐到 1:1 与 1:2 的连读序列 [1, 2, 3]
      final runner = ScriptedOrtRunner(
        buildAlignedEvidence(<int>[
          FixtureTokens.bism,
          FixtureTokens.allah,
          FixtureTokens.alhamd,
        ]),
      );
      final recognizer = QuranRecognizer(assets: assets, runner: runner);

      final result = await recognizer.recognizeOnce(Float32List(QuranRecognizer.sampleRate));

      // 单节候选需要把多出来的内容帧当空白，声学上明显更差，故连读跨度应当胜出
      expect(result.champion?.ref, '1:1-2');
      expect(result.champion?.isSpan, isTrue);
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

  group('能量 VAD 与绝对电平解耦', () {
    test('弱语音也能通过门控（旧口径的固定下限会整段跳过）', () async {
      final (session, events, _) = await startSessionWithEvents(
        const QuranStreamingConfig(
          triggerSeconds: 0.05,
          minWindowSeconds: 0.05,
          finalSilenceSeconds: 100.0,
        ),
      );

      // 峰值 0.02 / 本底 0.006：信噪比约 3.3，但峰值低于旧下限 speechRmsThreshold=0.03
      await session.feed(buildSpeechLikeSamples(0.5, peak: 0.02, base: 0.006));
      await pumpEventQueue();

      expect(events, hasLength(1));
      expect(events.single.champion?.ref, '1:1');
      expect(session.quietBaseline, greaterThan(0));

      await session.dispose();
    });

    test('连续朗读（无停顿）会被能量门控拒绝：信噪比判据的前提是窗口内有停顿', () async {
      final (session, events, _) = await startSessionWithEvents(
        const QuranStreamingConfig(
          triggerSeconds: 0.05,
          minWindowSeconds: 0.05,
          finalSilenceSeconds: 100.0,
        ),
      );

      // 帧能量均匀：峰值/中位数 ≈ 1.1，远低于 speechSnrRatio=2.5
      await session.feed(buildContinuousSpeechSamples(1.0));
      await pumpEventQueue();

      expect(events, isEmpty);

      await session.dispose();
    });

    test('按「已知是朗读」建会话时，连续朗读可正常识别（语料灌音路径）', () async {
      final (session, events, _) = await startSessionWithEvents(
        const QuranStreamingConfig(
          triggerSeconds: 0.05,
          minWindowSeconds: 0.05,
          finalSilenceSeconds: 100.0,
          stableRounds: 1,
          assumeSpeech: true,
        ),
      );

      await session.feed(buildContinuousSpeechSamples(1.0));
      await pumpEventQueue();

      expect(events, isNotEmpty);
      expect(events.last.champion?.ref, '1:1');

      await session.dispose();
    });

    test('稳态噪声不触发（放宽下限后仍不误触发）', () async {
      final (session, events, runner) = await startSessionWithEvents(
        const QuranStreamingConfig(
          triggerSeconds: 0.05,
          minWindowSeconds: 0.05,
          finalSilenceSeconds: 100.0,
        ),
      );

      // 幅值 0.02 但几乎不波动：峰值/本底 ≈ 1.1，低于 speechSnrRatio=2.5
      await session.feed(buildSteadyNoiseSamples(1.0, level: 0.02));
      await pumpEventQueue();

      expect(events, isEmpty);
      expect(runner.runCount, 0);

      await session.dispose();
    });

    test('提交已确认章节后窗口前移（裁掉已读音频并保留重叠）', () async {
      final (session, events, _) = await startSessionWithEvents(
        const QuranStreamingConfig(
          triggerSeconds: 0.05,
          minWindowSeconds: 0.05,
          finalSilenceSeconds: 100.0,
          stableRounds: 1,
          windowOverlapSeconds: 1.0,
        ),
      );

      await session.feed(buildSpeechLikeSamples(3.0));
      await pumpEventQueue();

      expect(events.single.committedRef, '1:1');
      // 3.0 s 音频对应 5 帧证据 → 每帧 0.6 s；已读内容结束于第 3 帧（= 2.4 s），
      // 裁剪点 = 2.4 s − 1.0 s 重叠 = 1.4 s → 保留 3.0 − 1.4 = 1.6 s
      expect(session.accumulatedSeconds, closeTo(1.6, 0.02));
      expect(events.single.advancedSeconds, closeTo(1.4, 0.02));
      expect(session.committedSequence, <String>['1:1']);

      await session.dispose();
    });

    test('关闭窗口推进时不裁剪音频', () async {
      final (session, events, _) = await startSessionWithEvents(
        const QuranStreamingConfig(
          triggerSeconds: 0.05,
          minWindowSeconds: 0.05,
          finalSilenceSeconds: 100.0,
          stableRounds: 1,
          advanceWindowOnCommit: false,
        ),
      );

      await session.feed(buildSpeechLikeSamples(3.0));
      await pumpEventQueue();

      expect(events.single.justCommitted, isTrue);
      expect(session.accumulatedSeconds, closeTo(3.0, 0.02));

      await session.dispose();
    });

    test('环境噪声上升时会话本底缓慢回升', () async {
      final (session, _, _) = await startSessionWithEvents(
        const QuranStreamingConfig(
          triggerSeconds: 0.05,
          minWindowSeconds: 0.05,
          finalSilenceSeconds: 100.0,
        ),
      );

      // 先在低电平噪声下确立本底
      for (var i = 0; i < 3; i++) {
        await session.feed(buildSteadyNoiseSamples(1.0, level: 0.006));
        await pumpEventQueue();
      }
      final low = session.quietBaseline;
      expect(low, greaterThan(0));

      // 噪声电平翻倍：本底每轮最多回升 2%，多轮后应高于初始值
      for (var i = 0; i < 60; i++) {
        await session.feed(buildSteadyNoiseSamples(1.0, level: 0.012));
        await pumpEventQueue();
      }

      // 回落到新电平附近（噪声夹具带 ±5% 抖动，故上界留出抖动余量）
      expect(session.quietBaseline, greaterThan(low));
      expect(session.quietBaseline, lessThan(0.0135));

      await session.dispose();
    });
  });

  group('已确认进度（committed sequence）', () {
    test('稳定命中且读满阈值后提交一次，后续轮次不重复提交', () async {
      final (session, events, _) = await startSessionWithEvents(
        const QuranStreamingConfig(
          triggerSeconds: 0.05,
          minWindowSeconds: 0.05,
          finalSilenceSeconds: 100.0,
          stableRounds: 2,
        ),
      );

      for (var round = 0; round < 3; round++) {
        await session.feed(buildSpeechLikeSamples(0.2));
        await pumpEventQueue();
      }

      expect(events.map((event) => event.stable).toList(), <bool>[false, true, true]);
      expect(events.where((event) => event.justCommitted), hasLength(1));
      expect(events.first.committedSequence, isEmpty);
      expect(events.last.committedRef, '1:1');
      expect(events.last.committedSequence, <String>['1:1']);

      await session.dispose();
    });

    test('收尾保留已确认序列（跨段累加），用户重置才清空', () async {
      final (session, events, _) = await startSessionWithEvents(
        const QuranStreamingConfig(
          triggerSeconds: 0.05,
          minWindowSeconds: 0.05,
          finalSilenceSeconds: 0.2,
          stableRounds: 2,
          silenceRmsThreshold: 0.012,
        ),
      );

      await session.feed(buildSpeechLikeSamples(0.2));
      await pumpEventQueue();
      await session.feed(buildSpeechLikeSamples(0.2));
      await pumpEventQueue();
      expect(session.committedSequence, <String>['1:1']);

      await session.feed(Float32List(3200)); // 0.2 s 静音 → 收尾识别
      await pumpEventQueue();
      expect(events.last.isFinal, isTrue);
      expect(session.committedSequence, <String>['1:1']);

      session.reset();
      expect(session.committedSequence, isEmpty);
      expect(session.lastStableRef, isNull);

      await session.dispose();
    });
  });
}

/// 构造一个收集事件的流式会话（VAD 与已确认进度用例复用）。
///
/// @param config 流式配置
/// @return `(会话, 事件列表, 脚本化推理桥)`
Future<(QuranStreamingSession, List<QuranRecognitionEvent>, ScriptedOrtRunner)>
    startSessionWithEvents(QuranStreamingConfig config) async {
  final assets = await loadFixtureAssets();
  final runner = ScriptedOrtRunner(
    buildAlignedEvidence(<int>[FixtureTokens.bism, FixtureTokens.allah]),
  );
  final recognizer = QuranRecognizer(assets: assets, runner: runner, config: config);
  final session = recognizer.createSession();
  final events = <QuranRecognitionEvent>[];
  session.events.listen(events.add);
  return (session, events, runner);
}
