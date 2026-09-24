/// Real-audio streaming benchmark using the local host ONNX Runtime server.
///
/// Start `tools/quran_offline/host_ort_server.py`, then set QURAN_BENCH_OUT
/// and invoke this test with `flutter test tool/stream_benchmark_test.dart`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quran_offline_demo/quran_offline/corpus_audio.dart';
import 'package:quran_offline_demo/quran_offline/corpus_catalog.dart';
import 'package:quran_broadcast_sdk/quran_offline/ctc_scorer.dart';
import 'package:quran_broadcast_sdk/quran_offline/ort_runner.dart';
import 'package:quran_broadcast_sdk/quran_offline/quran_assets.dart';
import 'package:quran_offline_demo/quran_offline/quran_recognizer.dart';
import 'package:quran_broadcast_sdk/quran_offline/quran_text.dart';
import 'package:quran_offline_demo/quran_offline/reference_text.dart';
import 'package:quran_broadcast_sdk/quran_offline/word_alignment.dart';

const _sampleRate = QuranRecognizer.sampleRate;
const _expectedCases = <String, List<String>>{
  'corpus_036_001_005.wav': <String>['36:1-5'],
  'corpus_055_001_013.wav': <String>['55:1-13'],
  'corpus_067_001_011.wav': <String>['67:1-11'],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'real corpus streaming benchmark through local ORT',
    () async {
      final outputPath = Platform.environment['QURAN_BENCH_OUT'];
      if (outputPath == null || outputPath.isEmpty) {
        throw StateError(
          'Set QURAN_BENCH_OUT to the JSON report path before running this benchmark.',
        );
      }
      final caseFilter = Platform.environment['QURAN_BENCH_CASE'];
      final gate = Platform.environment['QURAN_BENCH_GATE'] == '1';
      final advanceWindow = Platform.environment['QURAN_BENCH_ADVANCE'] != 'false';
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

        final eventFile = File('$outputPath.events.jsonl');
        await eventFile.parent.create(recursive: true);
        await eventFile.writeAsString('');
        final runner = HttpOrtRunner(endpoint: endpoint, blankId: assets.blankId);
        final reports = <Map<String, Object?>>[];
        try {
          for (final item in items) {
            final expected = _expectedCases[item.id]!;
            expect(item.reference.label, expected.single);
            final pcm = CorpusAudio.decodeWav(
              (await bundle.load(item.audio.assetKey!)).buffer.asUint8List(),
            );
            final report = await _runCase(
              assets: assets,
              runner: runner,
              item: item,
              expected: expected,
              samples: pcm,
              eventFile: eventFile,
              advanceWindow: advanceWindow,
            );
            reports.add(report);
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
        final document = <String, Object?>{
          'schemaVersion': 1,
          'engine': <String, Object?>{
            'url': endpoint.toString(),
            'input': 'float32 PCM LE, 16 kHz',
          },
          'gateEnabled': gate,
          'gatePassed': passed,
          'advanceWindowOnCommit': advanceWindow,
          'cases': reports,
          'eventLog': eventFile.path,
        };
        await File(outputPath).writeAsString(const JsonEncoder.withIndent('  ').convert(document));
        if (gate) {
          expect(passed, isTrue, reason: 'F1/precision/recall must each be >= 0.9');
        }
      }, _RealHttpOverrides());
    },
    timeout: const Timeout(Duration(minutes: 30)),
    skip: Platform.environment['QURAN_BENCH_OUT'] == null
        ? 'Set QURAN_BENCH_OUT and start the local host ORT server to run this benchmark.'
        : false,
  );
}

class FileAssetBundle extends CachingAssetBundle {
  FileAssetBundle(this.root);

  final Directory root;

  @override
  Future<ByteData> load(String key) async {
    final bytes = await File('${root.path}/$key').readAsBytes();
    return ByteData.sublistView(bytes);
  }
}

class _RealHttpOverrides extends HttpOverrides {}

class HttpOrtRunner implements OrtRunner {
  HttpOrtRunner({required this.endpoint, required this.blankId});

  final Uri endpoint;
  final int blankId;
  final HttpClient _client = HttpClient();

