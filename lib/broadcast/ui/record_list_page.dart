/// 历史记录列表：稳定序号、分页、语言/状态筛选与删除。
///
/// 序号来自数据库的稳定展示字段（删除后不改号、不复用），业务身份是 UUID；
/// 同一经文重复诵读是合法的新记录，不在这里去重。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../broadcast_services.dart';
import '../domain/utterance_record.dart';
import 'record_detail_page.dart';

/// 历史列表页。
class RecordListPage extends StatefulWidget {
  /// 构造列表页。
  ///
  /// @param services 依赖集合
  const RecordListPage({super.key, required this.services});

  /// 依赖集合。
  final BroadcastServices services;

  @override
  State<RecordListPage> createState() => _RecordListPageState();
}

class _RecordListPageState extends State<RecordListPage> {
  static const int _pageSize = 50;

  final ScrollController _controller = ScrollController();
  final List<UtteranceRecord> _records = <UtteranceRecord>[];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  bool _deleting = false;
  int _total = 0;
  TargetLanguage? _languageFilter;
  MatchStatus? _statusFilter;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
    unawaited(_reload());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_hasMore || _loadingMore) return;
    if (_controller.position.pixels > _controller.position.maxScrollExtent - 240) {
      unawaited(_loadMore());
    }
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    try {
      final page = await widget.services.records.page(limit: _pageSize);
      _total = await widget.services.records.count();
      setState(() {
        _records
          ..clear()
          ..addAll(page);
        _hasMore = page.length == _pageSize;
        _loading = false;
      });
    } catch (error) {
      setState(() {
        _loading = false;
        _hasMore = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('读取历史失败：$error')));
      }
    }
  }

  Future<void> _loadMore() async {
    setState(() => _loadingMore = true);
    try {
      final page = await widget.services.records.page(limit: _pageSize, offset: _records.length);
      setState(() {
        _records.addAll(page);
        _hasMore = page.length == _pageSize;
        _loadingMore = false;
      });
    } catch (_) {
      setState(() {
        _loadingMore = false;
        _hasMore = false;
      });
    }
  }

  List<UtteranceRecord> get _visible => _records.where((record) {
    if (_languageFilter != null && record.targetLanguage != _languageFilter) return false;
    if (_statusFilter != null && record.matchStatus != _statusFilter) return false;
    return true;
  }).toList(growable: false);

  Future<void> _confirmDelete(UtteranceRecord record) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除记录 #${record.displaySequence.toString().padLeft(6, '0')}？'),
        content: const Text('删除后该记录的转写、经文范围、指标与译文都会一并移除，'
            '迟到返回的译文不会复活它。'),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('删除')),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.services.records.delete(record.id);
    await _reload();
    await widget.services.session.refreshHistory();
  }

  /// 清空全部历史。
  ///
  /// 录音中禁止（实施方案 §3.2）：识别进行时清空会让当前片段的落库与已删记录
  /// 交叉，用户也容易误以为「刚说的话丢了」。
  Future<void> _confirmDeleteAll() async {
    if (widget.services.session.isRunning) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('识别进行中，无法清空历史；请先停止识别。')),
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空全部历史记录？'),
        content: Text(
          '将删除全部 $_total 条记录，以及它们的匹配经文、比对指标、译文与待处理翻译任务。\n\n'
          '该操作不可撤销；清空后展示序号从 #000001 重新开始。',
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade400),
            child: const Text('全部删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _deleting = true);
    try {
      final removed = await widget.services.records.deleteAll();
      await widget.services.session.refreshHistory();
      await _reload();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已清空 $removed 条历史记录')),
        );
      }
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visible;
    final canClear = _total > 0 && !_deleting;
    return Scaffold(
      appBar: AppBar(
        title: Text('历史记录（$_total）'),
        actions: <Widget>[
          IconButton(
            tooltip: _deleting ? '正在清空…' : '全部删除',
            icon: _deleting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.delete_sweep_outlined),
            onPressed: canClear ? () => unawaited(_confirmDeleteAll()) : null,
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Row(
              children: <Widget>[
                DropdownButton<TargetLanguage?>(
                  value: _languageFilter,
                  hint: const Text('全部语言'),
                  onChanged: (value) => setState(() => _languageFilter = value),
                  items: <DropdownMenuItem<TargetLanguage?>>[
                    const DropdownMenuItem<TargetLanguage?>(child: Text('全部语言')),
                    for (final language in TargetLanguage.all)
                      DropdownMenuItem<TargetLanguage?>(value: language, child: Text(language.displayName)),
                  ],
                ),
                const SizedBox(width: 12),
                DropdownButton<MatchStatus?>(
                  value: _statusFilter,
                  hint: const Text('全部状态'),
                  onChanged: (value) => setState(() => _statusFilter = value),
                  items: <DropdownMenuItem<MatchStatus?>>[
                    const DropdownMenuItem<MatchStatus?>(child: Text('全部状态')),
                    for (final status in MatchStatus.values)
                      DropdownMenuItem<MatchStatus?>(
                        value: status,
                        child: Text(_statusLabel(status)),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : visible.isEmpty
          ? const Center(child: Text('还没有记录'))
          : ListView.separated(
              controller: _controller,
              itemCount: visible.length + (_hasMore ? 1 : 0),
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                if (index >= visible.length) {
                  return const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                final record = visible[index];
                return _RecordTile(
                  record: record,
                  onOpen: () => unawaited(_open(record)),
                  onDelete: () => unawaited(_confirmDelete(record)),
                );
              },
            ),
    );
  }

  Future<void> _open(UtteranceRecord record) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RecordDetailPage(
          services: widget.services,
          recordId: record.id,
          onChanged: _reload,
        ),
      ),
    );
    await _reload();
  }

  static String _statusLabel(MatchStatus status) => switch (status) {
    MatchStatus.confirmed => '已确认',
    MatchStatus.partial => '部分节',
    MatchStatus.candidate => '候选',
    MatchStatus.unmatched => '未匹配',
  };
}

class _RecordTile extends StatelessWidget {
  const _RecordTile({required this.record, required this.onOpen, required this.onDelete});

  final UtteranceRecord record;
  final VoidCallback onOpen;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final translation = record.translationFor(record.targetLanguage);
    return ListTile(
      onTap: onOpen,
      title: Row(
        children: <Widget>[
          Text(
            '#${record.displaySequence.toString().padLeft(6, '0')}',
            style: theme.textTheme.labelMedium?.copyWith(fontFamily: 'monospace'),
          ),
          const SizedBox(width: 8),
          Text(
            record.createdAt.toLocal().toString().substring(5, 16),
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: theme.colorScheme.secondaryContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(record.targetLanguage.displayName, style: theme.textTheme.labelSmall),
          ),
          const Spacer(),
          Text(record.matchSummary, style: theme.textTheme.bodySmall),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const SizedBox(height: 4),
          Text(
            record.summary(40),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textDirection: TextDirection.rtl,
          ),
          const SizedBox(height: 2),
          Text(
            translation == null
                ? '译文：待生成'
                : '译文（${translation.sourceKind.label}）：'
                      '${translation.status == TranslationStatus.done ? translation.text : translation.status.label}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
        ],
      ),
      trailing: IconButton(
        onPressed: onDelete,
        icon: const Icon(Icons.delete_outline),
        tooltip: '删除',
      ),
    );
  }
}
