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

    test('长转写匹配到多节跨度，而不是被极短节抢走', () async {
      // 真机实测动机：念王权章连续多节时（转写 25 词），终稿只匹配到 7 词的单节
      // （67:14，F1 0.438）。原因是候选裁决只在 CTC 精排前 12 个候选里选，
      // 而短节因为按帧归一化的分数更优占满该窗口，真正的多节跨度候选进不来。
      final outcome = await matchTokens(tokensOf(67, 14, 17));
      expect(outcome.matches.length, greaterThan(1), reason: '长转写应匹配到多节跨度');
      expect(outcome.matches.first.ref, '67:14');
      expect(outcome.coverage, greaterThan(0.8));
      expect(outcome.precision, greaterThan(0.8));
    });

    test('长转写混入库外词时仍应选多节跨度，而不是退回极短节', () async {
      // 更贴近真机：转写含库外词（章前求护词一类），内容跨王权章多节。
      final tags = <int>[1015, 1020, 1022, 1023];
      final tokens = <int>[...tokensOf(67, 14, 17), ...tags];
      final outcome = await matchTokens(tokens);
      expect(outcome.matches.length, greaterThan(1), reason: '不应退回单节');
      expect(outcome.matches.first.ref, '67:14');
      expect(outcome.precision, greaterThan(0.7));
      expect(outcome.status, isNot(MatchStatus.unmatched));
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

    test('解释比例偏低但覆盖率足够时展示候选经文，而不是清空为未匹配', () async {
      // 真机实测动机：诵读者念某节时转写里混入库外词，解释比例掉到门槛以下，
      // 但该节本身被完整覆盖。旧逻辑直接判未匹配并清空经文栏，用户看到大量
      // 「未匹配」，而内容其实在库里。
      final tokens = <int>[
        ...tokensOf(112, 1, 1),
        // 库外词（词表内，但在语料库中匹配不到）：制造「转写多出词」的局面。
        1015, 1020, 1022, 1023, 1015, 1020, 1022, 1023,
      ];
      final outcome = await matchTokens(tokens);
      expect(outcome.status, MatchStatus.candidate);
      expect(outcome.matches, isNotEmpty, reason: '有覆盖率支撑时应展示候选经文');
      expect(outcome.matches.single.ref, '112:1');
      expect(outcome.matches.single.isWholeVerse, isTrue);
      expect(outcome.rejectionReason, contains('候选未确认'));
      expect(outcome.precision, lessThan(0.6));
      expect(outcome.coverage, greaterThanOrEqualTo(0.9));
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
      // 用词表中存在、但在语料库中几乎不出现的常见词拼出「普通讲话」。
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
