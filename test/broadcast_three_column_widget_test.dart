/// 首页三栏的同帧与版本一致性回归（widget 层）。
///
/// 这里补的是控制器单测覆盖不到的一层：**同一帧里三张卡片是否来自同一份快照**。
/// 控制器保证 `(sessionEpoch, revision, candidateGeneration)` 正确，但真正决定用户
/// 看到什么的是 [BroadcastHomePage] 的一次 build：
///
/// | 关注的风险 | 对应用例 |
/// |---|---|
/// | 三栏分别读不同预览轮次（新转写配旧经文） | «三栏在同一帧读取同一份预览版本» |
/// | 候选切换后旧候选的迟到译文被显示出来 | «候选切换后不显示上一候选的迟到译文» |
/// | 未匹配时仍沿用上一次的经文或翻译波动转写 | «未匹配预览不显示旧经文，也不翻译波动转写» |
/// | 终稿替换预览后来源标签没跟上 | «终稿到来后三栏切换为已确认记录与来源标签» |
///
/// 依赖注入：[BroadcastServices.bootstrap] 支持注入推理桥、音源、翻译引擎、匹配器、
/// 译本仓储与内存数据库，因此这里跑的是**真实的**首页、控制器与仓储，不是替身 UI。
///
/// 时序说明：`testWidgets` 运行在 `FakeAsync` 区域，而 sqlite 与资产读取是真实异步，
/// 单独 `await` 会挂起，因此重 IO 一律走 [WidgetTester.runAsync]，界面帧用 `pump`，
/// 两者在 [_advance] 里交替推进。
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quran_broadcast_sdk/broadcast/application/broadcast_transcriber.dart';
import 'package:quran_broadcast_sdk/broadcast/application/microphone_source.dart';
import 'package:quran_broadcast_sdk/broadcast/application/quran_match_service.dart';
import 'package:quran_broadcast_sdk/broadcast/broadcast_services.dart';
import 'package:quran_broadcast_sdk/broadcast/data/app_database.dart';
import 'package:quran_broadcast_sdk/broadcast/data/broadcast_corpus.dart';
import 'package:quran_broadcast_sdk/broadcast/domain/utterance_record.dart';
import 'package:quran_broadcast_sdk/broadcast/translation/offline_translation_engine.dart';
import 'package:quran_broadcast_sdk/broadcast/translation/verse_translation_repository.dart';
import 'package:quran_broadcast_sdk/broadcast/ui/broadcast_home_page.dart';
import 'package:quran_broadcast_sdk/quran_offline/ctc_scorer.dart';
import 'package:quran_broadcast_sdk/quran_offline/ort_runner.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/quran_test_fixtures.dart';

/// 返回固定声学证据的推理桥（不依赖 ONNX 资产与平台通道）。
class _FakeRunner implements OrtRunner {
  _FakeRunner(this.evidence);

  /// 每次推理都返回这份证据。
  final AcousticEvidence evidence;

  @override
  Future<void> loadModel(String modelPath) async {}

  @override
  Future<AcousticEvidence> run(Float32List samples) async => evidence;

  @override
  Future<void> dispose() async {}
}

/// 脚本化音源：由测试显式喂入音频。
class _ScriptedAudio implements AudioCaptureSource {
  /// 音频分块的广播流；未订阅时关闭不会挂起。
  final StreamController<Float32List> chunks =
      StreamController<Float32List>.broadcast();

  @override
  Future<bool> ensurePermission({bool request = true}) async => true;

  @override
  Future<Stream<Float32List>> start() async => chunks.stream;

  @override
  Future<void> stop() async {}
}

/// 按调用次数返回可区分译文的翻译引擎。
///
/// 译文文本带序号，A→B 的迟到译文才能在界面上被明确区分出来。
/// [firstCallGate] 让第一次翻译停在「在途」状态，用于构造候选切换的时序。
class _StubEngine implements OfflineTranslationEngine {
  _StubEngine({this.firstCallGate});

  /// 第一次翻译的闸门。
  final Completer<void>? firstCallGate;

  /// 已调用次数。
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
    final serial = calls;
    if (serial == 1) await firstCallGate?.future;
    // 译文里带上被译的标准原文：这样「界面对应的候选」可以被直接判定，
    // 而不依赖调用序号，避免脚本与预览轮次错位的脆弱断言。
    return TranslationResult(
      text: '译文·${request.inputText}',
      provider: 'stub',
      engineId: 'stub/1',
      elapsedMs: 1,
    );
  }

  @override
  Future<void> close() async {}
}

/// 按脚本返回候选的匹配器；脚本用尽后保持最后一项，null 表示未匹配。
class _ScriptedMatcher extends QuranMatchService {
  _ScriptedMatcher(BroadcastQuranLibrary library, this.script)
    : super(library: library);

