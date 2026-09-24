/// 用本项目同一套指标（[WordAlignment]）计算 Tilawa 侧结果，便于与真机实测对比。
///
/// 为什么单独做这个脚本：直接拿两个工程各自报的数字比是不公平的 —— 指标口径
/// （判定阈值、近似词半分、覆盖率/准确率的定义）必须一致。这里对 **同一批语料、
/// 同一份经文库原文**，用同一份 [WordAlignment] 同时算两侧：
///
/// - 转写稿口径与语料验证页一致：识别到的章节 → 展开成节 → 按「新覆盖到的节」累加
///   → 取这些节的标准经文词序列；
/// - 原文口径也一致：期望区间的标准经文，并提供「去掉太斯米前缀」变体，取 F1 更高者。
///
/// 用法：
///   dart run tool/tilawa_compare_metrics.dart /tmp/tilawa_bench.json [/tmp/ours_bench.json]
///
/// `ours_bench.json` 形如：
///   [{"clip": "...", "refs": ["36:1", "36:1-2", "1:1", ...]}, ...]
library;

// 命令行工具：输出走 stdout
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:quran_broadcast_sdk/quran_offline/quran_text.dart';
import 'package:quran_broadcast_sdk/quran_offline/word_alignment.dart';

/// 太斯米（归一化词形，与经文库 `text_clean` 一致）。
const List<String> _bismillah = <String>['بسم', 'الله', 'الرحمن', 'الرحيم'];

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('用法：dart run tool/tilawa_compare_metrics.dart <tilawa_bench.json> [ours_bench.json]');
    exit(2);
  }
  final lexicon = _loadLexicon('assets/quran_offline/quran.json');
  final tilawa = jsonDecode(File(args[0]).readAsStringSync()) as Map<String, Object?>;
  final ours = args.length > 1
      ? (jsonDecode(File(args[1]).readAsStringSync()) as List<Object?>)
      : const <Object?>[];

  print('说明：两侧指标均由本项目 WordAlignment 计算（阈值一致 / 近似词半分口径一致）');
  print('经文库：${lexicon.length} 节\n');

  final rows = <_Row>[];
  for (final raw in tilawa['results']! as List<Object?>) {
    final result = raw! as Map<String, Object?>;
    final clip = result['clip']! as String;
    final expected = (result['expectedRefs']! as List<Object?>).cast<String>();
    final tilawaRefs = <String>[
      for (final m in (result['verseMatches']! as List<Object?>))
        '${(m! as Map<String, Object?>)['surah']}:${(m as Map<String, Object?>)['ayah']}',
    ];
    final oursEntry = ours.cast<Map<String, Object?>>().where((e) => e['clip'] == clip).toList();
    final oursRefs = oursEntry.isEmpty
        ? const <String>[]
        : (oursEntry.first['refs']! as List<Object?>).cast<String>();

    rows.add(
      _Row(
        clip: clip,
        expected: expected,
        durationSec: (result['durationSec']! as num).toDouble(),
        tilawaRefs: tilawaRefs,
        oursRefs: oursRefs,
      ),
    );
  }

  print('${'语料'.padRight(28)}'
      '${'实现'.padRight(8)}'
      '${'章节命中'.padRight(10)}'
      '${'一致'.padRight(6)}'
      '${'近似'.padRight(6)}'
      '${'缺失'.padRight(6)}'
      '${'多余'.padRight(6)}'
      '${'覆盖率'.padRight(9)}'
      '${'准确率'.padRight(9)}'
      '${'F1'.padRight(7)}结论');
  for (final row in rows) {
    _printMetrics(row, 'Tilawa', row.tilawaRefs, lexicon, row.expected);
    if (row.oursRefs.isNotEmpty) {
      _printMetrics(row, '本项目', row.oursRefs, lexicon, row.expected);
    } else {
      print('${row.clip.padRight(28)}${'本项目'.padRight(8)}（未提供识别序列，见真机日志实测值）');
    }
    print('');
  }
}

