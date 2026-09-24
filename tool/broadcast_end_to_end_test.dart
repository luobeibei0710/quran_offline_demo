/// 主机端到端验证：真实音频 → 离线转写 → 全经匹配 → 权威译本查表。
///
/// 用途：在没有真机的情况下，用**真实全经诵读音频**跑完整链路，产出可复现的
/// 「转写内容 / 匹配到哪一节 / 取了哪个译本 / 各阶段耗时」记录。整条链路与
/// 应用内完全一致：同一个 [BroadcastTranscriber]、同一个 [QuranMatchService]、
/// 同一个 [JsonVerseTranslationRepository]，不另写简化实现。
///
/// 注意这里**不查参考文本**：转写阶段完全不知道音频对应哪一节，匹配是否命中
/// 是链路自己算出来的结论，因此结果可以作为独立证据。
///
/// 运行方式（先启动 host ORT 服务）：
/// ```bash
/// tools/quran_offline/.venv122/bin/python tools/quran_offline/host_ort_server.py --port 18765 &
/// QURAN_ORT_URL=http://127.0.0.1:18765 \
/// QURAN_E2E_AUDIO_DIR=/tmp/e2e_wav \
/// QURAN_E2E_CASES=1,36,55,67,112 \
/// QURAN_E2E_OUT=/tmp/e2e.json \
/// flutter test tool/broadcast_end_to_end_test.dart
/// ```
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:quran_broadcast_sdk/broadcast/application/broadcast_transcriber.dart';
import 'package:quran_broadcast_sdk/broadcast/application/quran_match_service.dart';
import 'package:quran_broadcast_sdk/broadcast/data/broadcast_corpus.dart';
import 'package:quran_broadcast_sdk/broadcast/data/translation_catalog.dart';
import 'package:quran_broadcast_sdk/broadcast/domain/utterance_record.dart';
import 'package:quran_offline_demo/quran_offline/corpus_audio.dart';
import 'package:quran_broadcast_sdk/quran_offline/ctc_decoder.dart';

import 'stream_benchmark_test.dart' show FileAssetBundle, HttpOrtRunner;

/// 每个窗口的时长（秒）：贴近真机广播片段的长度。
const double _windowSeconds = 30;

/// 每个用例均匀采样的窗口数。
const int _windowsPerCase = 3;

