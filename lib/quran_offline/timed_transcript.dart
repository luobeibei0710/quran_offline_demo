/// Acoustic-only overlap reconciliation. Reference text is never consulted.
library;

import 'ctc_decoder.dart';
import 'quran_text.dart';

class TimedWord {
  const TimedWord(this.text, this.start, this.end);
  final String text;
  final double start;
  final double end;
}

/// Re-decode the mutable audio tail, then commit words behind a two-second
/// lookahead. Time, rather than repeated text, identifies overlapping audio;
/// consecutive repetitions at different times remain separate words.
class TimedTranscript {
  final List<TimedWord> _committed = [];
  List<TimedWord> _pending = [];

  List<String> get words => [
    for (final word in _committed) word.text,
    for (final word in _pending) word.text,
  ];

  /// Reconciled words with absolute audio timestamps.
  List<TimedWord> get timedWords => [..._committed, ..._pending];

  void clear() {
    _committed.clear();
    _pending.clear();
  }

  void update({
    required TextCtcResult decoded,
    required Map<int, String> vocab,
    required int frames,
    required double windowStart,
    required double windowEnd,
    required bool isFinal,
    double lookaheadSeconds = 2,
  }) {
    if (frames <= 0) return;
    final step = (windowEnd - windowStart) / frames;
    final current = <TimedWord>[];
    var text = '';
    var start = 0.0;
    var end = 0.0;
    void flush() {
      final normalized = QuranText.normalize(text);
      if (normalized.isNotEmpty) current.add(TimedWord(normalized, start, end));
      text = '';
    }

    for (var i = 0; i < decoded.tokenIds.length; i++) {
      final piece = vocab[decoded.tokenIds[i]] ?? '';
      if (piece.isEmpty || piece.startsWith('<')) continue;
      if (piece.startsWith(TextCtcDecoder.wordPrefix)) flush();
      if (text.isEmpty) start = windowStart + decoded.tokenStarts[i] * step;
      text += piece.replaceAll(TextCtcDecoder.wordPrefix, '');
      end = windowStart + (decoded.tokenEnds[i] + 1) * step;
    }
    flush();
    final boundary = _committed.isEmpty ? double.negativeInfinity : _committed.last.end;
    // Preserve words outside this window; replace hypotheses inside its range.
    _pending = [
      ..._pending.where((word) => word.end < windowStart),
      ...current.where(
        (word) =>
            word.end > boundary + 0.12 &&
            (word.start >= boundary - 0.12 || word.start + (word.end - word.start) / 2 > boundary),
      ),
    ];
    final cutoff = isFinal ? double.infinity : windowEnd - lookaheadSeconds;
    // A final decoded word may still be a prefix while the reciter sustains it.
    // Require a following word boundary even if its first tokens are old.
    final eligible = isFinal ? _pending : _pending.take(_pending.isEmpty ? 0 : _pending.length - 1);
    final count = eligible.takeWhile((word) => word.end <= cutoff).length;
    _committed.addAll(_pending.take(count));
    _pending = _pending.skip(count).toList();
  }
}
