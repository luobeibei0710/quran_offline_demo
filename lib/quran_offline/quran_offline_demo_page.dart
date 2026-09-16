/// 古兰经离线识别 Demo 页面。
///
/// 功能：麦克风实时采集 → 端侧离线识别 → 展示当前章节（surah:ayah）、
/// 标准经文、识别原文、候选列表与词进度；支持随时重置与收尾。
///
/// 数据链路：麦克风 16 kHz PCM16 → float32 → ONNX 推理（原生）→
/// 贪心 CTC 解码 → 文本召回 → CTC 约束精排 → UI。
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import 'ort_runner.dart';
import 'quran_assets.dart';
import 'quran_matcher.dart';
import 'quran_recognizer.dart';

/// 声学模型在 Flutter 资产中的路径（与 pubspec 声明一致）。
const String _modelAssetKey = 'assets/quran_offline/fastconformer_full_mixed.onnx';

/// 古兰经离线识别演示页。
class QuranOfflineDemoPage extends StatefulWidget {
  /// 构造页面。
  const QuranOfflineDemoPage({super.key});

  @override
  State<QuranOfflineDemoPage> createState() => _QuranOfflineDemoPageState();
}

enum _Phase { idle, loading, ready, recording, error }

class _QuranOfflineDemoPageState extends State<QuranOfflineDemoPage> {
  final AudioRecorder _recorder = AudioRecorder();
  final List<String> _logs = <String>[];

  QuranAssets? _assets;
  QuranRecognizer? _recognizer;
  PlatformOrtRunner? _runner;
  QuranStreamingSession? _session;
  StreamSubscription<Uint8List>? _micSubscription;
  StreamSubscription<QuranRecognitionEvent>? _eventSubscription;

  _Phase _phase = _Phase.idle;
  String _status = '点击「加载模型」开始';
  QuranRecognitionEvent? _latest;
  final List<QuranRecognitionEvent> _history = <QuranRecognitionEvent>[];
  int _stableCommitCount = 0;
  double _micLevel = 0;

