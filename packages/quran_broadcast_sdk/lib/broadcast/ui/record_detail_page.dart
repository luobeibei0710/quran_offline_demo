/// 记录详情：三类文本快照、匹配范围、比对指标、逐词差异与诊断参数。
///
/// 详情页不做任何重算：原文、转写、指标与译文都来自落库快照，因此历史不会
/// 因新版经文或当前语言而悄悄变化。无可信匹配时原文与指标显示「不可用」，
/// 而不是 0 分。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../broadcast_services.dart';
import '../data/record_repository.dart';
import '../domain/utterance_record.dart';
import 'widgets/text_section_card.dart';

/// 记录详情页。
class RecordDetailPage extends StatefulWidget {
  /// 构造详情页。
  ///
  /// @param services 依赖集合
  /// @param recordId 记录业务标识
  /// @param onChanged 记录变更后的回调（用于刷新列表）
  const RecordDetailPage({
    super.key,
    required this.services,
    required this.recordId,
    this.onChanged,
  });

  /// 依赖集合。
  final BroadcastServices services;

  /// 记录标识。
  final String recordId;

  /// 变更回调。
  final Future<void> Function()? onChanged;

  @override
  State<RecordDetailPage> createState() => _RecordDetailPageState();
}

class _RecordDetailPageState extends State<RecordDetailPage> {
  UtteranceRecord? _record;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final record = await widget.services.records.byId(widget.recordId);
    if (!mounted) return;
    setState(() {
      _record = record;
      _loading = false;
    });
  }

  Future<void> _retry(TargetLanguage language) async {
    final record = _record;
    if (record == null) return;
    setState(() => _busy = true);
    await widget.services.translations.retry(record.id, language);
    await widget.services.drainTranslations();
    await _load();
    await widget.onChanged?.call();
    if (mounted) setState(() => _busy = false);
  }

  /// 为同一记录追加另一种语言版本（不覆盖原语言）。
  Future<void> _addLanguage(TargetLanguage language) async {
    final record = _record;
    if (record == null) return;
    if (record.translationFor(language) != null) return;
    setState(() => _busy = true);
    await widget.services.records.save(
      RecordDraft(
        sessionId: record.sessionId,
        utteranceId: record.utteranceId,
        revision: record.revision,
        startSample: record.startSample,
        endSample: record.endSample,
        sampleRate: record.sampleRate,
        boundaryReason: record.boundaryReason,
        rawAsrText: record.rawAsrText,
        targetLanguage: language,
        matchStatus: record.matchStatus,
        scope: record.scope,
        matches: record.matches,
        metrics: record.metrics,
        job: TranslationJob(
          id: 'job-${UtteranceRecord.newUuid()}',
          recordId: record.id,
          revision: record.revision,
          targetLanguage: language,
          provider: widget.services.engine.engineId,
          sourceHash: 'append',
          state: TranslationJobState.pending,
          attemptCount: 0,
          createdAt: DateTime.now().toUtc(),
        ),
      ),
    );
    await widget.services.drainTranslations();
    await _load();
    await widget.onChanged?.call();
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final record = _record;
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (record == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('记录详情')),
        body: const Center(child: Text('记录不存在或已被删除')),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text('#${record.displaySequence.toString().padLeft(6, '0')}'),
        actions: <Widget>[
          PopupMenuButton<TargetLanguage>(
            enabled: !_busy,
            tooltip: '追加语言版本',
            icon: const Icon(Icons.translate),
            onSelected: (language) => unawaited(_addLanguage(language)),
            itemBuilder: (context) => <PopupMenuEntry<TargetLanguage>>[
              for (final language in TargetLanguage.all)
                PopupMenuItem<TargetLanguage>(
                  value: language,
                  enabled: record.translationFor(language) == null,
                  child: Text('追加 ${language.displayName}'),
                ),
            ],
          ),
        ],
      ),
      body: ListView(
        children: <Widget>[
          _buildHeader(record),
          TextSectionCard(
            title: '识别转写',
            subtitle: '阿拉伯语 · 实际 ASR（未被经文替换）',
            body: record.rawAsrText,
            rtl: true,
            emptyHint: '该记录没有可用转写',
          ),
          _buildMatchCard(record),
          _buildTranslationCard(record),
          _buildMetricsCard(record),
          if (record.metrics?.alignmentJson != null) _buildAlignmentCard(record),
          _buildDiagnosticsCard(record),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildHeader(UtteranceRecord record) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '${record.createdAt.toLocal().toString().substring(0, 19)} · '
            '${record.startSeconds.toStringAsFixed(2)}–${record.endSeconds.toStringAsFixed(2)}s · '
            '结束原因：${record.boundaryReason.wireName}',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 2),
          Text(
            '源语言 $broadcastSourceLanguage → 目标语言 ${record.targetLanguage.displayName} · '
            '修订 ${record.revision} · 语料 ${widget.services.library.manifest.corpusId}',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
        ],
      ),
    );
  }

  Widget _buildMatchCard(UtteranceRecord record) {
    final matches = record.matches;
    final body = matches.isEmpty
        ? ''
        : <String>[for (final match in matches) match.canonicalTextSnapshot].join('\n\n');
    return TextSectionCard(
      title: '匹配经文',
      subtitle: matches.isEmpty
          ? (record.matchStatus == MatchStatus.candidate ? '候选经文' : '未匹配经文')
          : '${record.matchSummary} · 语料版本 ${matches.first.corpusVersion} · '
                '${matches.any((match) => !match.isWholeVerse) ? '部分节' : '完整节'}',
      body: body,
      rtl: true,
      emptyHint: '未匹配经文：本记录只有实际转写与机器翻译，不猜测经文章节。',
      footnote: matches.isEmpty
          ? null
          : <String>[
              for (final match in matches) match.label,
            ].join('、'),
    );
  }

  Widget _buildTranslationCard(UtteranceRecord record) {
    final translation = record.translationFor(record.targetLanguage);
    if (translation == null) {
      return TextSectionCard(
        title: '目标译文',
        subtitle: '${record.targetLanguage.displayName} · 待生成',
        body: '',
        emptyHint: '该语言版本尚未生成，可通过右上角菜单追加。',
        onRetry: _busy ? null : () => unawaited(_retry(record.targetLanguage)),
      );
    }
    return TextSectionCard(
      title: '目标译文',
      subtitle: '${record.targetLanguage.displayName} · ${translation.status.label}'
          '${switch (translation.inputScope) {
            'confirmedRange' => ' · 仅已确认范围',
            'fullVerseContext' => ' · 整节译文（上下文）',
            'asr' => ' · 输入为识别转写',
            _ => '',
          }}',
      body: translation.status == TranslationStatus.done ? translation.text : '',
      badge: translation.sourceKind.label,
      badgeColor: translation.sourceKind == TranslationSourceKind.curatedEdition
          ? Colors.teal
          : Colors.orange.shade800,
      emptyHint: switch (translation.status) {
        TranslationStatus.modelMissing => '缺少离线语言包，运行期不降级到云翻译。',
        TranslationStatus.failed => '翻译失败：${translation.errorCode ?? '未知原因'}。',
        TranslationStatus.running => '正在翻译…',
        TranslationStatus.pending => '等待翻译…',
        TranslationStatus.done => '',
      },
      footnote: '来源：${translation.sourceLabel}\n'
          '输入范围：${translation.inputScope} · 输入哈希：${translation.sourceHash}',
      onRetry: translation.status.canRetry && !_busy
          ? () => unawaited(_retry(record.targetLanguage))
          : null,
    );
  }

  Widget _buildMetricsCard(UtteranceRecord record) {
    final metrics = record.metrics;
    final theme = Theme.of(context);
    String format(double? value) => value == null ? '不可用' : value.toStringAsFixed(3);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('比对指标', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 2),
            Text(
              metrics == null
                  ? '本记录没有可信参考，指标不可用'
                  : '范围 ${metrics.metricScope} · 口径 ${metrics.normalizationVersion}',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
            ),
            const Divider(height: 16),
            Wrap(
              spacing: 20,
              runSpacing: 8,
              children: <Widget>[
                _metric('匹配准确率 P', format(metrics?.precision)),
                _metric('覆盖率 R', format(metrics?.recall)),
                _metric('F1', format(metrics?.f1)),
                _metric('严格 WER', format(metrics?.strictWer)),
                _metric('替换 S', metrics?.substitutions?.toString() ?? '不可用'),
                _metric('缺失 D', metrics?.deletions?.toString() ?? '不可用'),
                _metric('多余 I', metrics?.insertions?.toString() ?? '不可用'),
                _metric('参考词数', metrics?.referenceWords?.toString() ?? '不可用'),
                _metric('转写词数', metrics?.hypothesisWords?.toString() ?? '不可用'),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '说明：P/R/F1 是「转写与候选原文的一致性」，不是已知正确答案下的独立 ASR 准确率；'
              '严格 WER 按精确词计算，可能超过 100%。',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
            ),
          ],
        ),
      ),
    );
  }

  Widget _metric(String label, String value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      Text(label, style: const TextStyle(fontSize: 11, color: Colors.black54)),
      Text(value, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
    ],
  );

  Widget _buildAlignmentCard(UtteranceRecord record) {
    final rows = (jsonDecode(record.metrics!.alignmentJson!) as List<dynamic>)
        .cast<Map<String, dynamic>>();
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('原文 / 转写逐词比对', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: <Widget>[
                for (final row in rows) _wordChip(row),
              ],
            ),
            const SizedBox(height: 10),
            const Text(
              '一致 = 绿；近似 = 黄；错配 = 红；缺失（原文有、转写无）= 灰；多余（转写有）= 橙',
              style: TextStyle(fontSize: 11, color: Colors.black54),
            ),
          ],
        ),
      ),
    );
  }

  Widget _wordChip(Map<String, dynamic> row) {
    final status = row['status'] as String? ?? 'mismatch';
    final reference = row['reference'] as String?;
    final hypothesis = row['hypothesis'] as String?;
    final color = switch (status) {
      'match' => Colors.green,
      'near' => Colors.amber.shade700,
      'mismatch' => Colors.red,
      'missing' => Colors.blueGrey,
      'extra' => Colors.orange,
      _ => Colors.grey,
    };
    final text = reference != null && hypothesis != null && reference != hypothesis
        ? '$reference→$hypothesis'
        : (reference ?? hypothesis ?? '');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Directionality(
        textDirection: TextDirection.rtl,
        child: Text(text, style: TextStyle(fontSize: 15, color: color)),
      ),
    );
  }

  Widget _buildDiagnosticsCard(UtteranceRecord record) {
    final evidence = record.matcherEvidenceJson;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: ExpansionTile(
        title: const Text('开发诊断'),
        subtitle: const Text('候选分数、拒识原因、匹配证据与耗时', style: TextStyle(fontSize: 12)),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: <Widget>[
          Align(
            alignment: Alignment.centerLeft,
            child: SelectableText(
              '匹配证据：${evidence ?? '无'}\n'
              '各阶段耗时：${record.processingMs ?? '无'}\n'
              '边界：${record.boundaryReason.wireName}\n'
              '状态：${record.matchStatus.name} / ${record.scope.wireName}',
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
            ),
          ),
        ],
      ),
    );
  }
}