const int _sampleRate = 16000;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'end-to-end: audio -> transcription -> full-Quran match -> translations',
    () async {
      final audioDir = Platform.environment['QURAN_E2E_AUDIO_DIR'];
      final outputPath = Platform.environment['QURAN_E2E_OUT'];
      if (audioDir == null || outputPath == null) {
        throw StateError('Set QURAN_E2E_AUDIO_DIR and QURAN_E2E_OUT.');
      }
      final cases = (Platform.environment['QURAN_E2E_CASES'] ?? '1,36,55,67,112')
          .split(',')
          .where((item) => item.trim().isNotEmpty)
          .map((item) => int.parse(item.trim()))
          .toList();
      final endpoint = Uri.parse(
        Platform.environment['QURAN_ORT_URL'] ?? 'http://127.0.0.1:8765',
      );

      await HttpOverrides.runWithHttpOverrides(() async {
        final library = await BroadcastQuranLibrary.load(
          bundle: FileAssetBundle(Directory.current),
        );
        final runner = HttpOrtRunner(endpoint: endpoint, blankId: library.blankId);
        final transcriber = BroadcastTranscriber(
          runner: runner,
          decoder: TextCtcDecoder(library.vocab, blankId: library.blankId),
          vocab: library.vocab,
          sampleRate: _sampleRate,
        );
        final matcher = QuranMatchService(library: library);
        final catalog = await BroadcastTranslationCatalog.load(
          bundle: FileAssetBundle(Directory.current),
        );
        final translations = JsonVerseTranslationRepository(
          catalog: catalog,
          bundle: FileAssetBundle(Directory.current),
        );

        final reported = <Map<String, Object?>>[];
        for (final surah in cases) {
          final file = File('$audioDir/${surah.toString().padLeft(3, '0')}.wav');
          if (!file.existsSync()) {
            stdout.writeln('跳过第 $surah 章：缺少 ${file.path}');
            continue;
          }
          final samples = CorpusAudio.decodeWav(file.readAsBytesSync());
          final duration = samples.length / _sampleRate;
          final windowSamples = (_windowSeconds * _sampleRate).round();
          // 均匀采样窗口，避开开头（太斯米/求护词）与结尾的静音。
          // 音频本身短于一个窗口时（如纯洁章 22 秒）整段作为一个窗口，否则会被跳过。
          final usable = samples.length - windowSamples;
          final windows = <Map<String, Object?>>[];
          if (usable <= 0) {
            windows.add(
              await _runWindow(
                samples: samples,
                startSample: 0,
                expectedSurah: surah,
                transcriber: transcriber,
                matcher: matcher,
                translations: translations,
              ),
            );
          } else {
            for (var index = 0; index < _windowsPerCase; index++) {
              final start = usable * (index + 1) ~/ (_windowsPerCase + 1);
              windows.add(
                await _runWindow(
                  samples: Float32List.sublistView(samples, start, start + windowSamples),
                  startSample: start,
                  expectedSurah: surah,
                  transcriber: transcriber,
                  matcher: matcher,
                  translations: translations,
                ),
              );
            }
          }
          reported.add(<String, Object?>{
            'surah': surah,
            'durationSeconds': double.parse(duration.toStringAsFixed(1)),
            'windows': windows,
          });
          stdout.writeln(
            '第 $surah 章（${duration.toStringAsFixed(0)}s）：'
            '${windows.map((item) => item['matchRefs']).join(' | ')}',
          );
        }

        _printReport(reported);
        await File(outputPath).writeAsString(
          const JsonEncoder.withIndent('  ').convert(<String, Object?>{
            'windowSeconds': _windowSeconds,
            'windowsPerCase': _windowsPerCase,
            'corpusId': library.manifest.corpusId,
            'verseCount': library.manifest.verseCount,
            'languageCount': catalog.editions.length,
            'cases': reported,
          }),
        );
        stdout.writeln('\n明细已写入 $outputPath');
        await runner.dispose();
      }, _RealHttpOverrides());
    },
    timeout: const Timeout(Duration(minutes: 60)),
    skip: Platform.environment['QURAN_E2E_AUDIO_DIR'] == null
        ? 'Set QURAN_E2E_AUDIO_DIR and start the host ORT server to run this.'
        : false,
  );
}

