/// 流式转写拼接：把逐窗重复识别得到的文本合并成一份连续转写稿。
///
/// 背景：流式会话每次触发都对「最近最多 15 秒」的窗口重新识别
/// （见 `quran_recognizer.dart`），相邻两轮结果高度重叠。若直接首尾相接，
/// 同一段话会被重复计入，比对时分母虚高、指标失真。
///
/// 策略：以「词」为单位比较归一化文本，取新片段头部与已累积文本尾部的
/// **最长重叠**，只追加重叠之后的部分；新片段整体已被包含时不追加
/// （对应「窗口向前滑动但内容没变长」的情况）。
library;

import 'package:quran_broadcast_sdk/quran_offline/quran_text.dart';

/// 连续转写稿的增量拼接器。
class TranscriptStitcher {
  /// 构造拼接器。
  ///
  /// @param maxOverlapWords 参与重叠搜索的最大词数（限制单次搜索开销）
  /// @param minOverlapWords 认定重叠所需的最少词数（过小易误合并同形词）
  TranscriptStitcher({this.maxOverlapWords = 80, this.minOverlapWords = 2});

  /// 参与重叠搜索的最大词数。
  final int maxOverlapWords;

  /// 认定重叠所需的最少词数。
  final int minOverlapWords;

  final List<String> _words = <String>[];
  final List<String> _normalized = <String>[];

  /// 累积的转写词（保留识别输出的书写形式）。
  List<String> get words => List<String>.unmodifiable(_words);

  /// 累积的转写文本（空格分隔）。
  String get text => _words.join(' ');

  /// 是否还没有任何内容。
  bool get isEmpty => _words.isEmpty;

  /// 已累积词数。
  int get length => _words.length;

  /// 并入一段识别文本。
  ///
  /// @param segment 本轮识别出的文本（可能是整段窗口内容）
  /// @return 实际追加的词数（0 表示该段已被覆盖）
  int add(String segment) {
    final parts = segment
        .split(RegExp(r'\s+'))
        .map((word) => word.trim())
        .where((word) => word.isNotEmpty)
        .toList(growable: false);
    if (parts.isEmpty) return 0;

    final normalized = parts.map(QuranText.normalize).toList(growable: false);
    final overlap = _longestOverlap(normalized);
    // 整段都已在尾部出现过：不追加
    if (overlap >= normalized.length) return 0;

    final appended = parts.sublist(overlap);
    _words.addAll(appended);
    _normalized.addAll(normalized.sublist(overlap));
    return appended.length;
  }

  /// 清空累积内容（开始新一轮诵读时调用）。
  void reset() {
    _words.clear();
    _normalized.clear();
  }

  /// 求新片段头部与已累积文本尾部的最大重叠词数。
  ///
  /// 返回值为「新片段头部有多少个词已经被累积文本覆盖」。
  int _longestOverlap(List<String> normalized) {
    final maxWords = normalized.length < maxOverlapWords ? normalized.length : maxOverlapWords;
    final limit = maxWords < _normalized.length ? maxWords : _normalized.length;
    for (var k = limit; k >= 1; k--) {
      // 少于 minOverlapWords 的重叠只在「整段被包含」时才采纳
      if (k < minOverlapWords && k != normalized.length) continue;
      var same = true;
      for (var i = 0; i < k; i++) {
        if (_normalized[_normalized.length - k + i] != normalized[i]) {
          same = false;
          break;
        }
      }
      if (same) return k;
    }
    return 0;
  }
}
