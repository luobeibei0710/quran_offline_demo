/// Explicit real-audio benchmark for [OfflineTranscriber].
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:quran_offline_demo/quran_offline/corpus_audio.dart';
import 'package:quran_offline_demo/quran_offline/corpus_catalog.dart';
import 'package:quran_offline_demo/quran_offline/ctc_decoder.dart';
import 'package:quran_offline_demo/quran_offline/offline_transcriber.dart';
import 'package:quran_offline_demo/quran_offline/quran_assets.dart';
import 'package:quran_offline_demo/quran_offline/reference_text.dart';
import 'package:quran_offline_demo/quran_offline/word_alignment.dart';
import 'package:quran_offline_demo/quran_offline/word_error_rate.dart';

import 'stream_benchmark_test.dart' show FileAssetBundle, HttpOrtRunner;

const _expectedCases = <String, List<String>>{
  'corpus_036_001_005.wav': <String>['36:1-5'],
  'corpus_055_001_013.wav': <String>['55:1-13'],
  'corpus_067_001_011.wav': <String>['67:1-11'],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'real corpus offline ASR benchmark through local ORT',
    () async {
      final outputPath = Platform.environment['QURAN_BENCH_OUT'];
      if (outputPath == null || outputPath.isEmpty) {
        throw StateError(
          'Set QURAN_BENCH_OUT to the JSON report path before running this benchmark.',
        );
      }
      final caseFilter = Platform.environment['QURAN_BENCH_CASE'];
      final endpoint = Uri.parse(Platform.environment['QURAN_ORT_URL'] ?? 'http://127.0.0.1:8765');
      final bundle = FileAssetBundle(Directory.current);
      await HttpOverrides.runWithHttpOverrides(() async {
        final assets = await QuranAssets.load(bundle: bundle);
        final allItems = await CorpusCatalog.load(
          bundle: bundle,
          listDir: (_) async => const <String>[],
        );
        final items = allItems
            .where((item) => _expectedCases.containsKey(item.id))
            .where((item) {
              return caseFilter == null ||
                  caseFilter.isEmpty ||
                  item.id == caseFilter ||
                  item.reference.label == caseFilter;
            })
            .toList(growable: false);
        if (items.isEmpty) {
          throw StateError('No fixed corpus matches QURAN_BENCH_CASE=$caseFilter');
        }

        final runner = HttpOrtRunner(endpoint: endpoint, blankId: assets.blankId);
        final transcriber = OfflineTranscriber(
          runner: runner,
          decoder: TextCtcDecoder(assets.vocab, blankId: assets.blankId),
          vocab: assets.vocab,
        );
        final reports = <Map<String, Object?>>[];
        try {
          for (final item in items) {
            final expected = _expectedCases[item.id]!;
            final samples = CorpusAudio.decodeWav(
              (await bundle.load(item.audio.assetKey!)).buffer.asUint8List(),
            );
            final watch = Stopwatch()..start();
            final result = await transcriber.transcribe(samples);
            watch.stop();
            final reference = CorpusCatalog.fixedReference(
              ReferenceText(
                words: <String>[for (final ref in expected) ..._wordsForRef(assets, ref)],
                rawText: '',
                source: 'QuranAssets ${item.reference.label}',
              ),
              includesBismillah: item.includesBismillah,
            );
            final alignment = WordAlignment.align(reference.words, result.words);
            final wer = WordErrorRate.compare(reference.words, result.words);
            reports.add(<String, Object?>{
              'id': item.id,
              'expected': expected,
              'audioSeconds': samples.length / 16000,
              'elapsedSeconds': watch.elapsedMicroseconds / Duration.microsecondsPerSecond,
              'reference': <String, Object?>{
                'includesBismillah': item.includesBismillah,
                'wordCount': reference.words.length,
                'source': reference.source,
              },
              'text': result.words.join(' '),
              'segmentCount': result.segments.length,
              'segments': <Map<String, Object?>>[
                for (final segment in result.segments)
                  <String, Object?>{
                    'startSeconds': segment.startSeconds,
                    'endSeconds': segment.endSeconds,
                    'timeSteps': segment.timeSteps,
                    'decodedText': segment.decodedText,
                  },
              ],
              'timestamps': <Map<String, Object?>>[
                for (final word in result.timedWords)
                  <String, Object?>{
                    'text': word.text,
                    'startSeconds': word.start,
                    'endSeconds': word.end,
                  },
              ],
              'metrics': <String, Object?>{
                'f1': alignment.f1,
                'precision': alignment.precision,
                'recall': alignment.coverage,
                'strictWer': wer.rate,
                'strictErrors': wer.errors,
                'referenceWords': alignment.referenceCount,
                'hypothesisWords': alignment.hypothesisCount,
              },
            });
          }
        } finally {
          await runner.dispose();
        }
        final passed = reports.every((report) {
          final metrics = report['metrics']! as Map<String, Object?>;
          return (metrics['f1']! as double) >= .9 &&
              (metrics['precision']! as double) >= .9 &&
              (metrics['recall']! as double) >= .9;
        });
        await File(outputPath).writeAsString(
          const JsonEncoder.withIndent('  ').convert(<String, Object?>{
            'schemaVersion': 1,
            'engine': <String, Object?>{'url': endpoint.toString(), 'mode': 'offline bounded CTC'},
            'segmentation': '20ms RMS; pause >=0.35s below 0.4*median; midpoint cut',
            'windowSeconds': 30,
            'overlapSeconds': 8,
            'lookaheadSeconds': 8,
            'gatePassed': passed,
            'cases': reports,
          }),
        );
        expect(
          passed,
          isTrue,
          reason: 'Every fixed corpus requires F1, precision, and recall >= 0.9',
        );
      }, _RealHttpOverrides());
    },
    timeout: const Timeout(Duration(minutes: 30)),
    skip: Platform.environment['QURAN_BENCH_OUT'] == null
        ? 'Set QURAN_BENCH_OUT and start the local host ORT server to run this benchmark.'
        : false,
  );
}

class _RealHttpOverrides extends HttpOverrides {}

List<String> _wordsForRef(QuranAssets assets, String ref) {
  final parts = ref.split(':');
  if (parts.length != 2) return const <String>[];
  final surah = int.tryParse(parts[0]);
  final range = parts[1].split('-');
  final start = int.tryParse(range.first);
  final end = int.tryParse(range.last);
  if (surah == null || start == null || end == null) return const <String>[];
  return <String>[for (var ayah = start; ayah <= end; ayah++) ...?assets.verse(surah, ayah)?.words];
}