/// 跑一个窗口的完整链路：转写 → 匹配 → 译本。
Future<Map<String, Object?>> _runWindow({
  required Float32List samples,
  required int startSample,
  required int expectedSurah,
  required BroadcastTranscriber transcriber,
  required QuranMatchService matcher,
  required JsonVerseTranslationRepository translations,
}) async {
  final transcribeWatch = Stopwatch()..start();
  final fragment = await transcriber.transcribe(samples, offsetSample: startSample);
  final transcribeMs = transcribeWatch.elapsedMilliseconds;

  final matchWatch = Stopwatch()..start();
  final outcome = matcher.match(fragment);
  final matchMs = matchWatch.elapsedMilliseconds;

  // 译本：按匹配到的节逐节查表（与应用内 curatedEdition 路径同一套规则）。
  String? translationZh;
  String? translationEn;
  String? editionZh;
  if (outcome.matches.isNotEmpty) {
    final parts = <String>[];
    for (final match in outcome.matches) {
      final found = await translations.find(
        verseKey: match.ref,
        language: TargetLanguage.chinese,
      );
      if (found == null) {
        parts.clear();
        break;
      }
      parts.add(found.text);
      editionZh ??= '${found.translator} v${found.version}';
    }
    if (parts.isNotEmpty) translationZh = parts.join(' ');
    final english = <String>[];
    for (final match in outcome.matches) {
      final found = await translations.find(
        verseKey: match.ref,
        language: TargetLanguage.english,
      );
      if (found == null) {
        english.clear();
        break;
      }
      english.add(found.text);
    }
    if (english.isNotEmpty) translationEn = english.join(' ');
  }

  final matchRefs = <String>[for (final match in outcome.matches) match.ref];
  // 音频来源章是已知的（我们自己挑的音频），因此可以判断匹配是否落在正确章内 ——
  // 这是本脚本唯一可用的 ground truth，且不参与匹配决策。
  final hitExpectedChapter = matchRefs.any(
    (ref) => int.tryParse(ref.split(':').first) == expectedSurah,
  );

  return <String, Object?>{
    'startSeconds': double.parse((startSample / _sampleRate).toStringAsFixed(1)),
    'expectedSurah': expectedSurah,
    'hitExpectedChapter': hitExpectedChapter,
    'asrText': outcome.asrText,
    'status': outcome.status.name,
    'scope': outcome.scope.name,
    'matchRefs': matchRefs,
    'coveredVerses': outcome.matches.length,
    'coverage': outcome.coverage == null
        ? null
        : double.parse(outcome.coverage!.toStringAsFixed(3)),
    'precision': outcome.precision == null
        ? null
        : double.parse(outcome.precision!.toStringAsFixed(3)),
    'confidence': outcome.confidence == null
        ? null
        : double.parse(outcome.confidence!.toStringAsFixed(3)),
    'f1': outcome.metrics.f1 == null ? null : double.parse(outcome.metrics.f1!.toStringAsFixed(3)),
    'strictWer': outcome.metrics.strictWer == null
        ? null
        : double.parse(outcome.metrics.strictWer!.toStringAsFixed(3)),
    'referenceWords': outcome.metrics.referenceWords,
    'hypothesisWords': outcome.metrics.hypothesisWords,
    'rejectionReason': outcome.rejectionReason,
    'translationZh': translationZh,
    'translationEn': translationEn,
    'curatedEdition': editionZh,
    'transcribeMs': transcribeMs,
    'matchMs': matchMs,
    'asrWordCount': fragment.words.length,
  };
}

/// 允许真实 HTTP（host ORT 服务）的覆盖实现。
class _RealHttpOverrides extends HttpOverrides {}

/// 控制台汇总。
void _printReport(List<Map<String, Object?>> reported) {
  stdout.writeln('\n=== 端到端结果 ===');
  var total = 0;
  var matched = 0;
  var inChapter = 0;
  for (final item in reported) {
    final surah = item['surah']! as int;
    for (final raw in item['windows']! as List<Map<String, Object?>>) {
      total++;
      final refs = (raw['matchRefs']! as List<String>);
      if (refs.isNotEmpty) matched++;
      if (raw['hitExpectedChapter'] == true) inChapter++;
      final mark = raw['hitExpectedChapter'] == true ? '✓' : '✗';
      stdout.writeln(
        '[$mark] 第 $surah 章 @${raw['startSeconds']}s  '
        '${raw['status']}/${raw['scope']}  节=${refs.isEmpty ? '未匹配' : refs.join(',')}  '
        '覆盖=${raw['coverage']}  解释=${raw['precision']}  置信=${raw['confidence']}  '
        'F1=${raw['f1']}  WER=${raw['strictWer']}  '
        '词数 ${raw['referenceWords']}/${raw['hypothesisWords']}  '
        '转写 ${raw['transcribeMs']}ms 匹配 ${raw['matchMs']}ms',
      );
    }
  }
  stdout.writeln(
    '\n窗口合计 $total，有经文归属 $matched，落在正确章内 $inChapter',
  );
}
