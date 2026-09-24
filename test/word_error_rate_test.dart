import 'package:flutter_test/flutter_test.dart';
import 'package:quran_broadcast_sdk/quran_offline/word_error_rate.dart';

void main() {
  test('strict WER counts substitution, missing words and actual repetitions', () {
    final result = WordErrorRate.compare(
      ['الله', 'الرحمن', 'الرحيم'],
      ['الله', 'الله', 'الرحمان', 'الرحيم'],
    );
    expect(result.substitutions, 1);
    expect(result.insertions, 1);
    expect(result.rate, closeTo(2 / 3, 1e-9));
    expect(WordErrorRate.compare(['الله', 'الرحمن'], ['الله']).deletions, 1);
    expect(WordErrorRate.compare([], []).rate, 0);
    expect(WordErrorRate.compare([], ['الله']).rate, double.infinity);
  });
}
