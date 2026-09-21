/// 原文 / 转写比对页面。
///
/// 左侧显示「原文」（参考答案，来自 [ReferenceText]），右侧显示端侧识别的
/// 「转写结果」，逐词对齐后按相似度着色：
/// - 一致（≥ [WordAlignment.matchThreshold]）：绿
/// - 近似（≥ [WordAlignment.nearThreshold]）：黄
/// - 错配（< 阈值）：红
/// - 缺失（原文有、转写无）/ 多余（转写有、原文无）：灰 / 橙
///
/// 顶部汇总 F1、覆盖率、准确率与各状态词数，整体结论按 [WordAlignment]
/// 的阈值分档（优秀 / 良好 / 一般 / 较差）。
library;

import 'package:flutter/material.dart';

import 'reference_text.dart';
import 'word_alignment.dart';
import 'word_error_rate.dart';

/// 原文与转写的逐词比对页。
class QuranComparePage extends StatefulWidget {
  /// 构造比对页。
  ///
  /// @param hypothesisWords 端侧转写词序列
  /// @param referenceLoader 原文加载实现，默认 [ReferenceText.load]（测试可注入）
  const QuranComparePage({super.key, required this.hypothesisWords, this.referenceLoader});

  /// 端侧转写词序列。
  final List<String> hypothesisWords;

  /// 原文加载实现。
  final Future<ReferenceText> Function()? referenceLoader;

  @override
  State<QuranComparePage> createState() => _QuranComparePageState();
}

class _QuranComparePageState extends State<QuranComparePage> {
  /// 转写覆盖率低于该值时提示「指标仅供参考」。
  ///
  /// 覆盖率低通常是抓音问题（VAD 跳过多数窗口）而非比对算法问题，
  /// 见 `docs/android-device.md` 的实测数据。
  static const double _lowCoverageThreshold = 0.35;

