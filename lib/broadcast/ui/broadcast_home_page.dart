/// 广播识别首页：转写 → 匹配经文 → 目标译文 三栏，加收音控制与历史入口。
///
/// 界面约束（与实施方案 §3.1 一致）：
///
/// - 三类文本各自一块完整卡片，纵向可滚动；不固定高度导致长经文被截断；
/// - 阿拉伯卡局部 RTL，界面整体保持中文方向；显示不运行 `arabic_reshaper`，
///   直接使用上游 Unicode 文本交给系统排版；
/// - 识别中文案为当前片段草稿，确认后自动留存并清空草稿；
/// - 空闲时显示简短说明与资源就绪状态；运行中禁止切换目标语言。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../application/broadcast_session_controller.dart';
import '../broadcast_services.dart';
import '../domain/utterance_record.dart';
import '../translation/offline_translation_engine.dart';
import '../../quran_offline/quran_offline_demo_page.dart';
import 'record_detail_page.dart';
import 'record_list_page.dart';
import 'widgets/text_section_card.dart';

/// 广播识别首页。
class BroadcastHomePage extends StatefulWidget {
  /// 构造首页。
  ///
  /// @param services 已初始化的依赖集合
  const BroadcastHomePage({super.key, required this.services});

  /// 依赖集合。
  final BroadcastServices services;

  @override
  State<BroadcastHomePage> createState() => _BroadcastHomePageState();
}

class _BroadcastHomePageState extends State<BroadcastHomePage> {
  BroadcastSessionController get _session => widget.services.session;

  TranslationEngineStatus? _engineStatus;
  bool _preparing = false;

  @override
  void initState() {
    super.initState();
    _session.addListener(_onSessionChanged);
    unawaited(_refreshEngineStatus());
    unawaited(widget.services.drainTranslations());
  }

  @override
  void dispose() {
    _session.removeListener(_onSessionChanged);
    super.dispose();
  }

  void _onSessionChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _refreshEngineStatus() async {
    try {
      final status = await widget.services.engine.statusFor(_session.targetLanguage);
      if (mounted) setState(() => _engineStatus = status);
    } catch (_) {
      if (mounted) setState(() => _engineStatus = TranslationEngineStatus.failed);
    }
  }

