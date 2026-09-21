import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:quran_offline_demo/broadcast/application/broadcast_session_controller.dart';
import 'package:quran_offline_demo/broadcast/application/broadcast_transcriber.dart';
import 'package:quran_offline_demo/broadcast/application/microphone_source.dart';
import 'package:quran_offline_demo/broadcast/application/quran_match_service.dart';
import 'package:quran_offline_demo/broadcast/application/translation_coordinator.dart';
import 'package:quran_offline_demo/broadcast/data/app_database.dart';
import 'package:quran_offline_demo/broadcast/data/broadcast_corpus.dart';
import 'package:quran_offline_demo/broadcast/data/record_repository.dart';
import 'package:quran_offline_demo/broadcast/domain/utterance_record.dart';
import 'package:quran_offline_demo/broadcast/translation/offline_translation_engine.dart';
import 'package:quran_offline_demo/quran_offline/ctc_decoder.dart';
import 'package:quran_offline_demo/quran_offline/ctc_scorer.dart';
import 'package:quran_offline_demo/quran_offline/ort_runner.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 脚本化推理桥。
class _FixedRunner implements OrtRunner {
  _FixedRunner(this.evidence);
  final AcousticEvidence evidence;
  int runCount = 0;

  @override
  Future<void> loadModel(String modelPath) async {}

  @override
  Future<AcousticEvidence> run(Float32List samples) async {
    runCount++;
    return evidence;
  }

  @override
  Future<void> dispose() async {}
}

/// 可控音源。
class _FakeAudio implements AudioCaptureSource {
  // 用 broadcast：未订阅时 close 也不能挂起（否则「未授权」用例的 tearDown 会超时）。
  final StreamController<Float32List> controller = StreamController<Float32List>.broadcast();
  bool permissionGranted = true;
  int startCount = 0;
  bool stopped = false;

  @override
  Future<bool> ensurePermission({bool request = true}) async => permissionGranted;

  @override
  Future<Stream<Float32List>> start() async {
    startCount++;
    return controller.stream;
  }

  @override
  Future<void> stop() async {
    stopped = true;
  }
}

/// 恒定成功的翻译引擎（不依赖平台通道）。
class _StubEngine implements OfflineTranslationEngine {
  @override
  String get engineId => 'stub/1';

  @override
  int get generation => 1;

  @override
  Future<TranslationEngineStatus> statusFor(TargetLanguage target) async =>
      TranslationEngineStatus.ready;

  @override
  Future<TranslationEngineStatus> prepare({
    required TargetLanguage target,
    bool allowDownload = true,
  }) async => TranslationEngineStatus.ready;

  @override
  Future<TranslationResult> translate(TranslationRequest request) async => TranslationResult(
    text: '译文',
    provider: 'stub',
    engineId: 'stub/1',
    elapsedMs: 1,
  );

  @override
  Future<void> close() async {}
}

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

Float32List _speech(double seconds, {double amplitude = 0.2}) {
  final samples = Float32List((seconds * 16000).round());
  for (var index = 0; index < samples.length; index++) {
    samples[index] = amplitude * (index.isEven ? 1 : -1);
  }
  return samples;
}

