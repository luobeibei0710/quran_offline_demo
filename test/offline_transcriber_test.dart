import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:quran_offline_demo/quran_offline/ctc_decoder.dart';
import 'package:quran_offline_demo/quran_offline/ctc_scorer.dart';
import 'package:quran_offline_demo/quran_offline/offline_transcriber.dart';
import 'package:quran_offline_demo/quran_offline/ort_runner.dart';

void main() {
  group('OfflineTranscriber.segmentBounds', () {
    test('covers short audio in one bounded window', () {
      expect(
        OfflineTranscriber.segmentBounds(sampleCount: 28 * 16000, sampleRate: 16000),
        <(int, int)>[(0, 28 * 16000)],
      );
    });

    test('moves a sub-ten-second tail into an overlapping final window', () {
      final bounds = OfflineTranscriber.segmentBounds(sampleCount: 31 * 16000, sampleRate: 16000);

      expect(bounds, <(int, int)>[(0, 30 * 16000), (16000, 31 * 16000)]);
      _expectCoverageAndBounds(bounds, 31 * 16000, 30 * 16000);
    });

    test('long audio remains bounded, contiguous, and overlapping', () {
      final bounds = OfflineTranscriber.segmentBounds(sampleCount: 75 * 16000, sampleRate: 16000);

      expect(bounds, <(int, int)>[
        (0, 30 * 16000),
        (22 * 16000, 52 * 16000),
        (44 * 16000, 74 * 16000),
        (45 * 16000, 75 * 16000),
      ]);
      _expectCoverageAndBounds(bounds, 75 * 16000, 30 * 16000);
    });
  });

  test('transcribes model evidence without Quran-reference recovery', () async {
    const vocab = <int, String>{0: '<unk>', 1: '▁foo', 2: '▁bar', 3: '<blank>'};
    final progress = <double>[];
    final transcriber = OfflineTranscriber(
      runner: _EvidenceRunner(_evidence()),
      decoder: TextCtcDecoder(vocab, blankId: 3),
      vocab: vocab,
      sampleRate: 1,
      windowSeconds: 30,
      overlapSeconds: 8,
      lookaheadSeconds: 8,
    );

    final result = await transcriber.transcribe(
      Float32List(28)..fillRange(0, 28, .1),
      onProgress: progress.add,
    );

    expect(result.words, <String>['foo', 'bar']);
    expect(result.segments, hasLength(1));
    expect(result.segments.single.decodedText, 'foo bar');
    expect(result.timedWords.map((word) => word.text), <String>['foo', 'bar']);
    expect(progress, <double>[1]);
  });

  test('acoustic pauses partition audio independently of labels and gain', () {
    final transcriber = OfflineTranscriber(
      runner: _EvidenceRunner(_evidence()),
      decoder: TextCtcDecoder({3: '<blank>'}, blankId: 3),
      vocab: const {},
    );
    final samples = Float32List(8 * 16000)..fillRange(0, 8 * 16000, .1);
    samples.fillRange(3 * 16000, (3.6 * 16000).round(), .001);
    final bounds = transcriber.audioSegmentBounds(samples);
    expect(bounds, [(0, 52800), (52800, 128000)]);
    expect(
      transcriber.audioSegmentBounds(
        Float32List.fromList(samples.map((value) => value * .2).toList()),
      ),
      bounds,
    );
    expect(transcriber.audioSegmentBounds(Float32List(16000)), isEmpty);
    final mostlySilent = Float32List(12 * 16000);
    mostlySilent.fillRange(0, 16000, .1);
    mostlySilent.fillRange(11 * 16000, 12 * 16000, .1);
    expect(transcriber.audioSegmentBounds(mostlySilent), hasLength(2));
  });

  test('all-silent audio never invokes the acoustic model', () async {
    final runner = _EvidenceRunner(_evidence());
    final transcriber = OfflineTranscriber(
      runner: runner,
      decoder: TextCtcDecoder({3: '<blank>'}, blankId: 3),
      vocab: const {},
    );
    expect((await transcriber.transcribe(Float32List(16000))).words, isEmpty);
    expect(runner.runCount, 0);
  });
}

void _expectCoverageAndBounds(List<(int, int)> bounds, int total, int maximumWindow) {
  expect(bounds.first.$1, 0);
  expect(bounds.last.$2, total);
  for (var index = 0; index < bounds.length; index++) {
    final bound = bounds[index];
    expect(bound.$2 - bound.$1, lessThanOrEqualTo(maximumWindow));
    if (index > 0) expect(bound.$1, lessThanOrEqualTo(bounds[index - 1].$2));
  }
}

class _EvidenceRunner implements OrtRunner {
  _EvidenceRunner(this.evidence);

  final AcousticEvidence evidence;
  int runCount = 0;

  @override
  Future<void> dispose() async {}

  @override
  Future<void> loadModel(String modelPath) async {}

  @override
  Future<AcousticEvidence> run(Float32List samples) async {
    runCount++;
    return evidence;
  }
}

AcousticEvidence _evidence() {
  final values = Float32List(12)..fillRange(0, 12, -10);
  values[1] = 0;
  values[7] = 0;
  values[10] = 0;
  return AcousticEvidence(logprobs: values, timeSteps: 3, vocabSize: 4, blankId: 3);
}
