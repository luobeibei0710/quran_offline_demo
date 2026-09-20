/// 语料验证页：**选中一段语料 → 音频灌入引擎 → 与语料原文逐词比对**。
///
/// 与主界面的分工：
/// - 主界面 = 实时链路（麦克风采集 → 流式识别），显示不受本页影响；
/// - 本页 = 准确度验证链路，**不使用麦克风**，把已知原文的语料音频按实时节奏
///   直接喂入同一套流式会话，因此结果只反映「引擎 + 算法」，与抓音质量无关。
///
/// 跑完自动进入 [QuranComparePage]（左原文 / 右转写），回到本页后列表上会保留
/// 该条语料的命中情况与 F1。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'corpus_audio.dart';
import 'corpus_catalog.dart';
import 'corpus_runner.dart';
import 'quran_assets.dart';
import 'quran_compare_page.dart';
import 'quran_recognizer.dart';
import 'reference_text.dart';
import 'word_alignment.dart';

/// 一条语料的加载结果。
class _CorpusEntry {
  _CorpusEntry({
    required this.item,
    this.samples,
    this.references,
    this.error,
    this.surahName = '',
  });

  /// 语料定义。
  final CorpusItem item;

  /// 已解码的采样（加载失败时为 null）。
  final Float32List? samples;

  /// 候选原文（第一条为经文库/文件的完整原文，可能还有「去掉太斯米前缀」变体）。
  final List<ReferenceText>? references;

  /// 加载/解析失败原因。
  final String? error;

  /// 章名（区间来源时用于展示）。
  final String surahName;

  /// 主原文。
  ReferenceText? get reference =>
      references == null || references!.isEmpty ? null : references!.first;

  /// 是否可用。
  bool get usable => error == null && samples != null && reference != null;
}

/// 一次灌音的结果与比对指标。
class _RunOutcome {
  const _RunOutcome({required this.result, required this.alignment});

  /// 灌音结果。
  final CorpusRunResult result;

  /// 与语料原文的比对指标。
  final AlignmentResult alignment;
}

/// 语料验证页。
class CorpusVerifyPage extends StatefulWidget {
  /// 构造语料验证页。
  ///
  /// @param assets 已加载的数据资产（用于取官方语料的标准经文）
  /// @param recognizer 已加载模型的识别器
  /// @param catalogLoader 语料清单加载（测试可注入）
  /// @param audioLoader 音频字节读取（测试可注入）
  /// @param referenceLoader 原文加载（测试可注入）
  /// @param chunkMs 灌音分块时长，测试可调小以加速
  /// @param autoRunAll 加载完成后自动跑一遍全部可用语料（无人值守验证用）
  const CorpusVerifyPage({
    super.key,
    required this.assets,
    required this.recognizer,
    this.catalogLoader,
    this.audioLoader,
    this.referenceLoader,
    this.chunkMs = 20,
    this.autoRunAll = false,
  });

  /// 数据资产。
  final QuranAssets assets;

  /// 识别器。
  final QuranRecognizer recognizer;

  /// 语料清单加载实现。
  final Future<List<CorpusItem>> Function()? catalogLoader;

  /// 音频读取实现（返回 WAV 字节）。
  final Future<Uint8List> Function(CorpusAudioSource source)? audioLoader;

  /// 原文加载实现。
  final Future<ReferenceText> Function(CorpusReference reference)? referenceLoader;

  /// 灌音分块时长（毫秒）。
  final int chunkMs;

  /// 加载完成后是否自动跑一遍全部可用语料。
  final bool autoRunAll;

  @override
  State<CorpusVerifyPage> createState() => _CorpusVerifyPageState();
}

class _CorpusVerifyPageState extends State<CorpusVerifyPage> {
  final List<String> _logs = <String>[];
  final Map<String, _RunOutcome> _outcomes = <String, _RunOutcome>{};