Float32List _silence(double seconds) => Float32List((seconds * 16000).round())
  ..fillRange(0, (seconds * 16000).round(), 0.0001);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  late BroadcastDatabase database;
  late RecordRepository records;
  late BroadcastQuranLibrary library;
  late _FakeAudio audio;

  setUp(() async {
    database = await BroadcastDatabase.open(
      path: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    records = RecordRepository(database.db);
    library = await BroadcastQuranLibrary.load();
    audio = _FakeAudio();
  });

  tearDown(() async {
    await audio.controller.close();
    await database.close();
  });

  BroadcastSessionController buildController({List<int>? targetTokens}) {
    final evidence = _evidenceFor(
      targetTokens ?? library.tokensFor(112, 1, 1)!,
      blankId: library.blankId,
      vocabSize: library.blankId + 1,
    );
    final transcriber = BroadcastTranscriber(
      runner: _FixedRunner(evidence),
      decoder: TextCtcDecoder(library.vocab, blankId: library.blankId),
      vocab: library.vocab,
    );
    return BroadcastSessionController(
      transcriber: transcriber,
      matcher: QuranMatchService(library: library),
      records: records,
      translations: TranslationCoordinator(
        engine: _StubEngine(),
        records: records,
        library: library,
      ),
      audio: audio,
      library: library,
    );
  }

  /// 等待异步链路推进。
  ///
  /// 取 250ms 而不是刚好够用的较短值：`flutter test` 并发跑多个测试文件时，
  /// 固定等待过短会偶发失败（实测 120ms 在负载高时会漏掉一次推理 + 落库）。
  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 250));

  group('会话生命周期', () {
    test('未授权麦克风时明确提示且不进入识别状态', () async {
      audio.permissionGranted = false;
      final controller = buildController();
      expect(await controller.start(), isFalse);
      expect(controller.isRunning, isFalse);
      expect(controller.statusMessage, contains('麦克风权限'));
      controller.dispose();
    });

    test('重复开始是幂等的，不会打开第二个音源', () async {
      final controller = buildController();
      expect(await controller.start(), isTrue);
      expect(await controller.start(), isTrue);
      expect(audio.startCount, 1);
      await controller.stop();
      controller.dispose();
    });

    test('识别中禁止切换目标语言，避免一句中途混语言', () async {
      final controller = buildController();
      expect(controller.updateTargetLanguage(TargetLanguage.english), isTrue);
      await controller.start();
      expect(controller.updateTargetLanguage(TargetLanguage.simplifiedChinese), isFalse);
      await controller.stop();
      controller.dispose();
    });

    test('快速开始停止不抛异常，且音源被关闭', () async {
      final controller = buildController();
      await controller.start();
      await controller.stop();
      await controller.stop();
      expect(controller.isRunning, isFalse);
      expect(audio.stopped, isTrue);
      controller.dispose();
    });
  });

  group('断句与落库', () {
    test('识别中未命中库内经文时不翻译转写，预览译文只跟随匹配经文', () async {
      // 场景来自真机实测：诵读者先念求护词（库外内容），旧逻辑会跟着转写翻译，
      // 得到与经文无关且不断跳动的译文。
      final controller = buildController(targetTokens: <int>[19, 21, 30, 43]);
      await controller.start();
      audio.controller.add(_speech(3));
      await settle();
      await settle();

      final preview = controller.preview;
      expect(preview, isNotNull);
      expect(preview!.outcome.matches, isEmpty, reason: '库外内容应无候选');
      expect(preview.translationText, isNull, reason: '预览译文只跟随匹配经文，不得翻译转写');
      expect(preview.translationPending, isFalse);
      await controller.stop();
      controller.dispose();
    });

    test('识别中三栏预览同步：候选经文与预览译文在片段进行中出现，终稿后清空', () async {
      final controller = buildController();
      await controller.start();
      // 3 秒连续语音（无停顿、不触发终稿）→ 满足预览条件（≥2s）。
      audio.controller.add(_speech(3));
      await settle();
      await settle();

      var preview = controller.preview;
      expect(preview, isNotNull, reason: '识别中应有三栏预览，而不是只有转写草稿');
      expect(preview!.draftText, isNotEmpty);
      expect(preview.outcome.matches, isNotEmpty, reason: '匹配经文栏应与草稿同步显示候选');
      expect(preview.outcome.matches.single.ref, '112:1');
      expect(await records.count(), 0, reason: '预览候选不得落库');

      // 再喂 2.5 秒：满足预览间隔（2s），候选连续第二次相同 → 生成预览译文。
      audio.controller.add(_speech(2.5));
      await settle();
      await settle();
      preview = controller.preview;
      expect(preview, isNotNull);
      expect(preview!.translationText, '译文', reason: '候选稳定后应出现预览译文');
      expect(preview.translationSource, contains('预览'));

      // 静音 1.5 秒触发终稿：预览清空，三栏切换为已确认记录。
      audio.controller.add(_silence(1.5));
      await settle();
      await settle();
      expect(controller.preview, isNull, reason: '终稿确认后应清空预览');
      final record = (await records.page()).single;
      expect(record.matches.single.ref, '112:1');
      expect(record.translationFor(TargetLanguage.simplifiedChinese)?.text, '译文');
      await controller.stop();
      controller.dispose();
    });

    test('自然停顿产生一条记录，三类文本各自快照', () async {
      final controller = buildController();
      await controller.start();
      audio.controller.add(_speech(1.2));
      await settle();
      audio.controller.add(_silence(1.5));
      await settle();
      await settle();

      expect(await records.count(), 1);
      final record = (await records.page()).single;
      expect(record.rawAsrText, isNotEmpty, reason: '必须保存实际 ASR 转写');
      expect(record.matchStatus, MatchStatus.confirmed);
      expect(record.matches.single.ref, '112:1');
      expect(record.matches.single.canonicalTextSnapshot, isNotEmpty);
      expect(record.metrics?.f1, isNotNull);
      expect(record.translationFor(TargetLanguage.simplifiedChinese)?.text, '译文');
      expect(record.targetLanguage, TargetLanguage.simplifiedChinese);
      await controller.stop();
      controller.dispose();
    });

    test('停止时最后一句不会丢', () async {
      final controller = buildController();
      await controller.start();
      audio.controller.add(_speech(1.2));
      await settle();
      // 不给静音，直接停止。
      await controller.stop();
      expect(await records.count(), 1);
      controller.dispose();
    });

    test('纯噪声不产生伪句与伪经文', () async {
      final controller = buildController();
      await controller.start();
      audio.controller.add(_silence(3));
      await settle();
      await controller.stop();
      expect(await records.count(), 0);
      controller.dispose();
    });

    test('同一音频位置反复回调只落一条记录（幂等键）', () async {
      final controller = buildController();
      await controller.start();
      for (var round = 0; round < 3; round++) {
        audio.controller.add(_speech(1.2));
        await settle();
        audio.controller.add(_silence(1.5));
        await settle();
      }
      await controller.stop();
      // 三轮音频的位置不同，因此是三条合法记录，但每条都只落一次。
      final page = await records.page();
      final keys = <String>[for (final record in page) '${record.startSample}-${record.endSample}'];
      expect(keys.toSet(), hasLength(keys.length), reason: '不允许出现重复保存的同一片段');
      controller.dispose();
    });

    test('库外内容保存为未匹配，原文与指标为不可用', () async {
      // 用普通讲话的 token（新库几乎不出现）驱动同一段音频。
      final controller = buildController(targetTokens: <int>[19, 21, 30, 43]);
      await controller.start();
      audio.controller.add(_speech(1.2));
      await settle();
      audio.controller.add(_silence(1.5));
      await settle();
      await settle();

      final record = (await records.page()).single;
      expect(record.matchStatus, MatchStatus.unmatched);
      expect(record.matches, isEmpty);
      expect(record.metrics!.f1, isNull);
      expect(record.translationFor(TargetLanguage.simplifiedChinese), isNotNull,
          reason: '未匹配也要给出真实机器翻译，并标明来自转写');
      await controller.stop();
      controller.dispose();
    });
  });
}
