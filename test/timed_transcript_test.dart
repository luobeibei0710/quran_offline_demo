import 'package:flutter_test/flutter_test.dart';
import 'package:quran_offline_demo/quran_offline/ctc_decoder.dart';
import 'package:quran_offline_demo/quran_offline/timed_transcript.dart';

void main() {
  const vocab = {1: '▁الله', 2: '▁الرحمن', 3: '▁الرحيم', 4: '▁الرح'};
  void update(
    TimedTranscript transcript,
    List<int> ids,
    List<int> frames, {
    double start = 0,
    double end = 5,
    bool finalEvent = false,
  }) {
    transcript.update(
      decoded: TextCtcResult(
        text: '',
        tokenIds: ids,
        wordEnds: [],
        tokenStarts: frames,
        tokenEnds: frames,
      ),
      vocab: vocab,
      frames: ((end - start) * 10).round(),
      windowStart: start,
      windowEnd: end,
      isFinal: finalEvent,
    );
  }

  test('overlapping windows do not duplicate words, real repetitions survive', () {
    final transcript = TimedTranscript();
    update(transcript, [1, 1, 2], [5, 15, 40]);
    update(transcript, [1, 2, 3], [5, 30, 45], start: 1, end: 6, finalEvent: true);
    expect(transcript.words, ['الله', 'الله', 'الرحمن', 'الرحيم']);
  });

  test('uncommitted partial word is replaced by later acoustic decoding', () {
    final transcript = TimedTranscript();
    update(transcript, [1, 4], [10, 40]);
    update(transcript, [1, 2], [10, 40], end: 6, finalEvent: true);
    expect(transcript.words, ['الله', 'الرحمن']);
    transcript.clear();
    expect(transcript.words, isEmpty);
  });

  test('silent final window preserves already committed speech', () {
    final transcript = TimedTranscript();
    update(transcript, [1], [5]);
    update(transcript, [], [], start: 5, end: 8, finalEvent: true);
    expect(transcript.words, ['الله']);
  });
}