/// 打印一侧的指标行。
void _printMetrics(
  _Row row,
  String label,
  List<String> refs,
  Map<String, List<String>> lexicon,
  List<String> expected,
) {
  final variants = _referenceVariants(_wordsOfRange(lexicon, expected));
  final transcript = _transcriptFromRefs(lexicon, refs);
  var best = WordAlignment.align(variants.first, transcript);
  for (final variant in variants.skip(1)) {
    final candidate = WordAlignment.align(variant, transcript);
    if (candidate.f1 > best.f1) best = candidate;
  }
  final covered = _coveredAyahs(refs);
  final matched = expected.where(covered.contains).length;
  print('${row.clip.padRight(28)}'
      '${label.padRight(8)}'
      '${'$matched/${expected.length}'.padRight(10)}'
      '${'${best.matchCount}'.padRight(6)}'
      '${'${best.nearCount}'.padRight(6)}'
      '${'${best.missingCount}'.padRight(6)}'
      '${'${best.extraCount}'.padRight(6)}'
      '${best.coverage.toStringAsFixed(3).padRight(9)}'
      '${best.precision.toStringAsFixed(3).padRight(9)}'
      '${best.f1.toStringAsFixed(3).padRight(7)}${best.verdict}');
}

/// 一行对比数据。
class _Row {
  const _Row({
    required this.clip,
    required this.expected,
    required this.durationSec,
    required this.tilawaRefs,
    required this.oursRefs,
  });

  final String clip;
  final List<String> expected;
  final double durationSec;
  final List<String> tilawaRefs;
  final List<String> oursRefs;
}

/// 读取经文库：`surah:ayah` → 归一化词序列。
Map<String, List<String>> _loadLexicon(String path) {
  final raw = jsonDecode(File(path).readAsStringSync()) as List<Object?>;
  final map = <String, List<String>>{};
  for (final item in raw) {
    final verse = item! as Map<String, Object?>;
    final clean = (verse['text_clean'] as String?) ?? (verse['text_uthmani'] as String? ?? '');
    map['${verse['surah']}:${verse['ayah']}'] =
        QuranText.normalize(clean).split(' ').where((word) => word.isNotEmpty).toList();
  }
  return map;
}

/// 期望区间的标准经文词序列。
List<String> _wordsOfRange(Map<String, List<String>> lexicon, List<String> refs) =>
    <String>[for (final ref in refs) ...(lexicon[ref] ?? const <String>[])];

/// 识别序列 → 转写稿词序列（按「新覆盖到的节」累加，与语料验证页同一口径）。
List<String> _transcriptFromRefs(Map<String, List<String>> lexicon, List<String> refs) {
  final covered = <String>{};
  final words = <String>[];
  for (final ref in refs) {
    for (final ayahRef in _expand(ref)) {
      if (covered.add(ayahRef)) words.addAll(lexicon[ayahRef] ?? const <String>[]);
    }
  }
  return words;
}

/// 识别引用覆盖到的节集合。
Set<String> _coveredAyahs(List<String> refs) =>
    <String>{for (final ref in refs) ..._expand(ref)};

/// 展开引用（支持 `surah:ayah` 与 `surah:start-end`）。
List<String> _expand(String ref) {
  final parts = ref.split(':');
  if (parts.length != 2) return const <String>[];
  final surah = int.tryParse(parts[0]);
  if (surah == null) return const <String>[];
  final range = parts[1].split('-');
  final start = int.tryParse(range.first);
  final end = int.tryParse(range.last);
  if (start == null || end == null) return const <String>[];
  return <String>[for (var ayah = start; ayah <= end; ayah++) '$surah:$ayah'];
}

/// 原文变体：完整 / 去掉太斯米前缀（与 `CorpusCatalog.referenceVariants` 同一规则）。
List<List<String>> _referenceVariants(List<String> words) {
  if (words.length <= _bismillah.length) return <List<String>>[words];
  for (var i = 0; i < _bismillah.length; i++) {
    if (words[i] != _bismillah[i]) return <List<String>>[words];
  }
  return <List<String>>[words, words.sublist(_bismillah.length)];
}
