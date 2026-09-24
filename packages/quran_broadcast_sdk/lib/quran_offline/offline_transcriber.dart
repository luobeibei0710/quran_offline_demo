/// Bounded offline audio transcription without Quran-reference recovery.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'ctc_decoder.dart';
import 'ort_runner.dart';
import 'timed_transcript.dart';

/// One bounded model invocation over an absolute audio interval.
class OfflineTranscriptionSegment {
  const OfflineTranscriptionSegment({
    required this.startSeconds,
    required this.endSeconds,
    required this.decodedText,
    required this.timeSteps,
  });

  final double startSeconds;
  final double endSeconds;
  final String decodedText;
  final int timeSteps;
}

/// Acoustic-only output from [OfflineTranscriber].
class OfflineTranscriptionResult {
  const OfflineTranscriptionResult({
    required this.words,
    required this.timedWords,
    required this.segments,
  });

  final List<String> words;
  final List<TimedWord> timedWords;
  final List<OfflineTranscriptionSegment> segments;
}

/// Runs bounded, overlapping CTC windows and reconciles them by timestamp.
class OfflineTranscriber {
  OfflineTranscriber({
    required this.runner,
    required this.decoder,
    required this.vocab,
    this.sampleRate = 16000,
    this.windowSeconds = 30,
    this.overlapSeconds = 8,
    this.lookaheadSeconds = 8,
  }) : assert(sampleRate > 0),
       assert(windowSeconds > 0),
       assert(overlapSeconds >= 0 && overlapSeconds < windowSeconds),
       assert(lookaheadSeconds >= 0 && lookaheadSeconds < windowSeconds);

  final OrtRunner runner;
  final TextCtcDecoder decoder;
  final Map<int, String> vocab;
  final int sampleRate;
  final double windowSeconds;
  final double overlapSeconds;
  final double lookaheadSeconds;

  /// Transcribes [samples] without querying a reference text or matcher.
  Future<OfflineTranscriptionResult> transcribe(
    Float32List samples, {
    bool Function()? isCancelled,
    void Function(double fraction)? onProgress,
  }) async {
    final bounds = audioSegmentBounds(samples);
    final transcript = TimedTranscript();
    final segments = <OfflineTranscriptionSegment>[];
    for (var index = 0; index < bounds.length; index++) {
      if (isCancelled?.call() ?? false) break;
      final bound = bounds[index];
      final evidence = await runner.run(Float32List.sublistView(samples, bound.$1, bound.$2));
      final decoded = decoder.decode(evidence.logprobs, evidence.timeSteps, evidence.vocabSize);
      final isFinal = index == bounds.length - 1 || bounds[index + 1].$1 >= bound.$2;
      transcript.update(
        decoded: decoded,
        vocab: vocab,
        frames: evidence.timeSteps,
        windowStart: bound.$1 / sampleRate,
        windowEnd: bound.$2 / sampleRate,
        isFinal: isFinal,
        lookaheadSeconds: lookaheadSeconds,
      );
      segments.add(
        OfflineTranscriptionSegment(
          startSeconds: bound.$1 / sampleRate,
          endSeconds: bound.$2 / sampleRate,
          decodedText: decoded.text,
          timeSteps: evidence.timeSteps,
        ),
      );
      onProgress?.call(bound.$2 / samples.length);
    }
    return OfflineTranscriptionResult(
      words: List<String>.unmodifiable(transcript.words),
      timedWords: List<TimedWord>.unmodifiable(transcript.timedWords),
      segments: List<OfflineTranscriptionSegment>.unmodifiable(segments),
    );
  }

  /// Cut at acoustic pauses, not at verse labels. Relative RMS keeps the rule
  /// invariant to recording gain. Long passages without pauses use the bounded
  /// overlapping fallback; no expected verse or reference text enters this path.
  List<(int, int)> audioSegmentBounds(Float32List samples) {
    if (samples.isEmpty) return const [];
    final frame = math.max(1, (sampleRate * .02).round());
    final energy = <double>[];
    for (var start = 0; start < samples.length; start += frame) {
      final end = math.min(start + frame, samples.length);
      var sum = 0.0;
      for (var i = start; i < end; i++) {
        if (!samples[i].isFinite) throw ArgumentError('Audio must contain finite PCM samples');
        sum += samples[i] * samples[i];
      }
      energy.add(math.sqrt(sum / (end - start)));
    }
    final sorted = [...energy]..sort();
    if (sorted.last < 1e-5) return const [];
    final threshold = math.max(1e-5, sorted[sorted.length ~/ 2] * .4);
    final cuts = <int>[0];
    int? quietStart;
    for (var i = 0; i <= energy.length; i++) {
      final quiet = i < energy.length && energy[i] < threshold;
      if (quiet) {
        quietStart ??= i;
      } else if (quietStart != null) {
        final midpoint = ((i + quietStart) * frame / 2).round();
        if ((i - quietStart) * frame / sampleRate >= .35 &&
            midpoint - cuts.last >= sampleRate * 2 &&
            samples.length - midpoint >= sampleRate) {
          cuts.add(midpoint);
        }
        quietStart = null;
      }
    }
    cuts.add(samples.length);
    final result = <(int, int)>[];
    for (var i = 1; i < cuts.length; i++) {
      final base = cuts[i - 1];
      for (final bound in segmentBounds(
        sampleCount: cuts[i] - base,
        sampleRate: sampleRate,
        windowSeconds: windowSeconds,
        overlapSeconds: overlapSeconds,
      )) {
        result.add((base + bound.$1, base + bound.$2));
      }
    }
    return result;
  }

  /// Builds contiguous coverage with overlap and avoids a final fragment below ten seconds.
  static List<(int, int)> segmentBounds({
    required int sampleCount,
    required int sampleRate,
    double windowSeconds = 30,
    double overlapSeconds = 8,
    double minTailSeconds = 10,
  }) {
    if (sampleCount <= 0) return const <(int, int)>[];
    final window = math.max(1, (windowSeconds * sampleRate).round());
    final stride = math.max(1, ((windowSeconds - overlapSeconds) * sampleRate).round());
    final minTail = math.max(1, (minTailSeconds * sampleRate).round());
    final bounds = <(int, int)>[];
    var start = 0;
    while (true) {
      final end = math.min(start + window, sampleCount);
      bounds.add((start, end));
      if (end == sampleCount) break;
      var next = start + stride;
      if (sampleCount - next < minTail) {
        next = math.max(0, sampleCount - window);
      }
      if (next <= start || bounds.any((bound) => bound.$1 == next)) break;
      start = next;
    }
    return List<(int, int)>.unmodifiable(bounds);
  }
}