  @override
  Future<void> loadModel(String modelPath) async {}

  @override
  Future<AcousticEvidence> run(Float32List samples) async {
    final request = await _client.postUrl(endpoint.resolve('/run'));
    request.headers.set(HttpHeaders.contentTypeHeader, ContentType.binary.mimeType);
    request.contentLength = samples.lengthInBytes;
    request.add(Uint8List.view(samples.buffer, samples.offsetInBytes, samples.lengthInBytes));
    final response = await request.close();
    final bytes = await consolidateHttpClientResponseBytes(response);
    if (response.statusCode != HttpStatus.ok) {
      throw StateError('ORT server ${response.statusCode}: ${utf8.decode(bytes)}');
    }
    final timeSteps = int.tryParse(response.headers.value('x-quran-time-steps') ?? '');
    final vocabSize = int.tryParse(response.headers.value('x-quran-vocab-size') ?? '');
    if (timeSteps == null || vocabSize == null || bytes.length != timeSteps * vocabSize * 4) {
      throw StateError(
        'ORT response dimensions are invalid: $timeSteps x $vocabSize, ${bytes.length} bytes',
      );
    }
    final values = Float32List(timeSteps * vocabSize);
    final byteData = ByteData.sublistView(bytes);
    for (var index = 0; index < values.length; index++) {
      values[index] = byteData.getFloat32(index * 4, Endian.little);
    }
    return AcousticEvidence(
      logprobs: values,
      timeSteps: timeSteps,
      vocabSize: vocabSize,
      blankId: blankId,
    );
  }

  @override
  Future<void> dispose() async => _client.close(force: true);
}

Future<Map<String, Object?>> _runCase({
  required QuranAssets assets,
  required HttpOrtRunner runner,
  required CorpusItem item,
  required List<String> expected,
  required Float32List samples,
  required File eventFile,
  required bool advanceWindow,
}) async {
  final recognizer = QuranRecognizer(
    assets: assets,
    runner: runner,
    config: QuranStreamingConfig(advanceWindowOnCommit: advanceWindow),
  );
  final session = recognizer.createSession(assumeSpeech: true);
  final seenRefs = <String>[];
  final stableRefs = <String>[];
  final transcriptRefs = <String>[];
  final coveredAyahs = <String>{};
  var committedRefs = const <String>[];
  var eventCount = 0;
  var advancedSeconds = 0.0;
  var fedSeconds = 0.0;
  var timedTranscriptWords = const <String>[];
  final eventLines = <String>[];
  final watch = Stopwatch()..start();
  final subscription = session.events.listen((event) {
    eventCount++;
    advancedSeconds += event.advancedSeconds;
    committedRefs = event.committedSequence;
    timedTranscriptWords = event.transcriptWords;
    final champion = event.champion;
    final ref = champion?.ref;
    if (ref != null && (seenRefs.isEmpty || seenRefs.last != ref)) {
      seenRefs.add(ref);
    }
    if (ref != null && event.stable) {
      if (stableRefs.isEmpty || stableRefs.last != ref) stableRefs.add(ref);
      for (final ayahRef in _ayahRefs(ref)) {
        if (coveredAyahs.add(ayahRef)) transcriptRefs.add(ayahRef);
      }
    }
    eventLines.add(
      jsonEncode(<String, Object?>{
        'case': item.id,
        'index': eventCount,
        'champion': ref,
        'stable': event.stable,
        'final': event.isFinal,
        'audioSeconds': event.audioSeconds,
        'fedSeconds': fedSeconds,
        'decodedText': event.decodedText,
        'transcriptWords': event.transcriptWords,
        'readWords': event.readWords,
        'committedRefs': event.committedSequence,
        'advancedSeconds': event.advancedSeconds,
        'tracked': <String, Object?>{},
        'candidate': champion == null
            ? null
            : <String, Object?>{
                'confidence': event.match.confidence,
                'textScore': champion.textScore,
                'acousticScore': champion.acousticScore,
                'sortScore': champion.sortScore,
              },
      }),
    );
  });
  try {
    const chunkSamples = _sampleRate ~/ 50;
    for (var offset = 0; offset < samples.length; offset += chunkSamples) {
      final end = (offset + chunkSamples).clamp(0, samples.length);
      fedSeconds = end / _sampleRate;
      await session.feed(Float32List.sublistView(samples, offset, end));
    }
    await session.finish();
  } finally {
    await subscription.cancel();
    await session.dispose();
    watch.stop();
  }
  await eventFile.writeAsString('${eventLines.join('\n')}\n', mode: FileMode.append);
  final transcriptWords = <String>[for (final ref in transcriptRefs) ..._wordsForRef(assets, ref)];
  final reference = ReferenceText(
    words: <String>[for (final ref in expected) ..._wordsForRef(assets, ref)],
    rawText: '',
    source: 'QuranAssets ${item.reference.label}',
  );
  final fixedReference = CorpusCatalog.fixedReference(
    reference,
    includesBismillah: item.includesBismillah,
  );
  final stable = WordAlignment.align(fixedReference.words, transcriptWords);
  final timed = WordAlignment.align(fixedReference.words, timedTranscriptWords);
  return <String, Object?>{
    'id': item.id,
    'expected': expected,
    'audioSeconds': samples.length / _sampleRate,
    'elapsedSeconds': watch.elapsedMicroseconds / Duration.microsecondsPerSecond,
    'eventCount': eventCount,
    'seenRefs': seenRefs,
    'stableRefs': stableRefs,
    'transcriptRefs': transcriptRefs,
    'committedRefs': committedRefs,
    'advancedSeconds': advancedSeconds,
    'reference': <String, Object?>{
      'includesBismillah': item.includesBismillah,
      'wordCount': fixedReference.words.length,
      'source': fixedReference.source,
    },
    'metrics': _metrics(stable),
    'timedRaw': <String, Object?>{
      'text': timedTranscriptWords.join(' '),
      'metrics': _metrics(timed)
        ..['strictWer'] = _strictWer(fixedReference.words, timedTranscriptWords),
    },
  };
}

