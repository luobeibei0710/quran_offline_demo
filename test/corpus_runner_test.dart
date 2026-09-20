/// 语料灌音器的单元测试。
///
/// 用脚本化推理桥 + 夹具资产驱动真实流式会话（无需模型与真实语料）。
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:quran_offline_demo/quran_offline/corpus_runner.dart';
import 'package:quran_offline_demo/quran_offline/quran_recognizer.dart';

import 'support/quran_test_fixtures.dart';

void main() {
  /// 构造灌音器：夹具资产 + 固定声学证据（对齐到 1:1 的 token 序列）。
  Future<CorpusRunner> buildRunner({List<String>? expectedRefs, Float32List? samples}) async {
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
    return CorpusRunner(
      recognizer: recognizer,
      samples: samples ?? buildSpeechLikeSamples(0.3),
      expectedRefs: expectedRefs ?? const <String>[],
      chunkMs: 10,
    );
  }

  group('CorpusRunner.run', () {
    test('灌音跑完：产生事件、拼出转写、命中期望章节', () async {
      final runner = await buildRunner(expectedRefs: const <String>['1:1']);
      final fractions = <double>[];

      final result = await runner.run(onProgress: (progress) => fractions.add(progress.fraction));

      expect(result.eventCount, greaterThan(0));
      expect(result.seenRefs, contains('1:1'));
      expect(result.stableRefs, contains('1:1'));
      expect(result.hit, isTrue);
      expect(result.stableHit, isTrue);
      expect(result.transcriptWords, isNotEmpty);
      expect(result.transcriptText, isNotEmpty);
      expect(result.elapsed.inMilliseconds, greaterThanOrEqualTo(0));
      expect(fractions, isNotEmpty);
      expect(fractions.last, closeTo(1.0, 0.01));
    });

    test('转写稿取稳定命中章节的标准经文，同节只记一次', () async {
      final runner = await buildRunner(expectedRefs: const <String>['1:1']);

      final result = await runner.run();

      expect(result.transcriptRefs, contains('1:1'));
      // 夹具里 1:1 的标准经文是「بسم الله」
      expect(result.transcriptWords, <String>['بسم', 'الله']);
      // 逐词 ASR 原始输出仍然保留（诊断用）
      expect(result.rawTranscriptWords, isNotEmpty);
      expect(result.rawTranscriptText, isNotEmpty);
    });

    test('连续朗读音频（帧能量均匀、会被实时门控拒绝）也能灌音识别', () async {
      // 真实朗读语料（含官方语料）的峰值/中位数只有 1.3~2.0，达不到 VAD 的 2.5 倍
      final runner = await buildRunner(
        expectedRefs: const <String>['1:1'],
        samples: buildContinuousSpeechSamples(0.5),
      );

      final result = await runner.run();

      expect(result.eventCount, greaterThan(0));
      expect(result.hit, isTrue);
    });

    test('期望章节与识别结果不符时判为未命中', () async {
      final runner = await buildRunner(expectedRefs: const <String>['112:1']);

      final result = await runner.run();

      expect(result.seenRefs, isNot(contains('112:1')));
      expect(result.hit, isFalse);
      expect(result.stableHit, isFalse);
    });

    test('自定义语料（无期望章节）不做命中判定', () async {
      final runner = await buildRunner();

      final result = await runner.run();

      expect(result.expectedRefs, isEmpty);
      expect(result.hit, isNull);
      expect(result.stableHit, isNull);
      expect(result.transcriptWords, isNotEmpty);
    });

    test('取消后不再灌音，也不产生事件', () async {
      final runner = await buildRunner(expectedRefs: const <String>['1:1'])..cancel();

      final result = await runner.run();

      expect(result.eventCount, 0);
      expect(result.transcriptWords, isEmpty);
    });
  });
}