  ReferenceText? _reference;
  AlignmentResult? _result;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 加载原文并执行对齐。
  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final loader = widget.referenceLoader ?? ReferenceText.load;
      final reference = await loader();
      final result = WordAlignment.align(reference.words, widget.hypothesisWords);
      if (!mounted) return;
      setState(() {
        _reference = reference;
        _result = result;
        _loading = false;
      });
      debugPrint(
        '[QuranCompare] 原文 ${reference.words.length} 词 / 转写 '
        '${widget.hypothesisWords.length} 词 → F1=${result.f1.toStringAsFixed(3)} '
        '覆盖率=${result.coverage.toStringAsFixed(3)} '
        '准确率=${result.precision.toStringAsFixed(3)} '
        '一致=${result.matchCount} 近似=${result.nearCount} 错配=${result.mismatchCount} '
        '缺失=${result.missingCount} 多余=${result.extraCount} 结论=${result.verdict}',
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _loading = false;
      });
      debugPrint('[QuranCompare] 原文加载失败：$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('原文 / 转写比对'),
        actions: [
          IconButton(
            tooltip: '重新加载原文',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final error = _error;
    if (error != null) {
      return _buildError(error);
    }
    final result = _result;
    final reference = _reference;
    if (result == null || reference == null) {
      return const Center(child: Text('暂无比对结果'));
    }
    return Column(
      children: [
        _buildSummary(result, reference),
        if (result.coverage < _lowCoverageThreshold) _buildLowCoverageBanner(result),
        _buildLegend(),
        _buildColumnHeader(),
        Expanded(child: _buildRows(result)),
      ],
    );
  }

  /// 原文缺失时的提示：给出两种放入原文的方式。
  Widget _buildError(String error) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            const Icon(Icons.error_outline, color: Colors.red),
            const SizedBox(width: 8),
            Expanded(child: Text('原文加载失败：$error')),
          ],
        ),
        const SizedBox(height: 16),
        const Text('可用的原文来源：', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        const Text('1. 内置文件：${ReferenceText.assetPath}（随包发布，需重新构建）'),
        const SizedBox(height: 10),
        const Text('2. 设备文件（免重新构建，推送后回到本页点右上角刷新）：'),
        const SizedBox(height: 6),
        const SelectableText(
          'adb push 原文.txt /data/local/tmp/reference_text.txt\n'
          'adb shell run-as com.llvision.quran_offline_demo cp '
          '/data/local/tmp/reference_text.txt files/reference_text.txt',
          style: TextStyle(fontSize: 12, fontFamily: 'monospace'),
        ),
      ],
    );
  }

  /// 顶部指标区：结论、F1 / 覆盖率 / 准确率 / 平均相似度、各状态词数、来源。
  Widget _buildSummary(AlignmentResult result, ReferenceText reference) {
    final strict = WordErrorRate.compare(reference.words, widget.hypothesisWords);
    final verdictColor = switch (result.verdict) {
      '优秀' => Colors.green.shade700,
      '良好' => Colors.lightGreen.shade700,
      '一般' => Colors.orange.shade800,
      _ => Colors.red.shade700,
    };
    return Container(
      width: double.infinity,
      color: Colors.grey.shade50,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 2),
                decoration: BoxDecoration(
                  color: verdictColor,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  result.verdict,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'F1 ${result.f1.toStringAsFixed(3)}',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '覆盖率 ${result.coverage.toStringAsFixed(3)} · '
                  '准确率 ${result.precision.toStringAsFixed(3)} · '
                  '平均相似度 ${result.averageScore.toStringAsFixed(3)}',
                  style: const TextStyle(fontSize: 12, color: Colors.black54),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '严格词错误率 WER ${strict.rate.isFinite ? strict.rate.toStringAsFixed(3) : "∞"}'
            ' · 上方 F1 为容错词匹配分（近似词计半分）',
            style: const TextStyle(fontSize: 11, color: Colors.black54),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              _chip('一致 ${result.matchCount}', WordStatus.match),
              _chip('近似 ${result.nearCount}', WordStatus.near),
              _chip('错配 ${result.mismatchCount}', WordStatus.mismatch),
              _chip('缺失 ${result.missingCount}', WordStatus.missing),
              _chip('多余 ${result.extraCount}', WordStatus.extra),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '原文 ${result.referenceCount} 词（${reference.source}） · 转写 ${result.hypothesisCount} 词',
            style: const TextStyle(fontSize: 11, color: Colors.black45),
          ),
        ],
      ),
    );
  }

  /// 低覆盖率提示条：把「指标偏低」归因到抓音/环境，避免误判为算法问题。
  Widget _buildLowCoverageBanner(AlignmentResult result) {
    return Container(
      width: double.infinity,
      color: const Color(0xFFFFF3E0),
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_rounded, size: 16, color: Color(0xFFE65100)),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '转写覆盖率仅 ${result.coverage.toStringAsFixed(2)}：多为收音过弱或环境噪声导致 VAD 跳过'
              '大部分窗口，而非比对算法问题。建议靠近音源、提高音量后重测。',
              style: const TextStyle(fontSize: 11, color: Color(0xFFE65100)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, WordStatus status) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: _backgroundOf(status),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: _borderOf(status)),
      ),
      child: Text(label, style: TextStyle(fontSize: 11, color: _foregroundOf(status))),
    );
  }

  /// 图例：说明每种颜色对应的判定口径与阈值。
  Widget _buildLegend() {
    final items = <(String, WordStatus)>[
      ('一致 ≥${WordAlignment.matchThreshold.toStringAsFixed(2)}', WordStatus.match),
      (
        '近似 ${WordAlignment.nearThreshold.toStringAsFixed(2)}~'
            '${WordAlignment.matchThreshold.toStringAsFixed(2)}',
        WordStatus.near,
      ),
      ('错配 <${WordAlignment.nearThreshold.toStringAsFixed(2)}', WordStatus.mismatch),
      ('原文缺失', WordStatus.missing),
      ('转写多余', WordStatus.extra),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
      child: Wrap(
        spacing: 10,
        runSpacing: 4,
        children: [
          for (final (label, status) in items)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: _backgroundOf(status),
                    border: Border.all(color: _borderOf(status)),
                  ),
                ),
                const SizedBox(width: 4),
                Text(label, style: const TextStyle(fontSize: 10, color: Colors.black54)),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildColumnHeader() {
    return Container(
      color: const Color(0xFFEFEFEF),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: const [
          SizedBox(width: 32),
          Expanded(
            child: Text(
              '原文',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.black87),
            ),
          ),
          SizedBox(width: 6),
          Expanded(
            child: Text(
              '转写',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.black87),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRows(AlignmentResult result) {
    if (result.isEmpty) {
      return const Center(child: Text('没有可比对的内容'));
    }
    return ListView.builder(
      itemCount: result.rows.length,
      itemBuilder: (context, index) => _buildRow(result.rows[index], index),
    );
  }

  Widget _buildRow(AlignedWord row, int index) {
    return Container(
      decoration: BoxDecoration(
        color: _backgroundOf(row.status),
        border: const Border(bottom: BorderSide(color: Color(0x11000000))),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 32,
            child: Text(
              '${index + 1}',
              style: const TextStyle(fontSize: 10, color: Colors.black26),
            ),
          ),
          Expanded(child: _buildCell(row.reference)),
          const SizedBox(width: 6),
          Expanded(child: _buildCell(row.hypothesis)),
        ],
      ),
    );
  }

  /// 单元格：阿拉伯语按 RTL 渲染；缺词侧显示占位符。
  Widget _buildCell(String? word) {
    if (word == null) {
      return const Text('—', style: TextStyle(fontSize: 16, color: Colors.black26));
    }
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Text(word, style: const TextStyle(fontSize: 19, height: 1.5)),
    );
  }

  Color _backgroundOf(WordStatus status) => switch (status) {
    WordStatus.match => const Color(0xFFE8F5E9),
    WordStatus.near => const Color(0xFFFFF8E1),
    WordStatus.mismatch => const Color(0xFFFFEBEE),
    WordStatus.missing => const Color(0xFFF0F0F0),
    WordStatus.extra => const Color(0xFFFFF3E0),
  };

  Color _borderOf(WordStatus status) => switch (status) {
    WordStatus.match => const Color(0xFFA5D6A7),
    WordStatus.near => const Color(0xFFFFE082),
    WordStatus.mismatch => const Color(0xFFEF9A9A),
    WordStatus.missing => const Color(0xFFBDBDBD),
    WordStatus.extra => const Color(0xFFFFCC80),
  };

  Color _foregroundOf(WordStatus status) => switch (status) {
    WordStatus.match => const Color(0xFF1B5E20),
    WordStatus.near => const Color(0xFF8D6E00),
    WordStatus.mismatch => const Color(0xFFB71C1C),
    WordStatus.missing => const Color(0xFF616161),
    WordStatus.extra => const Color(0xFFE65100),
  };
}
