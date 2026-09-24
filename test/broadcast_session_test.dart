import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quran_broadcast_sdk/broadcast/application/broadcast_latency_trace.dart';
import 'package:quran_broadcast_sdk/broadcast/application/broadcast_session_controller.dart';
import 'package:quran_broadcast_sdk/broadcast/application/broadcast_transcriber.dart';
import 'package:quran_broadcast_sdk/broadcast/application/microphone_source.dart';
import 'package:quran_broadcast_sdk/broadcast/application/quran_match_service.dart';
import 'package:quran_broadcast_sdk/broadcast/application/screen_keep_on.dart';
import 'package:quran_broadcast_sdk/broadcast/application/translation_coordinator.dart';
import 'package:quran_broadcast_sdk/broadcast/application/utterance_segmenter.dart';
import 'package:quran_broadcast_sdk/broadcast/data/app_database.dart';
import 'package:quran_broadcast_sdk/broadcast/data/broadcast_corpus.dart';
import 'package:quran_broadcast_sdk/broadcast/data/record_repository.dart';
import 'package:quran_broadcast_sdk/broadcast/domain/utterance_record.dart';
import 'package:quran_broadcast_sdk/broadcast/translation/offline_translation_engine.dart';
import 'package:quran_broadcast_sdk/quran_offline/ctc_decoder.dart';
import 'package:quran_broadcast_sdk/quran_offline/ctc_scorer.dart';
import 'package:quran_broadcast_sdk/quran_offline/ort_runner.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _GatedCacheRepository extends RecordRepository {
  _GatedCacheRepository(super.db, this.writeGate);

  final Completer<void> writeGate;
  final Completer<void> writeStarted = Completer<void>();

  @override
  Future<void> writeCache(
    String cacheKey,
    String text, {
    required String provider,
    required TranslationSourceKind sourceKind,
    String? engineId,
  }) async {
    if (!writeStarted.isCompleted) writeStarted.complete();
    await writeGate.future;
    await super.writeCache(
      cacheKey,
      text,
      provider: provider,
      sourceKind: sourceKind,
      engineId: engineId,
    );
  }
}

/// 脚本化推理桥。
class _FixedRunner implements OrtRunner {
  _FixedRunner(this.evidence, {this.firstRunGate});
  final AcousticEvidence evidence;
  final Completer<void>? firstRunGate;
  final Completer<void> firstRunStarted = Completer<void>();
  int runCount = 0;
  final List<int> inputLengths = <int>[];

  @override
  Future<void> loadModel(String modelPath) async {}

  @override
  Future<AcousticEvidence> run(Float32List samples) async {
    runCount++;
    inputLengths.add(samples.length);
    if (runCount == 1) {
      firstRunStarted.complete();
      await firstRunGate?.future;
    }
    return evidence;
  }

  @override
  Future<void> dispose() async {}
}

/// 可控音源。
class _FakeAudio implements AudioCaptureSource {
  // 用 broadcast：未订阅时 close 也不能挂起（否则「未授权」用例的 tearDown 会超时）。
  final StreamController<Float32List> controller =
      StreamController<Float32List>.broadcast();
  bool permissionGranted = true;
  Completer<void>? permissionGate;
  int startCount = 0;
  bool stopped = false;

  @override
  Future<bool> ensurePermission({bool request = true}) async {
    await permissionGate?.future;
    return permissionGranted;
  }

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
  _StubEngine({this.firstTranslationGate});

  final Completer<void>? firstTranslationGate;
  int calls = 0;

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
  Future<TranslationResult> translate(TranslationRequest request) async {
    calls++;
    if (calls == 1) await firstTranslationGate?.future;
    return TranslationResult(
      text: '译文',
      provider: 'stub',
      engineId: 'stub/1',
      elapsedMs: 1,
    );
  }

  @override
  Future<void> close() async {}
}

/// 只控制预览候选顺序，用于检验迟到译文和候选切换。
class _ScriptedMatcher extends QuranMatchService {
  _ScriptedMatcher(BroadcastQuranLibrary library, this.refs)
    : super(library: library);

