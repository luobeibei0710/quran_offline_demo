import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:quran_offline_demo/broadcast/application/broadcast_transcriber.dart';
import 'package:quran_offline_demo/broadcast/application/quran_match_service.dart';
import 'package:quran_offline_demo/broadcast/data/broadcast_corpus.dart';
import 'package:quran_offline_demo/broadcast/domain/utterance_record.dart';
import 'package:quran_offline_demo/quran_offline/ctc_decoder.dart';
import 'package:quran_offline_demo/quran_offline/ctc_scorer.dart';
import 'package:quran_offline_demo/quran_offline/ort_runner.dart';

/// 固定返回同一份声学证据的推理桥（用于隔离匹配逻辑）。
class _ScriptedRunner implements OrtRunner {
  _ScriptedRunner(this.evidence);

  final AcousticEvidence evidence;

  @override
  Future<void> loadModel(String modelPath) async {}

  @override
  Future<AcousticEvidence> run(Float32List samples) async => evidence;

  @override
  Future<void> dispose() async {}
}

/// 按目标 token 序列合成「高概率恰好落在这些 token 上」的声学证据。
AcousticEvidence _evidenceFor(List<int> target, {required int blankId, required int vocabSize}) {
  final states = <int>[];
  for (final id in target) {
    states
      ..add(blankId)
      ..add(id);
  }
  states.add(blankId);
  final logprobs = Float32List(states.length * vocabSize)
    ..fillRange(0, states.length * vocabSize, -14);
  for (var t = 0; t < states.length; t++) {
    logprobs[t * vocabSize + states[t]] = -0.01;
  }
  return AcousticEvidence(
    logprobs: logprobs,
    timeSteps: states.length,
    vocabSize: vocabSize,
    blankId: blankId,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BroadcastQuranLibrary library;
  late QuranMatchService service;

  setUpAll(() async {
    library = await BroadcastQuranLibrary.load();
    service = QuranMatchService(library: library);
  });

  Future<BroadcastFragment> transcribeTokens(List<int> target) async {
    final evidence = _evidenceFor(
      target,
      blankId: library.blankId,
      vocabSize: library.blankId + 1,
    );
    final transcriber = BroadcastTranscriber(
      runner: _ScriptedRunner(evidence),
      decoder: TextCtcDecoder(library.vocab, blankId: library.blankId),
      vocab: library.vocab,
    );
    // 3 秒均匀非静音 → 声学分段得到单段。
    final samples = Float32List(3 * 16000)..fillRange(0, 3 * 16000, 0.1);
    return transcriber.transcribe(samples);
  }

  Future<BroadcastMatchOutcome> matchTokens(List<int> target) async =>
      service.match(await transcribeTokens(target));

  List<int> tokensOf(int surah, int ayahStart, int ayahEnd) =>
      library.tokensFor(surah, ayahStart, ayahEnd)!;

  group('新库匹配：正样本', () {
    test('整节 112:1 被确认为完整节', () async {
      final outcome = await matchTokens(tokensOf(112, 1, 1));
      expect(outcome.status, MatchStatus.confirmed);
      expect(outcome.scope, RecordScope.completeVerses);
      expect(outcome.matches, hasLength(1));
      expect(outcome.matches.single.ref, '112:1');
      expect(outcome.matches.single.isWholeVerse, isTrue);
      expect(outcome.metrics.f1, isNotNull);
      expect(outcome.metrics.f1!, greaterThan(0.9));
      expect(outcome.metrics.strictWer, isNotNull);
    });

    test('跨节连读保留多个引用，不只显示首节', () async {
      final outcome = await matchTokens(tokensOf(112, 1, 2));
      expect(outcome.matches.length, 2);
      expect(<String>[for (final match in outcome.matches) match.ref], <String>['112:1', '112:2']);
      expect(outcome.scope, RecordScope.completeVerses);
      expect(outcome.status, MatchStatus.confirmed);
    });

    test('只念到某节的一部分时判为部分覆盖，不补全未听到内容', () async {
      final full = tokensOf(112, 1, 1);
      // 去掉尾部的正文词，只保留到「قل هو」。
      final partial = full.sublist(0, full.length - 3);
      final outcome = await matchTokens(partial);
      expect(
        outcome.status,
        MatchStatus.partial,
        reason: 'candidate=${outcome.candidateRef} scope=${outcome.scope} '
            'matches=${<String>[for (final match in outcome.matches) match.label]} '
            'recall=${outcome.metrics.recall} precision=${outcome.metrics.precision} '
            'asr=${outcome.asrText}',
      );
      expect(outcome.scope, RecordScope.partialVerse);
      expect(outcome.matches.single.isWholeVerse, isFalse);
      expect(outcome.matches.single.label, contains('词'));
    });

    test('67:1 的章首太斯米被视为该节内容的一部分，而不是额外一节', () async {
      final outcome = await matchTokens(tokensOf(67, 1, 1));
      expect(outcome.matches, hasLength(1));
      expect(outcome.matches.single.ref, '67:1');
      expect(outcome.matches.single.ordinal, 0);
    });
  });

  group('新库匹配：必须拒识的场景', () {
    test('只识别到章首太斯米时不确认章节', () async {
      final outcome = await matchTokens(<int>[351, 7, 59, 982, 986]);
      expect(outcome.status, MatchStatus.unmatched);
      expect(outcome.matches, isEmpty);
      expect(outcome.asrText.isNotEmpty, isTrue, reason: '拒识也必须保留真实转写');
      expect(outcome.rejectionReason, contains('太斯米'));
    });

    test('库外内容不返回最相似经文（不回退旧库）', () async {
      // 用词表中存在、但三章经文中几乎不出现的常见词拼出「普通讲话」。
      final filler = <int>[19, 21, 30, 43];
      final outcome = await matchTokens(filler);
      expect(outcome.status, MatchStatus.unmatched);
      expect(outcome.matches, isEmpty);
      expect(outcome.metrics.f1, isNull, reason: '没有可信参考时指标必须为 null');
    });

    test('纯噪声（无声学内容）不产生伪句', () async {
      final evidence = _evidenceFor(
        const <int>[],
        blankId: library.blankId,
        vocabSize: library.blankId + 1,
      );
      final transcriber = BroadcastTranscriber(
        runner: _ScriptedRunner(evidence),
        decoder: TextCtcDecoder(library.vocab, blankId: library.blankId),
        vocab: library.vocab,
      );
      final samples = Float32List(3 * 16000)..fillRange(0, 3 * 16000, 0.1);
      final fragment = await transcriber.transcribe(samples);
      expect(fragment.words, isEmpty);
      final outcome = service.match(fragment);
      expect(outcome.status, MatchStatus.unmatched);
      expect(outcome.needsTranslation, isFalse);
    });
  });

  group('诊断与来源字段', () {
    test('诊断证据包含候选与分数，且可序列化', () async {
      final outcome = await matchTokens(tokensOf(112, 1, 1));
      expect(outcome.candidateRef, isNotNull);
      expect(outcome.candidateTextScore, isNotNull);
      expect(outcome.candidateAcousticScore, isNotNull);
      expect(outcome.evidenceJson, contains('"status"'));
      expect(outcome.evidenceJson, contains('candidateRef'));
    });

    test('逐词对照以 JSON 快照保存，供详情页离线复现', () async {
      final outcome = await matchTokens(tokensOf(112, 1, 1));
      final json = outcome.metrics.alignmentJson;
      expect(json, isNotNull);
      expect(json, contains('"status"'));
      expect(json, contains('"reference"'));
      expect(json, contains('"hypothesis"'));
    });
  });
}
