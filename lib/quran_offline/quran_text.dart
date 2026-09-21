/// 古兰经文本工具：阿拉伯语归一化与相似度计算。
///
/// 基本字母沿用 Tilawa 的 `normalizer.ts` + `levenshtein.ts` 语义；额外兼容
/// 外部文本中的 Arabic Presentation Forms-A/B，避免旧式字形编码破坏召回。
library;

import 'arabic_presentation_forms.dart';

/// 阿拉伯语文本归一化与相似度。
class QuranText {
  QuranText._();

  /// 变音符号（تشكيل）、Tatweel 与 BOM：归一化时全部移除。
  static final RegExp _strippable = RegExp(
    '[\u0610-\u061A\u064B-\u065F\u0670\u06D6-\u06DE\u06DF-\u06ED\u0640\uFEFF]',
  );

  /// 字母变体归一映射，避免同一发音因书写差异被判定为不同字符。
  static const Map<String, String> _letterMap = {
    '\u0623': '\u0627', // أ -> ا
    '\u0625': '\u0627', // إ -> ا
    '\u0622': '\u0627', // آ -> ا
    '\u0671': '\u0627', // ٱ -> ا
    '\u0629': '\u0647', // ة -> ه
    '\u0649': '\u064A', // ى -> ي
  };

  /// 归一化阿拉伯语文本。
  ///
  /// 处理顺序：先把外部输入中的 Arabic Presentation Forms-A/B 兼容分解为
  /// 逻辑字符，再沿用 Tilawa 语义去 BOM、去变音符号/Tatweel、统一字母变体，
  /// 最后压缩空白。该兼容步骤只反向展开旧式字形编码，不做显示用 reshape。
  ///
  /// @param text 原始文本（可能含音标）
  /// @return 归一化后的文本
  static String normalize(String text) {
    final expanded = expandArabicPresentationForms(text);
    final stripped = expanded.replaceAll(_strippable, '');
    final buffer = StringBuffer();
    for (final codePoint in stripped.runes) {
      final char = String.fromCharCode(codePoint);
      buffer.write(_letterMap[char] ?? char);
    }
    return buffer
        .toString()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .join(' ');
  }

  /// 归一化后的字符级编辑相似度（0..1，1 表示完全相同）。
  ///
  /// 使用滚动数组的 Levenshtein 距离，等价于 Tilawa 的 `ratio`。
  static double ratio(String a, String b) {
    if (a == b) return 1.0;
    if (a.isEmpty || b.isEmpty) return 0.0;

    final aUnits = a.runes.toList(growable: false);
    final bUnits = b.runes.toList(growable: false);
    var previous = List<int>.generate(bUnits.length + 1, (index) => index);
    var current = List<int>.filled(bUnits.length + 1, 0);

    for (var i = 1; i <= aUnits.length; i++) {
      current[0] = i;
      for (var j = 1; j <= bUnits.length; j++) {
        final cost = aUnits[i - 1] == bUnits[j - 1] ? 0 : 1;
        final deletion = previous[j] + 1;
        final insertion = current[j - 1] + 1;
        final substitution = previous[j - 1] + cost;
        current[j] = deletion < insertion
            ? (deletion < substitution ? deletion : substitution)
            : (insertion < substitution ? insertion : substitution);
      }
      final swap = previous;
      previous = current;
      current = swap;
    }
    final distance = previous[bUnits.length];
    final longest = aUnits.length > bUnits.length
        ? aUnits.length
        : bUnits.length;
    return 1.0 - distance / longest;
  }

  /// 片段相似度：把 [query] 当作 [target] 的片段，返回最佳窗口相似度。
  ///
  /// 对应 Tilawa 的 `fragmentScore`/`partialRatio`，用于处理「只诵读了一节
  /// 的部分内容」或「多节连读」的场景。为控制耗时，窗口按 [step] 滑动。
  ///
  /// @param query 识别文本
  /// @param target 经文文本（更长）
  /// @param step 窗口滑动步长（字符），默认按窗口长度的 1/4
  /// @return 最佳相似度 0..1
  static double fragmentScore(String query, String target, {int? step}) {
    if (query.isEmpty || target.isEmpty) return 0.0;
    var short = query;
    var long = target;
    if (short.length > long.length) {
      final swap = short;
      short = long;
      long = swap;
    }
    final window = short.length;
    if (window == 0) return 0.0;

    final stride = step ?? (window ~/ 4).clamp(1, window);
    var best = 0.0;
    final limit = long.length - window;
    for (var i = 0; i <= limit; i += stride) {
      final score = ratio(short, long.substring(i, i + window));
      if (score > best) {
        best = score;
        if (best == 1.0) break;
      }
    }
    return best;
  }

  /// 综合文本得分：整体相似度与片段相似度加权。
  ///
  /// @param decoded 识别文本（已归一化）
  /// @param verseText 经文文本（已归一化）
  /// @return 0..1 的文本得分
  static double textScore(String decoded, String verseText) {
    return 0.55 * ratio(decoded, verseText) +
        0.45 * fragmentScore(decoded, verseText);
  }
}