  @override
  void initState() {
    super.initState();
    // 联调便利：进入页面即自动加载经文库与模型，便于直接观察加载结果；
    // 正式接入时可改为用户点击触发（删除本方法内的调用即可）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load());
    });
  }

  @override
  void dispose() {
    _micSubscription?.cancel();
    _eventSubscription?.cancel();
    _recorder.dispose();
    _session?.dispose();
    _runner?.dispose();
    super.dispose();
  }

  void _log(String message) {
    final time = DateTime.now().toIso8601String().substring(11, 19);
    // 同时输出到 logcat，便于真机联调时用 adb 直接观察
    debugPrint('[QuranDemo] $message');
    setState(() {
      _logs.insert(0, '[$time] $message');
      if (_logs.length > 60) _logs.removeLast();
    });
  }

  /// 加载经文库、词表与 ONNX 模型。
  Future<void> _load() async {
    setState(() {
      _phase = _Phase.loading;
      _status = '正在加载经文库与词表…';
    });
    final stopwatch = Stopwatch()..start();
    try {
      final assets = await QuranAssets.load();
      _log('经文库 ${assets.verses.length} 节，词表 ${assets.vocab.length} 项，'
          'span 表 ${assets.spanTokens.length} 条（${stopwatch.elapsedMilliseconds}ms）');

      setState(() => _status = '正在加载 ONNX 模型（首次约需数秒）…');
      final runner = PlatformOrtRunner(blankId: assets.blankId);
      await runner.loadModel(_modelAssetKey);
      _log('模型加载完成（总耗时 ${stopwatch.elapsedMilliseconds}ms）');

      setState(() {
        _assets = assets;
        _runner = runner;
        _recognizer = QuranRecognizer(assets: assets, runner: runner);
        _phase = _Phase.ready;
        _status = '就绪：点击「开始识别」并诵读';
      });
    } catch (error) {
      setState(() {
        _phase = _Phase.error;
        _status = '加载失败：$error';
      });
      _log('ERROR $error');
    }
  }

  /// 开始麦克风采集与流式识别。
  Future<void> _start() async {
    final recognizer = _recognizer;
    if (recognizer == null) return;

    final granted = await Permission.microphone.request();
    if (!granted.isGranted) {
      _log('未授予麦克风权限');
      return;
    }

    final session = recognizer.createSession();
    _session = session;
    _history.clear();
    _stableCommitCount = 0;

    _eventSubscription = session.events.listen((event) {
      setState(() {
        _latest = event;
        _history.insert(0, event);
        if (_history.length > 8) _history.removeLast();
        if (event.stable && event.champion != null) _stableCommitCount++;
      });
      final champion = event.champion;
      if (champion != null) {
        _log('${event.stable ? '稳定' : '候选'} ${champion.ref} '
            'conf=${event.match.confidence.toStringAsFixed(2)} '
            'acoustic=${champion.acousticScore.toStringAsFixed(3)} '
            '${event.audioSeconds.toStringAsFixed(1)}s');
      }
    }, onError: (Object error) => _log('识别异常 $error'));

    final micStream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: QuranRecognizer.sampleRate,
        numChannels: 1,
      ),
    );
    _micSubscription = micStream.listen(
      (data) {
        final samples = _pcm16ToFloat32(data);
        _micLevel = _rms(samples);
        unawaited(session.feed(samples));
      },
      onError: (Object error) => _log('麦克风异常 $error'),
    );

    setState(() {
      _phase = _Phase.recording;
      _status = '识别中：请诵读古兰经';
    });
    _log('开始采集（16 kHz / PCM16 / 单声道）');
  }

  /// 停止采集并做收尾识别。
  Future<void> _stop() async {
    await _micSubscription?.cancel();
    _micSubscription = null;
    await _recorder.stop();
    await _session?.finish();
    await _eventSubscription?.cancel();
    _eventSubscription = null;
    setState(() {
      _phase = _Phase.ready;
      _status = '已停止，可再次开始';
    });
    _log('已停止采集');
  }

  /// 重置识别状态，开始新一次诵读。
  void _reset() {
    _session?.reset();
    setState(() {
      _latest = null;
      _history.clear();
      _stableCommitCount = 0;
    });
    _log('已重置');
  }

  /// PCM16 小端字节流转 float32（-1..1）。
  Float32List _pcm16ToFloat32(Uint8List bytes) {
    final count = bytes.length ~/ 2;
    final result = Float32List(count);
    final view = ByteData.sublistView(bytes);
    for (var i = 0; i < count; i++) {
      result[i] = view.getInt16(i * 2, Endian.little) / 32768.0;
    }
    return result;
  }

  /// 计算分块 RMS（用于电平显示）。
  double _rms(Float32List samples) {
    if (samples.isEmpty) return 0;
    var sum = 0.0;
    for (final value in samples) {
      sum += value * value;
    }
    return (sum / samples.length);
  }

  @override
  Widget build(BuildContext context) {
    final champion = _latest?.champion;
    final match = _latest?.match;
    return Scaffold(
      appBar: AppBar(
        title: const Text('古兰经离线识别 Demo'),
        actions: [
          IconButton(
            tooltip: '重置',
            onPressed: _phase == _Phase.recording ? _reset : null,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          _buildHeader(),
          _buildResult(champion, match),
          _buildCandidates(match),
          const Divider(height: 1),
          Expanded(child: _buildLogs()),
        ],
      ),
      floatingActionButton: _buildFab(),
    );
  }

  Widget _buildHeader() {
    final color = switch (_phase) {
      _Phase.error => Colors.red.shade50,
      _Phase.recording => Colors.green.shade50,
      _Phase.ready => Colors.blue.shade50,
      _ => Colors.grey.shade100,
    };
    return Container(
      width: double.infinity,
      color: color,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_status, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: LinearProgressIndicator(
                  value: _phase == _Phase.recording ? (_micLevel * 12).clamp(0.0, 1.0) : 0,
                  minHeight: 6,
                ),
              ),
              const SizedBox(width: 12),
              Text('稳定命中 ${_stableCommitCount.toString()} 次',
                  style: const TextStyle(fontSize: 12, color: Colors.black54)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildResult(VerseMatchCandidate? champion, VerseMatchResult? match) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (champion != null && _latest?.stable == true)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.green.shade600,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Text('已锁定', style: TextStyle(color: Colors.white, fontSize: 11)),
                ),
              const SizedBox(width: 8),
              Text(
                champion == null ? '等待识别…' : '${champion.label}  (${champion.ref})',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (champion != null) ...[
            Text(
              '${champion.verse.surahName}  ·  ${champion.verse.surahNameEn}',
              style: const TextStyle(fontSize: 13, color: Colors.black87),
            ),
            const SizedBox(height: 6),
            // 标准经文（奥斯曼体，带音标）
            Directionality(
              textDirection: TextDirection.rtl,
              child: Text(
                champion.isSpan
                    ? _spanText(champion)
                    : champion.verse.textUthmani,
                style: const TextStyle(fontSize: 20, height: 1.9),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                _chip('置信度', match?.confidence.toStringAsFixed(2) ?? '-'),
                _chip('声学分', champion.acousticScore.toStringAsFixed(3)),
                _chip('召回', '${match?.recallCount ?? 0} 条'),
                _chip('跨度', champion.isSpan ? '${champion.ayahEnd - champion.ayahStart + 1} 节' : '单节'),
                _chip('窗口', '${_latest?.audioSeconds.toStringAsFixed(1) ?? '-'} s'),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '识别原文：${_latest?.decodedText ?? ''}',
              style: const TextStyle(fontSize: 13, color: Colors.black54),
            ),
          ],
        ],
      ),
    );
  }

  /// 拼接多节经文的奥斯曼体文本。
  String _spanText(VerseMatchCandidate champion) {
    final assets = _assets;
    if (assets == null) return champion.verse.textUthmani;
    final buffer = StringBuffer();
    for (var a = champion.ayahStart; a <= champion.ayahEnd; a++) {
      final verse = assets.verse(champion.surah, a);
      if (verse == null) continue;
      if (buffer.isNotEmpty) buffer.write(' ');
      buffer.write(verse.textUthmani);
    }
    return buffer.toString();
  }

  Widget _chip(String label, String value) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text('$label $value', style: const TextStyle(fontSize: 12)),
      );

  Widget _buildCandidates(VerseMatchResult? match) {
    final runners = match?.runnersUp ?? const <VerseMatchCandidate>[];
    if (runners.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('候选（声学分升序）', style: TextStyle(fontSize: 12, color: Colors.black54)),
          const SizedBox(height: 4),
          ...runners.map(
            (candidate) => Text(
              '  · ${candidate.ref}  acoustic=${candidate.acousticScore.toStringAsFixed(3)} '
              'text=${candidate.textScore.toStringAsFixed(2)}',
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLogs() {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: _logs.length,
      itemBuilder: (context, index) => Text(
        _logs[index],
        style: const TextStyle(fontSize: 11, fontFamily: 'monospace', color: Colors.black87),
      ),
    );
  }

  Widget _buildFab() {
    if (_phase == _Phase.idle || _phase == _Phase.error) {
      return FloatingActionButton.extended(
        onPressed: _load,
        icon: const Icon(Icons.download),
        label: const Text('加载模型'),
      );
    }
    if (_phase == _Phase.loading) {
      return const FloatingActionButton.extended(
        onPressed: null,
        icon: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
        label: Text('加载中…'),
      );
    }
    final recording = _phase == _Phase.recording;
    return FloatingActionButton.extended(
      onPressed: recording ? _stop : _start,
      backgroundColor: recording ? Colors.red.shade400 : null,
      icon: Icon(recording ? Icons.stop : Icons.mic),
      label: Text(recording ? '停止识别' : '开始识别'),
    );
  }
}

