/// 结构化时延事件：把「音频区间 → 转写/候选 → 译文 → UI 帧」串成可关联的序列。
///
/// 已有的 `[BroadcastLatency]` 只有两个数字：最新音频块进入控制器到转写/候选
/// UI 帧、候选稳定到译文 UI 帧。它们**不能相加**当作「语音进入麦克风到正确译文
/// 可见」的端到端时延，因为译文要等候选连续两次稳定，且只有显示成功的版本才计入。
///
/// 本文件补齐可关联的事件链，供离线统计：
///
/// | 事件 | 含义 | 关键字段 |
/// |---|---|---|
/// | `previewPublished` | 一次预览结果在控制器侧生成 | 音频区间、候选、候选代数 |
/// | `previewFrame` | 该预览首次真正绘制到界面 | 修订号、是否带译文 |
/// | `translationPublished` | 预览译文生成并发布 | 候选代数、来源 |
/// | `translationFrame` | 带译文的预览首次绘制到界面 | 候选代数 |
/// | `translationDropped` | 译文在到达前被候选切换清掉 | 候选代数 |
/// | `finalPublished` | 终稿落库 | 片段采样区间、候选、状态 |
///
/// 所有时间戳取自会话内的单调时钟（`Stopwatch`），与 `revision`、`candidateGeneration`
/// 一起可以判断「迟到结果是否混算」：A→B→A 的旧译文必须丢弃。
///
/// **默认关闭**：只有显式注入本对象时才记录，不改变收音、转写与落库路径。
library;

import 'package:flutter/foundation.dart';

import '../domain/utterance_record.dart';

/// 时延事件种类。
enum BroadcastLatencyEventKind {
  /// 预览结果已生成（尚未绘制）。
  previewPublished,

  /// 预览首次绘制到界面。
  previewFrame,

  /// 预览译文已发布（尚未绘制）。
  translationPublished,

  /// 带译文的预览首次绘制到界面。
  translationFrame,

  /// 译文在到达前被丢弃（候选已切换）。
  translationDropped,

  /// 终稿已落库。
  finalPublished,
}

/// 一条时延事件。
class BroadcastLatencyEvent {
  /// 构造事件。
  const BroadcastLatencyEvent({
    required this.kind,
    required this.atUs,
    required this.sessionEpoch,
    required this.revision,
    required this.candidateGeneration,
    required this.utteranceStartSample,
    required this.audioStartSample,
    required this.audioEndSample,
    this.audioReceivedAtUs,
    this.candidateRef,
    this.status,
    this.sourceKind,
    this.note,
  });

  /// 事件种类。
  final BroadcastLatencyEventKind kind;

  /// 事件发生时刻（会话单调时钟，微秒）。
  final int atUs;

  /// 会话代数（重启后迟到结果不得混算）。
  final int sessionEpoch;

  /// 预览修订号；终稿事件沿用最后一次预览修订。
  final int revision;

  /// 候选代数（候选每次切换递增）。
  final int candidateGeneration;

  /// 当前片段的绝对起始采样。
  final int utteranceStartSample;

  /// 本事件对应音频的绝对起始采样。
  final int audioStartSample;

  /// 本事件对应音频的绝对结束采样。
  final int audioEndSample;

  /// 该音频末块进入控制器的时刻（微秒）；仅预览事件有值。
  final int? audioReceivedAtUs;

  /// 候选经文引用。
  final String? candidateRef;

  /// 匹配状态名。
  final String? status;

  /// 译文来源。
  final TranslationSourceKind? sourceKind;

  /// 补充说明（丢弃原因等）。
  final String? note;

  /// 转成便于日志检索与离线解析的一行文本。
  String toLogLine() => <String>[
    'kind=${kind.name}',
    'epoch=$sessionEpoch',
    'rev=$revision',
    'gen=$candidateGeneration',
    'utt=$utteranceStartSample',
    'aStart=$audioStartSample',
    'aEnd=$audioEndSample',
    if (audioReceivedAtUs != null) 'aRecvUs=$audioReceivedAtUs',
    if (candidateRef != null) 'ref=$candidateRef',
    if (status != null) 'status=$status',
    if (sourceKind != null) 'src=${sourceKind!.wireName}',
    'atUs=$atUs',
    if (note != null) 'note=$note',
  ].join(' ');
}

/// 时延事件记录器；未启用时不记录任何事件。
class BroadcastLatencyTrace {
  /// 构造记录器。
  ///
  /// @param capacity 内存里保留的最近事件数（仅供测试与内存控制）
  BroadcastLatencyTrace({this.capacity = 4096});

  /// 内存中保留的最近事件数。
  final int capacity;

  final List<BroadcastLatencyEvent> _events = <BroadcastLatencyEvent>[];

  /// 已记录的最近事件（按发生顺序）。
  List<BroadcastLatencyEvent> get events =>
      List<BroadcastLatencyEvent>.unmodifiable(_events);

  /// 记录一条事件并打印一行 `[BroadcastLatencyTrace]` 日志。
  ///
  /// @param event 待记录事件
  void record(BroadcastLatencyEvent event) {
    if (_events.length >= capacity) _events.removeAt(0);
    _events.add(event);
    debugPrint('[BroadcastLatencyTrace] ${event.toLogLine()}');
  }

  /// 按种类筛选事件（测试与离线核对用）。
  ///
  /// @param kind 目标种类
  /// @return 该种类的全部事件
  List<BroadcastLatencyEvent> ofKind(BroadcastLatencyEventKind kind) => [
    for (final event in _events)
      if (event.kind == kind) event,
  ];

  /// 清空记录。
  void clear() => _events.clear();
}