Map<String, Object?> _metrics(AlignmentResult alignment) => <String, Object?>{
  'f1': alignment.f1,
  'precision': alignment.precision,
  'recall': alignment.coverage,
  'referenceWords': alignment.referenceCount,
  'hypothesisWords': alignment.hypothesisCount,
  'matchCount': alignment.matchCount,
  'nearCount': alignment.nearCount,
  'missingCount': alignment.missingCount,
  'extraCount': alignment.extraCount,
};

double _strictWer(List<String> reference, List<String> hypothesis) {
  final left = reference
      .map(QuranText.normalize)
      .where((word) => word.isNotEmpty)
      .toList(growable: false);
  final right = hypothesis
      .map(QuranText.normalize)
      .where((word) => word.isNotEmpty)
      .toList(growable: false);
  if (left.isEmpty) return right.isEmpty ? 0 : 1;
  var previous = List<int>.generate(right.length + 1, (index) => index);
  for (var row = 1; row <= left.length; row++) {
    final current = List<int>.filled(right.length + 1, 0)..[0] = row;
    for (var column = 1; column <= right.length; column++) {
      final replacement = previous[column - 1] + (left[row - 1] == right[column - 1] ? 0 : 1);
      current[column] = <int>[
        previous[column] + 1,
        current[column - 1] + 1,
        replacement,
      ].reduce((best, value) => value < best ? value : best);
    }
    previous = current;
  }
  return previous.last / left.length;
}

List<String> _ayahRefs(String ref) {
  final parts = ref.split(':');
  if (parts.length != 2) return const <String>[];
  final surah = int.tryParse(parts[0]);
  final range = parts[1].split('-');
  final start = int.tryParse(range.first);
  final end = int.tryParse(range.last);
  if (surah == null || start == null || end == null) return const <String>[];
  return <String>[for (var ayah = start; ayah <= end; ayah++) '$surah:$ayah'];
}

List<String> _wordsForRef(QuranAssets assets, String ref) {
  final words = <String>[];
  for (final ayahRef in _ayahRefs(ref)) {
    final pair = ayahRef.split(':');
    final verse = assets.verse(int.parse(pair[0]), int.parse(pair[1]));
    if (verse != null) words.addAll(verse.words);
  }
  return words;
}
