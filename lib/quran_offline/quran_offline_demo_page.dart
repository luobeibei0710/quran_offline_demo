/// 古兰经离线识别 Demo 页面。
///
/// 功能：麦克风实时采集 → 端侧离线识别 → 展示当前章节（surah:ayah）、
/// 标准经文、识别原文、候选列表与词进度；支持随时重置与收尾。
///
/// 数据链路：麦克风 16 kHz PCM16 → float32 → ONNX 推理（原生）→
/// 贪心 CTC 解码 → 文本召回 → CTC 约束精排 → UI。
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'ctc_scorer.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import 'corpus_verify_page.dart';
import 'ort_runner.dart';
import 'quran_assets.dart';
import 'quran_compare_page.dart';
import 'quran_matcher.dart';
import 'quran_recognizer.dart';
import 'reference_text.dart';
import 'transcript_stitcher.dart';
import 'word_alignment.dart';

/// 声学模型在 Flutter 资产中的路径（与 pubspec 声明一致）。
///
/// 使用「ORT 1.22 兼容版」：原模型含 `ConvInteger`（int8 量化卷积），
/// Android/iOS 可用的 ONNX Runtime 1.22 尚未实现该算子，故经
/// `tools/quran_offline/convert_for_ort122.py` 等价改造为 DequantizeLinear + Conv。
const String _modelAssetKey = 'assets/quran_offline/fastconformer_full_mixed_ort122.onnx';

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

  /// 连续转写稿：把逐窗重复识别结果按最长重叠去重后累积，供比对页使用。
  final TranscriptStitcher _stitcher = TranscriptStitcher();

  /// 提词器滚动控制器，以及文本区可用宽度（用于计算居中滚动位置）。
  final ScrollController _prompterScroll = ScrollController();
  double _prompterTextWidth = 0;

  /// 麦克风分块计数（用于周期性输出电平诊断）。
  int _micFrames = 0;

  /// 本次采集的峰值电平（RMS），用于「收音偏弱」自检。
  double _micPeak = 0;

  /// 判定「收音偏弱」的峰值下限：正常朗读或贴近外放应明显高于该值。
  static const double _weakLevelRms = 0.02;

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
    _prompterScroll.dispose();
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
      // 自动化验证：用内置样本跑一次完整识别，无需麦克风即可确认算法链路
      unawaited(_runBuiltinSample());
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
    _micFrames = 0;
    _micPeak = 0;
    // 新一轮诵读：清空上一轮的转写稿
    _stitcher.reset();

    _eventSubscription = session.events.listen((event) {
      // 同一段话会被多轮重复识别，按最长重叠去重后再累积成连续转写稿
      _stitcher.add(event.decodedText);
      setState(() {
        _latest = event;
        _history.insert(0, event);
        if (_history.length > 8) _history.removeLast();
        if (event.stable && event.champion != null) _stableCommitCount++;
      });
      // 提词器跟随：把「当前词」滚动到屏幕中部附近
      WidgetsBinding.instance.addPostFrameCallback((_) => _centerPrompter());
      final champion = event.champion;
      if (champion != null) {
        _log('${event.stable ? '稳定' : '候选'} ${champion.ref} '
            'conf=${event.match.confidence.toStringAsFixed(2)} '
            'acoustic=${champion.acousticScore.toStringAsFixed(3)} '
            '进度=${event.readWords}/${event.words.length} '
            '${event.audioSeconds.toStringAsFixed(1)}s');
      }
      // 已确认进度：稳定命中且读满阈值时提交一次，序列单调推进
      if (event.justCommitted) {
        final advanced = event.advancedSeconds;
        _log('已确认 ${event.committedRef}（累计 ${event.committedSequence.length} 节'
            '${advanced > 0 ? '，窗口前移 ${advanced.toStringAsFixed(1)}s' : ''}）');
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
        final level = _micLevel <= 0 ? 0.0 : math.sqrt(_micLevel);
        if (level > _micPeak) _micPeak = level;
        // 诊断：周期性输出麦克风 RMS，用于校准静音/语音门控阈值
        _micFrames++;
        if (_micFrames % 20 == 0) {
          _log('麦克风 RMS=${level.toStringAsFixed(4)}');
        }
        unawaited(session.feed(samples));
      },
      onError: (Object error) => _log('麦克风异常 $error'),
    );

    setState(() {
      _phase = _Phase.recording;
      _status = '识别中：请诵读古兰经';
    });
    _log('开始采集（16 kHz / PCM16 / 单声道）');

    // 自检：采集 2 秒后仍无任何输入电平，说明麦克风未被系统放行
    //（常见于「仅本次允许」的一次性授权过期，或系统麦克风隐私开关关闭）
    Timer(const Duration(seconds: 2), () {
      if (_phase == _Phase.recording && _micLevel <= 0) {
        _log('警告：麦克风无输入（RMS=0），请检查权限或麦克风隐私开关');
        setState(() => _status = '麦克风无输入，请检查权限');
      }
    });

    // 自检：采集 6 秒后峰值仍远低于正常朗读水平 → 提示收音偏弱
    //（否则多数窗口会被 VAD 跳过，转写与比对指标会因此失真）
    Timer(const Duration(seconds: 6), () {
      if (_phase != _Phase.recording || _micLevel <= 0 || _micPeak >= _weakLevelRms) return;
      _log('提示：收音偏弱（峰值 RMS=${_micPeak.toStringAsFixed(4)} < '
          '${_weakLevelRms.toStringAsFixed(3)}），建议靠近音源或提高音量');
      setState(() => _status = '收音偏弱：请靠近音源或提高音量');
    });
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
      _status = '已停止，可点右上角图标查看比对结果';
    });
    _log('已停止采集，转写共 ${_stitcher.length} 词');
    await _logComparisonPreview();
  }

  /// 重置识别状态，开始新一次诵读。
  void _reset() {
    _session?.reset();
    _stitcher.reset();
    setState(() {
      _latest = null;
      _history.clear();
      _stableCommitCount = 0;
    });
    _log('已重置');
  }

  /// 打开比对页：左侧原文（`reference_text.txt`），右侧本次转写稿。
  Future<void> _openComparison() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => QuranComparePage(hypothesisWords: _stitcher.words),
      ),
    );
  }

  /// 打开语料验证页：选中语料后把音频灌入引擎（不经麦克风），跑完与语料原文比对。
  ///
  /// 与实时识别共用同一个识别器（同一份模型），因此不可在采集时进入；
  /// 页面对会话、转写稿各自的累积互不干扰。
  ///
  /// @param autoRunAll 进入后是否自动跑一遍全部语料（无人值守验证用）
  Future<void> _openCorpusVerify({bool autoRunAll = false}) async {
    final assets = _assets;
    final recognizer = _recognizer;
    if (assets == null || recognizer == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CorpusVerifyPage(
          assets: assets,
          recognizer: recognizer,
          autoRunAll: autoRunAll,
        ),
      ),
    );
  }

  /// 结束识别后先算一遍比对指标并写入日志，不打开页面也能看到结果概览。
  Future<void> _logComparisonPreview() async {
    final words = _stitcher.words;
    if (words.isEmpty) return;
    try {
      final reference = await ReferenceText.load();
      final result = WordAlignment.align(reference.words, words);
      _log('比对预览 原文${result.referenceCount}词/转写${result.hypothesisCount}词 '
          'F1=${result.f1.toStringAsFixed(3)} '
          '覆盖率=${result.coverage.toStringAsFixed(3)} '
          '准确率=${result.precision.toStringAsFixed(3)} '
          '一致=${result.matchCount} 近似=${result.nearCount} 错配=${result.mismatchCount} '
          '缺失=${result.missingCount} 多余=${result.extraCount} 结论=${result.verdict}');
    } catch (error) {
      _log('比对预览失败：$error');
    }
  }

  /// 联调开关：内置样本验证结束后自动开启麦克风识别。
  ///
  /// 打开方式：`flutter run --dart-define=quran_auto_start=true`
  /// （Android 禁用 `input tap`、iOS 模拟器无法脚本点击，无人值守验证只能靠它）；
  /// 默认关闭，正式演示由用户点按触发。
  static const bool _autoStartListening = bool.fromEnvironment('quran_auto_start');

  /// 联调开关：自动开始识别后经过该秒数自动停止并输出比对预览，0 表示不自动停止。
  ///
  /// 打开方式：`--dart-define=quran_auto_stop_seconds=160`
  static const int _autoStopSeconds = int.fromEnvironment('quran_auto_stop_seconds');

  /// 联调开关：加载完成后自动进入「语料验证」并跑一遍全部语料（含与原文比对）。
  ///
  /// 该链路不依赖麦克风与声学环境，适合设备上无人值守跑准确度回归：
  /// `--dart-define=quran_auto_corpus=true`
  static const bool _autoCorpus = bool.fromEnvironment('quran_auto_corpus');

  /// 提词器开关：true 时主区显示「逐词跟随高亮」提词器；
  /// false 时显示 Streaming 样式（整句奥斯曼体经文）。
  static const bool _showTeleprompter = false;

  /// 内置验证样本：资源路径 → 期望章节（文件名即标准答案，SSSAAA = 章号、节号）。
  static const Map<String, String> _builtinSamples = {
    'assets/quran_offline/sample_001001.wav': '1:1',
    'assets/quran_offline/sample_001002.wav': '1:2',
    'assets/quran_offline/sample_002255.wav': '2:255',
    'assets/quran_offline/sample_036001.wav': '36:1',
    'assets/quran_offline/sample_112001.wav': '112:1',
  };

  /// 读取内置样本音频（16 kHz / 单声道 / PCM16 WAV，跳过 44 字节头）。
  Future<Float32List> _loadBuiltinSample(String assetKey) async {
    final data = await rootBundle.load(assetKey);
    final bytes = data.buffer.asUint8List(data.offsetInBytes + 44, data.lengthInBytes - 44);
    return _pcm16ToFloat32(bytes);
  }

  /// 批量跑内置样本，自动核对准确率（文件名即标准答案，无需人工判断阿拉伯语）。
  ///
  /// 判定方式：识别出的章节 `ref` 是否等于文件名解析出的期望章节；命中率直接
  /// 反映「推理 → 解码 → 召回 → CTC 精排」整条链路的正确性。
  Future<void> _runBuiltinSample() async {
    final recognizer = _recognizer;
    if (recognizer == null) return;
    var hits = 0;
    var index = 0;
    for (final entry in _builtinSamples.entries) {
      index++;
      final expected = entry.value;
      try {
        final samples = await _loadBuiltinSample(entry.key);
        final stopwatch = Stopwatch()..start();
        final result = await recognizer.recognizeOnce(samples);
        final elapsed = stopwatch.elapsedMilliseconds;
        final champion = result.champion;
        final actual = champion?.ref ?? '无匹配';
        final hit = actual == expected;
        if (hit) hits++;
        _log('样本$index 期望=$expected 实际=$actual ${hit ? '命中' : '未命中'} '
            'conf=${result.confidence.toStringAsFixed(2)} '
            'acoustic=${champion?.acousticScore.toStringAsFixed(3) ?? '-'} '
            '召回=${result.recallCount} 耗时=${elapsed}ms');
        _log('      原文：${result.decodedText}');
        if (!hit && result.runnersUp.isNotEmpty) {
          final others = result.runnersUp
              .take(10)
              .map((c) => '${c.ref}(${c.acousticScore.toStringAsFixed(2)})')
              .join(' ');
          _log('      候选：$others');
          // 诊断：期望经节在文本召回中的名次（是否被 topK 截断）
          final parts = expected.split(':');
          final targetSurah = int.tryParse(parts.first) ?? 0;
          final targetAyah = int.tryParse(parts.last.split('-').first) ?? 0;
          final targetIndex = recognizer.assets.verses.indexWhere(
            (v) => v.surah == targetSurah && v.ayah == targetAyah,
          );
          final recalled = recognizer.matcher.recall(result.decodedText);
          final rank = recalled.indexWhere((e) => e.key == targetIndex);
          _log('      诊断：期望节下标=$targetIndex 召回名次=$rank/${recalled.length} '
              '（topK=${recognizer.config.topK}）');
          // 诊断：确认 native 返回的 log 概率数值范围（log_softmax 应全为负、最大接近 0）
          final evidence = await recognizer.runner.run(samples);
          var maxValue = double.negativeInfinity;
          var minValue = double.infinity;
          var total = 0.0;
          for (final value in evidence.logprobs) {
            if (value > maxValue) maxValue = value;
            if (value < minValue) minValue = value;
            total += value;
          }
          _log('      诊断：frames=${evidence.timeSteps} vocab=${evidence.vocabSize} '
              'blankId=${evidence.blankId} '
              'max=${maxValue.toStringAsFixed(3)} min=${minValue.toStringAsFixed(3)} '
              'avg=${(total / evidence.logprobs.length).toStringAsFixed(3)}');
          // 诊断：期望节单节候选的打分（含太斯米 / 剥离太斯米）
          final targetTokens = recognizer.assets.tokensFor(targetSurah, targetAyah, targetAyah);
          if (targetTokens != null && targetTokens.length > 5) {
            final fullScore = CtcScorer.scoreSequence(evidence, targetTokens);
            final trimmedScore = CtcScorer.scoreSequence(evidence, targetTokens.sublist(5));
            _log('      诊断：期望节 span=1 tokens=${targetTokens.length} '
                'head=${targetTokens.take(6).join(",")} '
                'full=${fullScore.toStringAsFixed(3)} trimmed=${trimmedScore.toStringAsFixed(3)}');
          }
        }
        if (index == 1) {
          setState(() {
            _latest = QuranRecognitionEvent(
              match: result,
              decodedText: result.decodedText,
              stable: true,
              isFinal: true,
              audioSeconds: samples.length / QuranRecognizer.sampleRate,
            );
          });
        }
      } catch (error) {
        _log('样本$index 期望=$expected 识别失败：$error');
      }
    }
    _log('内置样本验证完成：命中 $hits/${_builtinSamples.length}');
    if (_autoCorpus) {
      await Future<void>.delayed(const Duration(seconds: 1));
      _log('联调模式：自动进入语料验证（灌音 + 原文比对）');
      await _openCorpusVerify(autoRunAll: true);
      return;
    }

    if (_autoStartListening) {
      await Future<void>.delayed(const Duration(seconds: 2));
      _log('联调模式：自动开始麦克风识别');
      await _start();
      if (_autoStopSeconds > 0) {
        Timer(Duration(seconds: _autoStopSeconds), () {
          if (mounted && _phase == _Phase.recording) unawaited(_stop());
        });
      }
    }
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
          // 语料验证入口：音频灌入引擎（不经麦克风）+ 与语料原文比对
          IconButton(
            tooltip: '语料验证（灌音 + 原文比对）',
            onPressed: _assets == null || _recognizer == null || _phase == _Phase.recording
                ? null
                : _openCorpusVerify,
            icon: const Icon(Icons.library_music_outlined),
          ),
          // 比对入口：有转写内容后可用，进入「左侧原文 / 右侧转写」比对页
          IconButton(
            tooltip: '比对结果（左：原文，右：转写）',
            onPressed: _stitcher.isEmpty ? null : _openComparison,
            icon: const Icon(Icons.compare_arrows),
          ),
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
          _buildChapterBar(champion, match),
          Expanded(child: _buildVerseBody(champion)),
          _buildFooter(),
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

  /// 主区内容：按开关显示提词器或整句经文（Streaming 样式）。
  Widget _buildVerseBody(VerseMatchCandidate? champion) {
    if (champion == null) {
      return const Center(
        child: Text(
          '开始诵读后，这里显示识别到的经文',
          style: TextStyle(fontSize: 14, color: Colors.black38),
        ),
      );
    }
    if (_showTeleprompter) return _buildTeleprompter(champion);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
      child: Directionality(
        textDirection: TextDirection.rtl,
        child: Text(
          champion.isSpan ? _spanText(champion) : champion.verse.textUthmani,
          style: const TextStyle(fontSize: 26, height: 2.1),
        ),
      ),
    );
  }

  /// 拼接多节经文的奥斯曼体文本。
  String _spanText(VerseMatchCandidate champion) {
    final assets = _assets;
    if (assets == null) return champion.verse.textUthmani;
    final buffer = StringBuffer();
    for (var ayah = champion.ayahStart; ayah <= champion.ayahEnd; ayah++) {
      final verse = assets.verse(champion.surah, ayah);
      if (verse == null) continue;
      if (buffer.isNotEmpty) buffer.write(' ');
      buffer.write(verse.textUthmani);
    }
    return buffer.toString();
  }

  /// 提词器：整屏逐词显示经文，已朗读 / 当前 / 未读三态强对比，并自动居中跟随。
  ///
  /// 已读位置由 [QuranWordProgress] 的「CTC 前缀可达性」估算（见
  /// `quran_word_progress.dart`）：随朗读推进，更长前缀的声学证据更充分、
  /// 分数下降；尚未朗读的词会让分数回升，据此判断读到第几个词。
  Widget _buildTeleprompter(VerseMatchCandidate? champion) {
    final words = _latest?.words ?? const <String>[];
    if (champion == null || words.isEmpty) {
      return const Center(
        child: Text(
          '开始诵读后，这里会逐词跟随高亮',
          style: TextStyle(fontSize: 14, color: Colors.black38),
        ),
      );
    }
    final readWords = (_latest?.readWords ?? 0).clamp(0, words.length);

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(10, 2, 10, 4),
      decoration: BoxDecoration(
        color: const Color(0xFFFDFBF3),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFDCD3BE)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          _prompterTextWidth = constraints.maxWidth - 34;
          return Scrollbar(
            controller: _prompterScroll,
            thickness: 3,
            child: SingleChildScrollView(
              controller: _prompterScroll,
              padding: const EdgeInsets.fromLTRB(14, 20, 14, 20),
              child: Directionality(
                textDirection: TextDirection.rtl,
                child: RichText(
                  text: TextSpan(
                    children: [
                      for (var i = 0; i < words.length; i++)
                        TextSpan(text: '${words[i]} ', style: _wordStyle(i, readWords)),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// 词的三态样式：已朗读（深墨绿加粗）、当前词（琥珀底 + 特粗）、未读（中灰）。
  TextStyle _wordStyle(int index, int readWords) {
    if (index == readWords - 1) {
      return const TextStyle(
        fontSize: 34,
        height: 2.0,
        fontWeight: FontWeight.w900,
        color: Color(0xFF06281E),
        backgroundColor: Color(0xFFFFD54F),
      );
    }
    if (index < readWords) {
      return const TextStyle(
        fontSize: 34,
        height: 2.0,
        fontWeight: FontWeight.w600,
        color: Color(0xFF0D7A5F),
      );
    }
    return const TextStyle(
      fontSize: 34,
      height: 2.0,
      color: Color(0xFFB4B4B4),
    );
  }

  /// 把「当前词」滚动到可视区中部附近。
  ///
  /// 用 [TextPainter] 复算「已读部分」的实际排版高度，再滚动到该高度减去
  /// 半屏的位置，使正在朗读的词始终落在屏幕中间区域。
  void _centerPrompter() {
    final words = _latest?.words ?? const <String>[];
    final readWords = (_latest?.readWords ?? 0).clamp(0, words.length);
    if (words.isEmpty || readWords == 0 || !_prompterScroll.hasClients || _prompterTextWidth <= 0) {
      return;
    }
    final painter = TextPainter(
      text: TextSpan(
        children: [
          for (var i = 0; i < readWords; i++)
            TextSpan(text: '${words[i]} ', style: _wordStyle(i, readWords)),
        ],
      ),
      textDirection: TextDirection.rtl,
    )..layout(maxWidth: _prompterTextWidth);

    final position = _prompterScroll.position;
    final target = painter.height + 20 - position.viewportDimension / 2;
    _prompterScroll.animateTo(
      target.clamp(0.0, position.maxScrollExtent),
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOut,
    );
  }

  /// 章节信息栏（紧凑）：章名、章:节与关键指标压成两行小字。
  Widget _buildChapterBar(VerseMatchCandidate? champion, VerseMatchResult? match) {
    if (champion == null) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(16, 10, 16, 6),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text('等待识别…', style: TextStyle(fontSize: 15, color: Colors.black45)),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (_latest?.stable == true) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                  decoration: BoxDecoration(
                    color: Colors.green.shade600,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text('已锁定', style: TextStyle(color: Colors.white, fontSize: 10)),
                ),
                const SizedBox(width: 6),
              ],
              Text(
                '${champion.label}  (${champion.ref})',
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            '${champion.verse.surahName} · ${champion.verse.surahNameEn}    '
            '置信度 ${match?.confidence.toStringAsFixed(2) ?? '-'} · '
            '声学分 ${champion.acousticScore.toStringAsFixed(3)} · '
            '进度 ${_latest?.readWords ?? 0}/${_latest?.words.length ?? 0} · '
            '已确认 ${_latest?.committedSequence.length ?? 0} 节'
            '${_latest?.committedRef == null ? '' : '（最近 ${_latest!.committedRef}）'} · '
            '窗口 ${_latest?.audioSeconds.toStringAsFixed(0) ?? '-'}s',
            style: const TextStyle(fontSize: 11, color: Colors.black45),
          ),
        ],
      ),
    );
  }

  /// 底部信息（紧凑）：只保留最近几条事件日志，高度受限。
  Widget _buildFooter() {
    return Container(
      width: double.infinity,
      height: 76,
      decoration: const BoxDecoration(
        color: Color(0xFFF6F6F6),
        border: Border(top: BorderSide(color: Color(0xFFE2E2E2))),
      ),
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: ListView.builder(
        reverse: true,
        itemCount: _logs.length > 5 ? 5 : _logs.length,
        itemBuilder: (context, index) => Text(
          _logs[index],
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 10, fontFamily: 'monospace', color: Colors.black45),
        ),
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