  /// 每次 [match] 返回的候选；null 代表「库内无候选」。
  final List<(int, int)?> script;

  /// 已调用次数。
  int calls = 0;

  @override
  BroadcastMatchOutcome match(BroadcastFragment fragment) {
    final entry = script[calls < script.length ? calls : script.length - 1];
    calls++;
    if (entry == null) {
      return BroadcastMatchOutcome(
        asrText: fragment.text,
        status: MatchStatus.unmatched,
        scope: RecordScope.unknown,
        matches: const <MatchedVerse>[],
        metrics: RecordMetrics.unavailable(
          metricScope: 'none',
          normalizationVersion: QuranMatchService.normalizationVersion,
        ),
        rejectionReason: '测试用例注入：库内没有候选',
      );
    }
    final (surah, ayah) = entry;
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

/// 交替推进「界面帧」与「真实异步」，直到 [future] 完成或轮次耗尽。
///
/// @param tester 当前测试驱动
/// @param future 正在等待的任务；为 null 时只做固定轮次推进
/// @param rounds 最大轮次
Future<void> _advance(
  WidgetTester tester, {
  Future<void>? future,
  int rounds = 20,
}) async {
  var done = false;
  unawaited(future?.then((_) => done = true));
  for (var index = 0; index < rounds; index++) {
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    if (future != null && done) return;
  }
  await future;
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
  sqfliteFfiInit();

  late BroadcastQuranLibrary library;
  late _ScriptedAudio audio;

  /// 组装真实服务：不加载模型，数据库与语料走可注入实现。
  Future<BroadcastServices> bootstrap(
    WidgetTester tester, {
    required QuranMatchService matcher,
    required OfflineTranslationEngine engine,
  }) async {
    final database = await tester.runAsync(
      () => BroadcastDatabase.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      ),
    ) as BroadcastDatabase;
    final services = await tester.runAsync(
      () => BroadcastServices.bootstrap(
        loadModel: false,
        runner: _FakeRunner(
          buildAlignedEvidence(<int>[FixtureTokens.bism, FixtureTokens.allah]),
        ),
        audio: audio,
        engine: engine,
        database: database,
        matcher: matcher,
        // 关掉权威译本：让译文确定性地走机器翻译分支，才能区分两次调用的译文。
        editions: const NoCuratedEditionRepository(),
      ),
    ) as BroadcastServices;
    return services;
  }

  Future<void> mountHome(WidgetTester tester, BroadcastServices services) async {
    await tester.pumpWidget(
      MaterialApp(home: BroadcastHomePage(services: services)),
    );
    await tester.pump();
    await _advance(tester, rounds: 3);
  }

  /// 收尾：停止识别并释放资源。
  ///
  /// 这里刻意**不等待** `stop`/`dispose` 完成：它们内部还有 sqlite 与资产 IO，
  /// 在 `FakeAsync` 区域里单独 `await` 会挂起。用例只校验界面快照，收尾是否有
  /// 残留不影响断言，因此仅推进若干帧与一小段真实时钟。
  Future<void> finish(WidgetTester tester, BroadcastServices services) async {
    unawaited(services.session.stop());
    await _advance(tester, rounds: 30);
    unawaited(services.dispose());
    await _advance(tester, rounds: 5);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
  }

  setUp(() async {
    // 资产读取是真实 IO：必须在 setUp 里完成，FakeAsync 区域内会挂起。
    library = await BroadcastQuranLibrary.load();
    audio = _ScriptedAudio();
  });

  tearDown(() async {
    await audio.chunks.close();
  });

  testWidgets('三栏在同一帧读取同一份预览版本', (WidgetTester tester) async {
    final matcher = _ScriptedMatcher(library, <(int, int)?>[(112, 1), (112, 1)]);
    final engine = _StubEngine();
    final services = await bootstrap(tester, matcher: matcher, engine: engine);
    await mountHome(tester, services);

    await _advance(tester, future: services.session.start(), rounds: 10);
    audio.chunks.add(_speech(3));
    await _advance(tester, rounds: 20);
    audio.chunks.add(_speech(2.5));
    await _advance(tester, rounds: 30);

    final preview = services.session.preview;
    expect(preview, isNotNull, reason: '识别中应出现三栏预览');
    expect(preview!.translationText, isNotNull, reason: '候选稳定后应出现预览译文');

    // 同一帧：转写栏、经文栏、译文栏引用同一个窗口编号（允许多个 Text 出现同一编号）。
    expect(find.textContaining('窗口草稿 #${preview.revision}'), findsWidgets);
    expect(find.textContaining('窗口 #${preview.revision}'), findsWidgets);
    // 关键在于**没有别的修订号**：若三栏各自读新一轮预览，这里会同时出现多个编号。
    expect(
      find.textContaining('窗口 #${preview.revision - 1}'),
      findsNothing,
      reason: '同一帧不得混出现更早的预览修订',
    );
    expect(
      find.textContaining('窗口 #${preview.revision + 1}'),
      findsNothing,
      reason: '同一帧不得混出现更新的预览修订',
    );
    expect(find.text(preview.translationText!), findsWidgets);

    await finish(tester, services);
  });

  testWidgets('候选切换后不显示上一候选的迟到译文', (WidgetTester tester) async {
    final gate = Completer<void>();
    final matcher = _ScriptedMatcher(library, <(int, int)?>[
      (112, 1),
      (112, 1),
      (67, 2),
      (67, 2),
      (67, 2),
    ]);
    final engine = _StubEngine(firstCallGate: gate);
    final services = await bootstrap(tester, matcher: matcher, engine: engine);
    await mountHome(tester, services);

    await _advance(tester, future: services.session.start(), rounds: 10);
    for (var round = 0; round < 4; round++) {
      audio.chunks.add(_speech(round == 0 ? 3 : 1.5));
      await _advance(tester, rounds: 20);
    }
    final ayah112Text = library.verse(112, 1)!.textUthmani;
    final ayah67Text = library.verse(67, 2)!.textUthmani;
    expect(services.session.preview?.outcome.matches.single.ref, '67:2');
    expect(
      find.text('译文·$ayah112Text'),
      findsNothing,
      reason: '切换候选后不得再出现旧候选的译文',
    );

    gate.complete();
    audio.chunks.add(_speech(1.5));
    await _advance(tester, rounds: 50);

    // A 的在途译文返回时候选已是 B：必须丢弃 A，并继续为 B 生成译文。
    expect(services.session.preview?.outcome.matches.single.ref, '67:2');
    expect(services.session.preview?.translationText, '译文·$ayah67Text');
    expect(
      find.text('译文·$ayah112Text'),
      findsNothing,
      reason: '迟到译文不得回写到新候选上',
    );
    expect(find.text('译文·$ayah67Text'), findsWidgets);
    expect(
      find.text(library.verse(67, 2)!.textUthmani),
      findsWidgets,
      reason: '经文栏显示当前候选的标准原文',
    );
    expect(
      find.text(library.verse(112, 1)!.textUthmani),
      findsNothing,
      reason: '旧候选的标准原文不得留在界面上',
    );

    await finish(tester, services);
  });

  testWidgets('未匹配预览不显示旧经文，也不翻译波动转写', (WidgetTester tester) async {
    final matcher = _ScriptedMatcher(library, <(int, int)?>[null, null, null]);
    final engine = _StubEngine();
    final services = await bootstrap(tester, matcher: matcher, engine: engine);
    await mountHome(tester, services);

    await _advance(tester, future: services.session.start(), rounds: 10);
    audio.chunks.add(_speech(3));
    await _advance(tester, rounds: 20);
    audio.chunks.add(_speech(2.5));
    await _advance(tester, rounds: 20);

    expect(services.session.preview?.outcome.matches, isEmpty);
    expect(engine.calls, 0, reason: '未匹配预览不得翻译波动的转写');
    expect(find.textContaining('等待匹配经文'), findsOneWidget);
    expect(
      find.text(library.verse(112, 1)!.textUthmani),
      findsNothing,
      reason: '未匹配时不得显示任何标准原文（含上一次命中的经文）',
    );

    await finish(tester, services);
  });

  testWidgets('终稿到来后三栏切换为已确认记录与来源标签', (WidgetTester tester) async {
    final matcher = _ScriptedMatcher(library, <(int, int)?>[(112, 1), (112, 1)]);
    final engine = _StubEngine();
    final services = await bootstrap(tester, matcher: matcher, engine: engine);
    await mountHome(tester, services);

    await _advance(tester, future: services.session.start(), rounds: 10);
    audio.chunks.add(_speech(1.2));
    await _advance(tester, rounds: 20);
    audio.chunks.add(_silence(1.5));
    await _advance(tester, rounds: 40);

    expect(services.session.preview, isNull, reason: '终稿确认后预览必须清空');
    final page = await tester.runAsync(
      () => services.records.page(),
    ) as List<UtteranceRecord>;
    expect(page, hasLength(1));
    final record = page.single;
    expect(record.matches.single.ref, '112:1');

    // 终稿替换预览：三栏转为已确认记录，译文带来源标签而不是裸文本。
    expect(find.textContaining('已确认'), findsWidgets);
    expect(find.textContaining('窗口 #'), findsNothing, reason: '终稿界面不得再显示预览窗口编号');
    final translation = record.translationFor(services.session.targetLanguage);
    expect(translation, isNotNull, reason: '终稿必须有正式译文');
    expect(find.text(translation!.text), findsWidgets);
    expect(find.text(translation.sourceKind.label), findsWidgets);

    await finish(tester, services);
  });
}
