import 'package:quran_broadcast_sdk/quran_offline/quran_text.dart';

/// Strict normalized word edit distance; no fuzzy matches or reference repair.
class WordErrorRate {
  const WordErrorRate({
    required this.referenceWords,
    required this.substitutions,
    required this.deletions,
    required this.insertions,
  });
  final int referenceWords;
  final int substitutions;
  final int deletions;
  final int insertions;
  int get errors => substitutions + deletions + insertions;
  double get rate =>
      referenceWords == 0 ? (errors == 0 ? 0 : double.infinity) : errors / referenceWords;

  static WordErrorRate compare(List<String> reference, List<String> hypothesis) {
    List<String> clean(List<String> words) =>
        QuranText.normalize(words.join(' ')).split(' ').where((word) => word.isNotEmpty).toList();
    final a = clean(reference);
    final b = clean(hypothesis);
    final dp = List.generate(a.length + 1, (_) => List<int>.filled(b.length + 1, 0));
    for (var i = 0; i <= a.length; i++) {
      dp[i][0] = i;
    }
    for (var j = 0; j <= b.length; j++) {
      dp[0][j] = j;
    }
    for (var i = 1; i <= a.length; i++) {
      for (var j = 1; j <= b.length; j++) {
        final sub = dp[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1);
        final del = dp[i - 1][j] + 1;
        final ins = dp[i][j - 1] + 1;
        dp[i][j] = sub < del ? (sub < ins ? sub : ins) : (del < ins ? del : ins);
      }
    }
    var i = a.length, j = b.length, sub = 0, del = 0, ins = 0;
    while (i > 0 || j > 0) {
      if (i > 0 && j > 0 && dp[i][j] == dp[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)) {
        if (a[i - 1] != b[j - 1]) sub++;
        i--;
        j--;
      } else if (i > 0 && dp[i][j] == dp[i - 1][j] + 1) {
        del++;
        i--;
      } else {
        ins++;
        j--;
      }
    }
    return WordErrorRate(
      referenceWords: a.length,
      substitutions: sub,
      deletions: del,
      insertions: ins,
    );
  }
}