  List<_CorpusEntry> _entries = const <_CorpusEntry>[];
  bool _loading = true;
  String? _loadError;
  String? _runningId;
  double _progress = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 加载清单、音频与原文。
  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final items = await (widget.catalogLoader ?? CorpusCatalog.load)();
      final entries = <_CorpusEntry>[];
      for (final item in items) {
        entries.add(await _loadEntry(item));
      }
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _loading = false;
      });
      final usable = entries.where((entry) => entry.usable).length;
      _log('语料清单加载完成：$usable/${entries.length} 条可用');
      for (final entry in entries.where((entry) => !entry.usable)) {
        _log('${entry.item.title} 不可用：${entry.error}');
      }
      if (widget.autoRunAll && usable > 0) {
        await _runAll();
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = '$error';
        _loading = false;
      });
    }
  }

  /// 加载单条语料（音频解码 + 原文解析）。
  Future<_CorpusEntry> _loadEntry(CorpusItem item) async {
    try {
      final bytes = await _readAudio(item.audio);
      final samples = CorpusAudio.decodeWav(bytes);
      final reference = await _loadReference(item.reference);
      return _CorpusEntry(
        item: item,
        samples: samples,
        references: CorpusCatalog.referenceVariants(reference),
        surahName: item.reference.isRange
            ? (widget.assets
                    .verse(item.reference.surah!, item.reference.ayahStart)
                    ?.surahName ??
                '')
            : '',
      );
    } catch (error) {
      return _CorpusEntry(item: item, error: '$error');
    }
  }

  /// 读取音频字节：内置资产或设备文件（按顺序尝试）。
  Future<Uint8List> _readAudio(CorpusAudioSource source) async {
    final injected = widget.audioLoader;
    if (injected != null) return injected(source);
    final assetKey = source.assetKey;
    if (assetKey != null) {
      final data = await rootBundle.load(assetKey);
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    }
    for (final path in source.filePaths) {
      final file = File(path);
      if (await file.exists()) return file.readAsBytes();
    }
    throw StateError('设备上找不到音频：${source.filePaths.join(' 或 ')}');
  }

  /// 解析原文：区间取经文库标准经文拼接；自定义语料用同名 txt（回退内置资产）。
  Future<ReferenceText> _loadReference(CorpusReference reference) async {
    final injected = widget.referenceLoader;
    if (injected != null) return injected(reference);
    if (reference.isRange) {
      final surah = reference.surah!;
      final words = <String>[];
      final uthmani = <String>[];
      for (var ayah = reference.ayahStart; ayah <= reference.ayahEnd; ayah++) {
        final verse = widget.assets.verse(surah, ayah);
        if (verse == null) throw StateError('经文库缺少 $surah:$ayah');
        words.addAll(verse.words);
        uthmani.add(verse.textUthmani);
      }
      return ReferenceText(
        words: words,
        rawText: uthmani.join(' '),
        source: '经文库标准经文 · ${reference.label}',
      );
    }
    return ReferenceText.load();
  }

  /// 依次灌音全部可用语料并汇总命中情况（不逐条进入比对页）。
  Future<void> _runAll() async {
    if (_runningId != null) return;
    final usable = _entries.where((entry) => entry.usable).toList();
    if (usable.isEmpty) return;
    _log('开始批量灌音：共 ${usable.length} 条');
    var fullHit = 0;
    var judged = 0;
    var matchedAyahs = 0;
    var totalAyahs = 0;
    for (final entry in usable) {
      if (!mounted) return;
      await _run(entry, openCompare: false);
      final result = _outcomes[entry.item.id]?.result;
      if (result == null || result.expectedRefs.isEmpty) continue;
      judged++;
      matchedAyahs += result.matchedRefs.length;
      totalAyahs += result.expectedRefs.length;
      if (result.hit == true) fullHit++;
    }
    _log('语料验证完成：章节命中 $matchedAyahs/$totalAyahs 节；整段全中 $fullHit/$judged 条');
  }

  /// 灌音一条语料，跑完与原文比对，并按需进入比对页。
  ///
  /// @param entry 语料条目
  /// @param openCompare 是否自动进入比对页（批量模式下为 false）
  Future<void> _run(_CorpusEntry entry, {bool openCompare = true}) async {
    final samples = entry.samples;
    final reference = entry.reference;
    if (_runningId != null || samples == null || reference == null) return;

    setState(() {
      _runningId = entry.item.id;
      _progress = 0;
      _logs.clear();
    });
    _log('开始灌音：${entry.item.title}（${CorpusAudio.durationSeconds(samples).toStringAsFixed(1)}s）');

    final runner = CorpusRunner(
      recognizer: widget.recognizer,
      samples: samples,
      expectedRefs: entry.item.expectedRefs,
      chunkMs: widget.chunkMs,
    );
    CorpusRunResult result;
    try {
      result = await runner.run(onProgress: _onProgress);
    } catch (error) {
      if (!mounted) return;
      setState(() => _runningId = null);
      _log('灌音失败：$error');
      return;
    }
    if (!mounted) return;

    // 原文可能有多个变体（见 [CorpusCatalog.referenceVariants]）：取与音频更贴合的那个
    final variants = entry.references!;
    var chosen = variants.first;
    var alignment = WordAlignment.align(chosen.words, result.transcriptWords);
    for (final candidate in variants.skip(1)) {
      final candidateAlignment = WordAlignment.align(candidate.words, result.transcriptWords);
      if (candidateAlignment.f1 > alignment.f1) {
        chosen = candidate;
        alignment = candidateAlignment;
      }
    }
    setState(() {
      _runningId = null;
      _progress = 1;
      _outcomes[entry.item.id] = _RunOutcome(result: result, alignment: alignment);
    });
    if (!identical(chosen, variants.first)) {
      _log('原文采用变体：${chosen.source}');
    }

    _log('转写稿 ${result.transcriptWords.length} 词（稳定命中 ${result.transcriptRefs.length} 节）· '
        '逐词原始输出 ${result.rawTranscriptWords.length} 词 · 事件 ${result.eventCount} 次 · '
        '耗时 ${(result.elapsed.inMilliseconds / 1000).toStringAsFixed(1)}s'
        '${result.advancedSeconds > 0 ? ' · 窗口前移 ${result.advancedSeconds.toStringAsFixed(1)}s' : ''}');
    _log('稳定命中：${result.stableRefs.isEmpty ? '无' : result.stableRefs.join(' → ')}');
    _log('识别章节（含瞬时）：${result.seenRefs.isEmpty ? '无' : result.seenRefs.join(' → ')}');
    _log('比对 原文${alignment.referenceCount}词/转写${alignment.hypothesisCount}词 '
        'F1=${alignment.f1.toStringAsFixed(3)} '
        '覆盖率=${alignment.coverage.toStringAsFixed(3)} '
        '准确率=${alignment.precision.toStringAsFixed(3)} '
        '一致=${alignment.matchCount} 近似=${alignment.nearCount} '
        '错配=${alignment.mismatchCount} 缺失=${alignment.missingCount} 多余=${alignment.extraCount} '
        '结论=${alignment.verdict}');

    if (!openCompare) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => QuranComparePage(
          hypothesisWords: result.transcriptWords,
          referenceLoader: () async => chosen,
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  /// 灌音进度回调：刷新进度条并记录稳定/已确认事件。
  void _onProgress(CorpusRunProgress progress) {
    if (!mounted) return;
    setState(() => _progress = progress.fraction);
    final event = progress.event;
    if (event == null) return;
    final ref = event.match.champion?.ref;
    if (event.justCommitted) {
      _log('已确认 ${event.committedRef}（累计 ${event.committedSequence.length} 节'
          '${event.advancedSeconds > 0 ? '，窗口前移 ${event.advancedSeconds.toStringAsFixed(1)}s' : ''}）');
    } else if (event.stable && ref != null) {
      _log('稳定 $ref（读 ${event.readWords}/${event.words.length} 词）');
    }
  }

  /// 追加一行日志（只保留最近若干条）。
  void _log(String message) {
    debugPrint('[QuranCorpus] $message');
    if (!mounted) return;
    setState(() {
      _logs.add(message);
      if (_logs.length > 60) _logs.removeAt(0);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('语料验证'),
        actions: [
          // 一键跑完所有可用语料：得到官方语料的命中率与逐条比对指标
          IconButton(
            tooltip: '全部跑一遍（汇总命中率）',
            onPressed: _loading || _runningId != null ? null : _runAll,
            icon: const Icon(Icons.playlist_play),
          ),
          IconButton(
            tooltip: '重新加载语料清单',
            onPressed: _loading || _runningId != null ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(child: Text('正在加载语料…'));
    }
    final error = _loadError;
    if (error != null) {
      return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(error)));
    }
    return Column(
      children: [
        if (_runningId != null) LinearProgressIndicator(value: _progress),
        _buildHint(context),
        Expanded(child: ListView.builder(itemCount: _entries.length, itemBuilder: _buildRow)),
        _buildLogs(context),
      ],
    );
  }

  Widget _buildHint(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '不使用麦克风：选中语料后把音频按实时节奏灌入引擎，跑完与语料原文逐词比对。',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          Text(
            '内置语料由 tools/quran_offline/download_corpus.sh 生成（多节连续诵读）；'
            '自定义语料把 16 kHz/单声道/16bit 的 WAV 推到 files/corpus/（可带同名 .txt 作为原文）',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
        ],
      ),
    );
  }

  Widget _buildRow(BuildContext context, int index) {
    final entry = _entryForIndex(index);
    final theme = Theme.of(context);
    final outcome = _outcomes[entry.item.id];
    final running = _runningId == entry.item.id;
    final source = entry.reference?.source ?? entry.item.reference.label;

    Widget trailing;
    if (entry.error != null) {
      trailing = Icon(Icons.error_outline, color: theme.colorScheme.error);
    } else if (running) {
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(value: _progress, strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Text('${(_progress * 100).round()}%'),
        ],
      );
    } else if (outcome != null) {
      final result = outcome.result;
      final judged = result.expectedRefs.isNotEmpty;
      final hit = result.hit;
      trailing = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text('F1=${outcome.alignment.f1.toStringAsFixed(2)}',
              style: theme.textTheme.labelLarge),
          Text(
            judged
                ? '章节 ${result.matchedRefs.length}/${result.expectedRefs.length}'
                : outcome.alignment.verdict,
            style: theme.textTheme.labelSmall?.copyWith(
              color: judged
                  ? (hit == true ? Colors.green.shade700 : theme.colorScheme.error)
                  : null,
            ),
          ),
        ],
      );
    } else {
      trailing = const Icon(Icons.play_circle_outline);
    }

    final subtitle = entry.error != null
        ? entry.error!
        : '${CorpusAudio.durationSeconds(entry.samples!).toStringAsFixed(1)}s · '
            '原文 ${entry.reference!.words.length} 词 · $source';

    return ListTile(
      enabled: entry.usable && _runningId == null,
      onTap: entry.usable ? () => _run(entry) : null,
      title: Text(
        entry.surahName.isEmpty ? entry.item.title : '${entry.item.title} · ${entry.surahName}',
      ),
      subtitle: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: trailing,
      isThreeLine: false,
    );
  }

  /// 列表索引到条目（防御越界）。
  _CorpusEntry _entryForIndex(int index) => _entries[index];

  Widget _buildLogs(BuildContext context) {
    final theme = Theme.of(context);
    final lines = _logs.length > 6 ? _logs.sublist(_logs.length - 6) : _logs;
    return Container(
      height: 96,
      width: double.infinity,
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('日志', style: theme.textTheme.labelSmall),
          const SizedBox(height: 2),
          Expanded(
            child: Text(
              lines.isEmpty ? '（待运行）' : lines.join('\n'),
              style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
              maxLines: 5,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