  final List<(int, int)> refs;
  int calls = 0;

  @override
  BroadcastMatchOutcome match(BroadcastFragment fragment) {
    final (surah, ayah) = refs[calls < refs.length ? calls : refs.length - 1];
    calls++;
    final source = library.verse(surah, ayah)!;
    final match = MatchedVerse(
      ordinal: 0,
      surah: surah,
      ayah: ayah,
      wordStart: null,
      wordEnd: null,
      canonicalTextSnapshot: source.textUthmani,
      matchedTextSnapshot: source.textUthmani,
      corpusVersion: library.manifest.corpusVersion,
    );
    return BroadcastMatchOutcome(
      asrText: fragment.text,
      status: MatchStatus.confirmed,
      scope: RecordScope.completeVerses,
      matches: <MatchedVerse>[match],
      metrics: RecordMetrics.unavailable(
        metricScope: match.ref,
        normalizationVersion: QuranMatchService.normalizationVersion,
      ),
      candidateRef: match.ref,
    );
  }
}

AcousticEvidence _evidenceFor(
  List<int> target, {
  required int blankId,
  required int vocabSize,
}) {
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

Float32List _silence(double seconds) =>
    Float32List((seconds * 16000).round())
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

  BroadcastSessionController buildController({
    List<int>? targetTokens,
    _FixedRunner? runner,
    QuranMatchService? matcher,
    _StubEngine? engine,
    RecordRepository? repository,
    double previewWindowSeconds = 12,
    UtteranceSegmenterConfig segmenterConfig = const UtteranceSegmenterConfig(),
    BroadcastLatencyTrace? trace,
  }) {
    final evidence = _evidenceFor(
      targetTokens ?? library.tokensFor(112, 1, 1)!,
      blankId: library.blankId,
      vocabSize: library.blankId + 1,
    );
    final transcriber = BroadcastTranscriber(
      runner: runner ?? _FixedRunner(evidence),
      decoder: TextCtcDecoder(library.vocab, blankId: library.blankId),
      vocab: library.vocab,
    );
    return BroadcastSessionController(
      transcriber: transcriber,
      matcher: matcher ?? QuranMatchService(library: library),
      records: repository ?? records,
      translations: TranslationCoordinator(
        engine: engine ?? _StubEngine(),
        records: repository ?? records,
        library: library,
      ),
      audio: audio,
      library: library,
      previewWindowSeconds: previewWindowSeconds,
      segmenterConfig: segmenterConfig,
      trace: trace,
    );
  }

  /// 等待异步链路推进。
  ///
  /// 取 250ms 而不是刚好够用的较短值：`flutter test` 并发跑多个测试文件时，
  /// 固定等待过短会偶发失败（实测 120ms 在负载高时会漏掉一次推理 + 落库）。
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 250));

  group('会话生命周期', () {
    test('屏幕常亮只覆盖实际收音期间，停止后恢复', () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel(ScreenKeepOn.channelName);
      final values = <bool>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        values.add(
          (call.arguments as Map<Object?, Object?>)['enabled'] as bool,
        );
        return null;
      });
      try {
        final controller = buildController();
        expect(await controller.start(), isTrue);
        expect(await controller.start(), isTrue);
        expect(values, <bool>[true]);
        await controller.stop();
        expect(values, <bool>[true, false]);
        controller.dispose();
      } finally {
        messenger.setMockMethodCallHandler(channel, null);
      }
    });

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
      expect(controller.updateTargetLanguage(TargetLanguage.chinese), isFalse);
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
      final cleared = preview.copyWith(
        translationText: null,
        translationSource: null,
        translationSourceKind: null,
        translationInputScope: null,
      );
      expect(cleared.translationText, isNull, reason: '候选切换必须能真正清空旧译文');
      expect(cleared.translationSource, isNull);

      // 后续预览仍是相同候选时，已显示的译文不应在每轮刷新后闪退。
      audio.controller.add(_speech(1.5));
      await settle();
      await settle();
      preview = controller.preview;
      expect(preview?.translationText, '译文');

      // 静音 1.5 秒触发终稿：预览清空，三栏切换为已确认记录。
      audio.controller.add(_silence(1.5));
      await settle();
      await settle();
      expect(controller.preview, isNull, reason: '终稿确认后应清空预览');
      final record = (await records.page()).single;
      expect(record.matches.single.ref, '112:1');
      expect(record.translationFor(TargetLanguage.chinese)?.text, '译文');
      await controller.stop();
      controller.dispose();
    });

    test('长片段预览只推理最近 12 秒，终稿仍推理完整片段', () async {
      final evidence = _evidenceFor(
        library.tokensFor(112, 1, 1)!,
        blankId: library.blankId,
        vocabSize: library.blankId + 1,
      );
      final runner = _FixedRunner(evidence);
      final controller = buildController(runner: runner);
      await controller.start();
      audio.controller.add(_speech(15));
      await settle();
      await settle();
      final preview = controller.preview;
      expect(preview, isNotNull);
      expect(preview!.audioEndSample - preview.audioStartSample, 12 * 16000);
      expect(runner.inputLengths.first, 12 * 16000);
      audio.controller.add(_silence(1.5));
      await settle();
      await settle();
      expect(await records.count(), 1);
      expect(runner.inputLengths, contains(greaterThan(15 * 16000)));
      await controller.stop();
      controller.dispose();
    });

    test('最长时长强切后不会用重叠音频覆盖已确认三栏', () async {
      final controller = buildController(
        segmenterConfig: const UtteranceSegmenterConfig(
          maxSeconds: 3,
          overlapSeconds: 1,
        ),
      );
      await controller.start();
      audio.controller.add(_speech(3.1));
      await settle();
      await settle();
      expect(await records.count(), 1);
      expect(controller.preview, isNull, reason: '重叠音频本身不能构成新片段预览');
      audio.controller.add(_speech(1.1));
      await settle();
      expect(controller.preview, isNotNull, reason: '新音频到达后可恢复预览');
      await controller.shutdown();
    });

    test('预览推理途中完成断句，无后续音频也会处理终稿', () async {
      final evidence = _evidenceFor(
        library.tokensFor(112, 1, 1)!,
        blankId: library.blankId,
        vocabSize: library.blankId + 1,
      );
      final gate = Completer<void>();
      final runner = _FixedRunner(evidence, firstRunGate: gate);
      final controller = buildController(runner: runner);
      await controller.start();
      audio.controller.add(_speech(3));
      await runner.firstRunStarted.future;
      audio.controller.add(_silence(1.5));
      await settle();
      expect(await records.count(), 0);
      gate.complete();
      await settle();
      await settle();
      expect(await records.count(), 1, reason: '预览结束必须主动唤醒已排队终稿');
      expect(controller.preview, isNull);
      await controller.stop();
      controller.dispose();
    });

    test('关闭会话等待在途预览推理及末句落库', () async {
      final evidence = _evidenceFor(
        library.tokensFor(112, 1, 1)!,
        blankId: library.blankId,
        vocabSize: library.blankId + 1,
      );
      final gate = Completer<void>();
      final runner = _FixedRunner(evidence, firstRunGate: gate);
      final controller = buildController(runner: runner);
      await controller.start();
      audio.controller.add(_speech(1.2));
      await runner.firstRunStarted.future;
      var closed = false;
      final shutdown = controller.shutdown().then((_) => closed = true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(closed, isFalse);
      gate.complete();
      await shutdown;
      expect(closed, isTrue);
      expect(await records.count(), 1);
    });

    test('关闭会话等待在途译文完成', () async {
      final gate = Completer<void>();
      final engine = _StubEngine(firstTranslationGate: gate);
      final controller = buildController(engine: engine);
      await controller.start();
      audio.controller.add(_speech(3));
      await settle();
      audio.controller.add(_speech(2.5));
      await settle();
      expect(controller.preview?.translationPending, isTrue);
      await settle();
      expect(engine.calls, 1);
      var closed = false;
      final shutdown = controller.shutdown().then((_) => closed = true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(closed, isFalse);
      gate.complete();
      await shutdown;
      expect(closed, isTrue);
      expect(await records.count(), 1);
    });

    test('申请麦克风权限途中关闭，不会在释放后启动音源', () async {
      final gate = Completer<void>();
      audio.permissionGate = gate;
      final controller = buildController();
      final starting = controller.start();
      await controller.shutdown();
      gate.complete();
      expect(await starting, isFalse);
      expect(audio.startCount, 0);
    });

    test('旧候选译文在途时切换新候选，新候选仍会及时翻译', () async {
      final gate = Completer<void>();
      final engine = _StubEngine(firstTranslationGate: gate);
      final matcher = _ScriptedMatcher(library, <(int, int)>[
        (112, 1),
        (112, 1),
        (67, 2),
        (67, 2),
      ]);
      final controller = buildController(matcher: matcher, engine: engine);
      await controller.start();
      for (var i = 0; i < 4; i++) {
        audio.controller.add(_speech(i == 0 ? 3 : 1.5));
        await settle();
      }
      expect(matcher.calls, 4);
      expect(controller.preview?.outcome.matches.single.ref, '67:2');
      expect(controller.preview?.translationText, isNull);
      expect(engine.calls, 1, reason: '旧候选的机器翻译仍在执行');
      gate.complete();
      await settle();
      expect(engine.calls, 2, reason: '旧翻译结束后必须主动处理已稳定的新候选');
      expect(controller.preview?.outcome.matches.single.ref, '67:2');
      expect(controller.preview?.translationText, '译文');
      await controller.stop();
      controller.dispose();
    });

    test('A 译文在途且 B 候选稳定后关闭，会等待 A 的缓存写入', () async {
      final engineGate = Completer<void>();
      final cacheGate = Completer<void>();
      final repository = _GatedCacheRepository(database.db, cacheGate);
      final engine = _StubEngine(firstTranslationGate: engineGate);
      final matcher = _ScriptedMatcher(library, <(int, int)>[
        (112, 1),
        (112, 1),
        (67, 2),
        (67, 2),
      ]);
      final controller = buildController(
        matcher: matcher,
        engine: engine,
        repository: repository,
      );
      await controller.start();
      for (var i = 0; i < 4; i++) {
        audio.controller.add(_speech(i == 0 ? 3 : 1.5));
        await settle();
      }
      expect(controller.preview?.outcome.matches.single.ref, '67:2');
      expect(engine.calls, 1);
      // 清空待确认片段，隔离终稿任务对 shutdown 等待路径的影响。
      controller.startNewSession();
      var closed = false;
      final shutdown = controller.shutdown().then((_) => closed = true);
      engineGate.complete();
      await repository.writeStarted.future;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(closed, isFalse, reason: '原生引擎结束后仍须等待预览缓存写入');
      cacheGate.complete();
      await shutdown;
      expect(closed, isTrue);
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
      expect(record.translationFor(TargetLanguage.chinese)?.text, '译文');
      expect(record.targetLanguage, TargetLanguage.chinese);
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
      final keys = <String>[
        for (final record in page) '${record.startSample}-${record.endSample}',
      ];
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
      expect(
        record.translationFor(TargetLanguage.chinese),
        isNotNull,
        reason: '未匹配也要给出真实机器翻译，并标明来自转写',
      );
      await controller.stop();
      controller.dispose();
    });
  });

  group('端到端时延埋点', () {
    test('默认不注入记录器，收音路径不产生任何事件', () async {
      final controller = buildController();
      expect(controller.trace, isNull, reason: '默认必须关闭埋点，不改变生产路径');
      await controller.start();
      audio.controller.add(_speech(3));
      await settle();
      expect(controller.preview, isNotNull, reason: '关闭埋点不影响预览本身');
      await controller.stop();
      controller.dispose();
    });

    test('预览事件携带音频区间与候选代数，并能按修订号关联到 UI 帧', () async {
      final trace = BroadcastLatencyTrace();
      final controller = buildController(trace: trace);
      await controller.start();
      audio.controller.add(_speech(3));
      await settle();
      await settle();

      final preview = controller.preview!;
      controller.recordPreviewRendered(preview);

      final published = trace.ofKind(
        BroadcastLatencyEventKind.previewPublished,
      );
      final frames = trace.ofKind(BroadcastLatencyEventKind.previewFrame);
      expect(published, hasLength(1));
      expect(frames, hasLength(1));
      expect(
        published.single.revision,
        frames.single.revision,
        reason: '帧事件必须能按修订号回溯到对应预览',
      );
      expect(
        published.single.candidateGeneration,
        frames.single.candidateGeneration,
      );
      expect(published.single.audioStartSample, preview.audioStartSample);
      expect(published.single.audioEndSample, preview.audioEndSample);
      expect(published.single.candidateRef, '112:1');
      // 时间戳取自会话单调时钟，用于离线计算「音频进入 → UI 可见」。
      expect(published.single.audioReceivedAtUs, preview.audioReceivedAtUs);
      expect(
        frames.single.atUs >= published.single.atUs,
        isTrue,
        reason: 'UI 帧必然不早于预览发布',
      );
      await controller.stop();
      controller.dispose();
    });

    test('候选切换记录译文丢弃，迟到译文不产生任何译文帧事件', () async {
      final trace = BroadcastLatencyTrace();
      final gate = Completer<void>();
      final engine = _StubEngine(firstTranslationGate: gate);
      final matcher = _ScriptedMatcher(library, <(int, int)>[
        (112, 1),
        (112, 1),
        (67, 2),
        (67, 2),
      ]);
      final controller = buildController(
        matcher: matcher,
        engine: engine,
        trace: trace,
      );
      await controller.start();
      for (var i = 0; i < 4; i++) {
        audio.controller.add(_speech(i == 0 ? 3 : 1.5));
        await settle();
        final preview = controller.preview;
        if (preview != null) controller.recordPreviewRendered(preview);
      }
      gate.complete();
      await settle();
      await settle();

      expect(controller.preview?.translationText, '译文');
      final dropped = trace.ofKind(
        BroadcastLatencyEventKind.translationDropped,
      );
      expect(dropped, isNotEmpty, reason: '候选切换清掉旧译文必须留下记录，否则统计会漏掉被取消的样本');
      expect(dropped.any((event) => event.note == 'pending'), isTrue);

      // 旧候选 A 的译文没有单独产生发布/帧事件：只有最终生效的译文进入统计。
      final published = trace.ofKind(
        BroadcastLatencyEventKind.translationPublished,
      );
      for (final event in published) {
        expect(event.candidateRef, isNot('112:1'), reason: '迟到译文不得污染当前候选的时延统计');
      }
      final frames = trace.ofKind(BroadcastLatencyEventKind.translationFrame);
      for (final event in frames) {
        expect(event.candidateRef, isNot('112:1'));
      }
      // 候选切换使代数递增，A→B 不会共用同一代数，统计时不会互相顶替。
      final generations = controller.preview!.candidateGeneration;
      expect(generations, greaterThan(1));
      await controller.stop();
      controller.dispose();
    });

    test('终稿事件带片段真实采样区间，可按采样 cut 出同一段音频做离线复现', () async {
      final trace = BroadcastLatencyTrace();
      final controller = buildController(trace: trace);
      await controller.start();
      audio.controller.add(_speech(1.2));
      await settle();
      audio.controller.add(_silence(1.5));
      await settle();
      await settle();

      final finals = trace.ofKind(BroadcastLatencyEventKind.finalPublished);
      expect(finals, hasLength(1));
      final event = finals.single;
      final record = (await records.page()).single;
      expect(event.audioStartSample, record.startSample);
      expect(event.audioEndSample, record.endSample);
      expect(
        event.audioEndSample > event.audioStartSample,
        isTrue,
        reason: '必须能据此从 PCM 转储中裁出完全相同的音频',
      );
      expect(event.note, contains('silence'));
      await controller.stop();
      controller.dispose();
    });
  });
}