  Future<void> _prepareLanguagePack() async {
    setState(() => _preparing = true);
    debugPrint(
      '[Broadcast] 开始准备语言包：目标 ${_session.targetLanguage.id}'
      '（阿→中经英语中转，需阿拉伯语/英语/中文三份）',
    );
    try {
      final status = await widget.services.engine.prepare(
        target: _session.targetLanguage,
        allowDownload: true,
      );
      debugPrint('[Broadcast] 语言包准备结束：${status.wireName}');
      if (mounted) setState(() => _engineStatus = status);
    } on TranslationException catch (error) {
      debugPrint('[Broadcast] 语言包准备失败：${error.code.wireName} — ${error.message}');
      if (mounted) {
        setState(() => _engineStatus = TranslationEngineStatus.failed);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('语言包准备失败：${error.message}')));
      }
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
  }

  Future<void> _toggleLanguage(TargetLanguage language) async {
    if (_session.updateTargetLanguage(language)) {
      debugPrint('[Broadcast] 目标语言切换为 ${language.id}（已持久化）');
      await widget.services.persistTargetLanguage(language);
      await _refreshEngineStatus();
      unawaited(widget.services.drainTranslations());
    }
  }

  Future<void> _retry(UtteranceRecord record, TargetLanguage language) async {
    await widget.services.translations.retry(record.id, language);
    await _session.refreshHistory();
  }

  @override
  Widget build(BuildContext context) {
    final recent = _session.recentRecords.isEmpty ? null : _session.recentRecords.first;
    final running = _session.isRunning;
    return Scaffold(
      appBar: AppBar(
        title: const Text('古兰经广播识别'),
        actions: <Widget>[
          TextButton.icon(
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => RecordListPage(services: widget.services),
                ),
              );
              await _session.refreshHistory();
            },
            icon: const Icon(Icons.history),
            label: Text('记录 ${_session.recordCount}'),
          ),
          IconButton(
            tooltip: '开发诊断（旧 Demo：语料校核与流式诊断，会另行加载旧经文库）',
            icon: const Icon(Icons.build_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const QuranOfflineDemoPage()),
            ),
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          _buildHeader(),
          if (_session.statusMessage != null)
            Container(
              width: double.infinity,
              color: Colors.amber.withValues(alpha: 0.15),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(_session.statusMessage!, style: const TextStyle(fontSize: 12)),
            ),
          Expanded(
            child: CustomScrollView(
              slivers: <Widget>[
                SliverList(
                  delegate: SliverChildListDelegate(<Widget>[
                    _buildTranscriptionCard(running, recent),
                    _buildMatchCard(recent),
                    _buildTranslationCard(recent),
                    const SizedBox(height: 12),
                  ]),
                ),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton.icon(
            onPressed: running ? () => unawaited(_session.stop()) : () => unawaited(_session.start()),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
              backgroundColor: running ? Colors.red.shade400 : null,
            ),
            icon: Icon(running ? Icons.stop : Icons.mic),
            label: Text(running ? '停止识别' : '开始识别'),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final session = _session;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Text('目标语言'),
              const SizedBox(width: 8),
              DropdownButton<TargetLanguage>(
                value: session.targetLanguage,
                onChanged: session.isRunning
                    ? null
                    : (value) {
                        if (value != null) unawaited(_toggleLanguage(value));
                      },
                items: <DropdownMenuItem<TargetLanguage>>[
                  for (final language in TargetLanguage.all)
                    DropdownMenuItem<TargetLanguage>(value: language, child: Text(language.displayName)),
                ],
              ),
              if (session.isRunning)
                const Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: Text('（识别中不可切换）', style: TextStyle(fontSize: 11, color: Colors.black54)),
                ),
            ],
          ),
          // 资源状态与「准备语言包」单独一行：窄屏上与语言选择同排会溢出 17px。
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '离线资源：${_engineStatusLabel()}',
                  style: theme.textTheme.bodySmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (_engineStatus != TranslationEngineStatus.ready)
                TextButton(
                  onPressed: _preparing ? null : _prepareLanguagePack,
                  child: Text(_preparing ? '准备中…' : '准备语言包'),
                ),
            ],
          ),
          Text(
            session.isRunning
                ? '收音中：正在断句识别（安静约 1.2 秒后确认一句）'
                : '空闲：点击「开始识别」后对准外放声源',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
        ],
      ),
    );
  }

  String _engineStatusLabel() => switch (_engineStatus) {
    null => '检查中',
    TranslationEngineStatus.ready => '已就绪',
    TranslationEngineStatus.missing => '缺少语言包',
    TranslationEngineStatus.downloading => '下载中',
    TranslationEngineStatus.failed => '准备失败',
    TranslationEngineStatus.unsupportedLanguage => '不支持该语言',
  };

  Widget _buildTranscriptionCard(bool running, UtteranceRecord? recent) {
    final draft = _session.draftText;
    final showingDraft = running && draft.trim().isNotEmpty;
    final text = showingDraft ? draft : (recent?.rawAsrText ?? '');
    final status = showingDraft
        ? '阿拉伯语 · 识别中（草稿）'
        : (recent == null
              ? '阿拉伯语 · 尚未识别'
              : '阿拉伯语 · 已确认 · ${recent.startSeconds.toStringAsFixed(1)}–'
                    '${recent.endSeconds.toStringAsFixed(1)}s');
    return TextSectionCard(
      title: '识别转写',
      subtitle: status,
      body: text,
      rtl: true,
      emptyHint: '还没有识别内容。开始识别后，实际 ASR 输出会显示在这里；'
          '它不会被经文替换。',
      footnote: recent?.matcherEvidenceJson == null || showingDraft
          ? null
          : '匹配状态：${recent!.matchStatus.name} · 范围：${recent.scope.name}',
    );
  }

  Widget _buildMatchCard(UtteranceRecord? recent) {
    // 识别中：匹配经文栏跟随草稿同步刷新为「候选」，不再等片段结束。
    final preview = _session.isRunning ? _session.preview : null;
    if (preview != null) {
      final outcome = preview.outcome;
      final matches = outcome.matches;
      if (matches.isEmpty) {
        return TextSectionCard(
          title: '匹配经文',
          subtitle: '识别中 · 候选 ${outcome.candidateRef ?? '无'}',
          body: '',
          rtl: true,
          emptyHint: outcome.rejectionReason ?? '本片段暂未命中库内经文，继续诵读会实时更新。',
          badge: '候选',
        );
      }
      final whole = matches.every((match) => match.isWholeVerse);
      return TextSectionCard(
        title: '匹配经文',
        subtitle: '识别中 · 候选 ${outcome.candidateRef} · '
            '${whole ? '完整节' : '部分节'} · '
            '覆盖 ${outcome.coverage?.toStringAsFixed(2) ?? '-'}',
        body: <String>[for (final match in matches) match.canonicalTextSnapshot].join('\n\n'),
        rtl: true,
        badge: '候选 · 随识别更新',
        footnote: '终稿确认（安静约 1.2 秒）后固定；预览口径与终稿可能略有差异。',
      );
    }
    if (recent == null) {
      return const TextSectionCard(
        title: '匹配经文',
        subtitle: '新库：开端章 / 王权章 / 纯洁章（41 节）',
        body: '',
        rtl: true,
        emptyHint: '匹配到经文后，这里显示新库的标准阿拉伯原文（含音标）与章节范围。',
      );
    }
    final matches = recent.matches;
    final body = matches.isEmpty
        ? ''
        : <String>[for (final match in matches) match.canonicalTextSnapshot].join('\n\n');
    final subtitle = matches.isEmpty
        ? (recent.matchStatus == MatchStatus.candidate ? '候选经文 · 证据不足' : '未匹配经文')
        : '${_surahLabel(matches.first.surah)} ${recent.matchSummary} · '
              '${switch (recent.matchStatus) {
                MatchStatus.confirmed => '已确认',
                MatchStatus.partial => '部分节',
                MatchStatus.candidate => '候选',
                MatchStatus.unmatched => '未匹配',
              }}';
    return TextSectionCard(
      title: '匹配经文',
      subtitle: subtitle,
      body: body,
      rtl: true,
      emptyHint: matches.isEmpty
          ? '未匹配经文：保留实际转写，不猜测最相似经文，也不回退旧经文库。'
          : null,
      footnote: matches.isEmpty
          ? null
          : matches.any((match) => !match.isWholeVerse)
          ? '本段只识别到该节的一部分，已标出匹配词范围。'
          : null,
    );
  }

  Widget _buildTranslationCard(UtteranceRecord? recent) {
    final language = _session.targetLanguage;
    // 识别中：译文栏跟随候选同步刷新（候选稳定后自动生成预览译文）。
    final preview = _session.isRunning ? _session.preview : null;
    if (preview != null) {
      if (preview.outcome.matches.isEmpty) {
        // 未命中库内经文（章前求护词、解说、其他章节）：预览译文跟随匹配经文，
        // 因此这里显示等待状态而不是翻译转写；终稿的未匹配记录仍会按需求翻译转写。
        return TextSectionCard(
          title: '目标译文',
          subtitle: '${language.displayName} · 等待匹配经文',
          body: '',
          emptyHint: '预览译文跟随匹配经文：当前片段尚未命中库内三章'
              '（可能是章前求护词、解说词或其他章节），命中后自动翻译对应标准原文。',
        );
      }
      if (preview.translationText != null && preview.translationText!.isNotEmpty) {
        return TextSectionCard(
          title: '目标译文',
          subtitle: preview.translationSource ?? language.displayName,
          body: preview.translationText!,
          badge: '预览',
          badgeColor: Colors.orange.shade800,
          footnote: '终稿确认后固定为正式译文并写入历史。',
        );
      }
      return TextSectionCard(
        title: '目标译文',
        subtitle: preview.translationPending
            ? '${language.displayName} · 正在生成预览译文'
            : '${language.displayName} · 等待候选稳定',
        body: '',
        emptyHint: preview.translationPending
            ? '首次翻译需要引擎冷启动，稍候…'
            : '候选经文连续两次一致后自动生成预览译文；'
                  '若长时间不出现，可能是缺少离线语言包（点上方「准备语言包」）。',
      );
    }
    if (recent == null) {
      return TextSectionCard(
        title: '目标译文',
        subtitle: '${language.displayName} · 尚无记录',
        body: '',
        emptyHint: '识别并确认一句后，这里显示译文及其来源（校订译本或机器翻译）。',
      );
    }
    final translation = recent.translationFor(language);
    if (translation == null) {
      return TextSectionCard(
        title: '目标译文',
        subtitle: '${language.displayName} · 等待翻译',
        body: '',
        emptyHint: '译文任务已入队，完成后会自动更新；失败可在同一记录重试。',
        onRetry: () => unawaited(_retry(recent, language)),
      );
    }
    return TextSectionCard(
      title: '目标译文',
      subtitle: '${language.displayName} · ${translation.status.label}'
          '${translation.inputScope == 'confirmedRange' ? ' · 仅已确认范围' : ''}',
      body: translation.status == TranslationStatus.done ? translation.text : '',
      badge: translation.sourceKind.label,
      badgeColor: translation.sourceKind == TranslationSourceKind.curatedEdition
          ? Colors.teal
          : Colors.orange.shade800,
      emptyHint: switch (translation.status) {
        TranslationStatus.modelMissing => '缺少离线语言包：请先在上方「准备语言包」，'
            '运行期不会降级到云翻译。',
        TranslationStatus.failed => '翻译失败：${translation.errorCode ?? '未知原因'}。',
        TranslationStatus.running => '正在翻译…',
        TranslationStatus.pending => '等待翻译…',
        TranslationStatus.done => '',
      },
      footnote: translation.status == TranslationStatus.done
          ? '来源：${translation.sourceLabel} · 生成于 '
                '${translation.createdAt.toLocal().toString().substring(0, 16)}'
          : null,
      onRetry: translation.status.canRetry ? () => unawaited(_retry(recent, language)) : null,
    );
  }

  static String _surahLabel(int surah) => switch (surah) {
    1 => '第 1 章 开端章',
    67 => '第 67 章 王权章',
    112 => '第 112 章 纯洁章',
    _ => '第 $surah 章',
  };
}

/// 详情页跳转辅助（首页与列表共用）。
Future<void> openRecordDetail(
  BuildContext context,
  BroadcastServices services,
  UtteranceRecord record,
) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => RecordDetailPage(
      services: services,
      recordId: record.id,
      onChanged: () => services.session.refreshHistory(),
    ),
  ),
);
