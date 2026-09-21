/// 用真实整章音频标定新库的跨度惩罚（`spanPenalty`）。
///
/// 背景：旧库的 `spanPenalty = 0.1` 是在 6236 节 + Tilawa 官方 token 表上标定的，
/// 新库的 token 表由本仓库用确定性分词重新生成（口径与上游不同），**该常数从未在
/// 新库上标定过**。直接把旧值搬过来会出现「长转写被匹配成短节」或「过度扩展」。
///
/// 标定方法：取一段真实的连续诵读音频，按固定步长滑窗（模拟广播里长度不一的
/// 片段），对每组候选参数统计三类失败模式 —— **不需要人工 ground truth**，
/// 因为连续诵读本身提供了「候选应当单调推进且覆盖窗口内容」的约束：
///
/// 1. **覆盖不足**：候选无法解释窗口内容（coverage 偏低）→ 说明跨度太短；
/// 2. **跨度膨胀**：候选参考词数远大于转写词数 → 说明跨度太长，把没念到的节算进来了；
/// 3. **推进回退**：相邻窗口的候选节号倒退 → 说明参数导致定位不稳。
///
/// 运行方式（先启动 host ORT 服务）：
/// ```bash
/// tools/quran_offline/.venv122/bin/python tools/quran_offline/host_ort_server.py --port 18765
/// QURAN_ORT_URL=http://127.0.0.1:18765 \
/// QURAN_TUNE_WAV=/tmp/span_tune/067-ru-16k.wav \
/// QURAN_TUNE_OUT=/tmp/span_tuning.json \
/// flutter test tool/broadcast_span_tuning_test.dart
/// ```
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:quran_offline_demo/broadcast/application/broadcast_transcriber.dart';
import 'package:quran_offline_demo/broadcast/application/quran_match_service.dart';
import 'package:quran_offline_demo/broadcast/data/broadcast_corpus.dart';
import 'package:quran_offline_demo/quran_offline/corpus_audio.dart';
import 'package:quran_offline_demo/quran_offline/ctc_decoder.dart';
import 'package:quran_offline_demo/quran_offline/ctc_scorer.dart';
import 'package:quran_offline_demo/quran_offline/quran_matcher.dart';
import 'package:quran_offline_demo/quran_offline/quran_text.dart';

import 'stream_benchmark_test.dart' show FileAssetBundle, HttpOrtRunner;

/// 滑窗长度（秒）：接近真实广播片段的中位长度。
const double _windowSeconds = 25;

/// 滑窗步长（秒）。
const double _hopSeconds = 8;

/// 待标定的跨度惩罚候选值。
///
/// 实测（15s 与 25s 两种窗口）显示：在「解释比例分带优先」的裁决逻辑下，
/// `spanPenalty` 在 0–0.2 范围内对结果**完全没有影响** —— 因为不同跨度的候选
/// 解释比例差异通常跨带，排序分根本没参与比较。因此这里固定 0.1（与旧库同值，
/// 便于两库对照），改为扫描真正影响结果的自变量：**候选跨度上限**。
const List<double> _penalties = <double>[0.1];

/// 待标定的最大连读跨度（节）；需与 token 表实际生成的跨度上限一致。
const List<int> _maxSpans = <int>[4, 6];

/// 跨度膨胀判据：候选参考词数 / 转写词数 超过该比例即视为膨胀。
const double _inflationRatio = 1.6;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'tune span penalty on a real continuous recitation',
    () async {
      final wavPath = Platform.environment['QURAN_TUNE_WAV'];
      final outputPath = Platform.environment['QURAN_TUNE_OUT'];
      if (wavPath == null || outputPath == null) {
        throw StateError('Set QURAN_TUNE_WAV and QURAN_TUNE_OUT before running.');
      }
      final endpoint = Uri.parse(Platform.environment['QURAN_ORT_URL'] ?? 'http://127.0.0.1:8765');
      final bundle = FileAssetBundle(Directory.current);

      await HttpOverrides.runWithHttpOverrides(() async {
        final library = await BroadcastQuranLibrary.load(bundle: bundle);
        final samples = CorpusAudio.decodeWav(File(wavPath).readAsBytesSync());
        const sampleRate = 16000;
        final runner = HttpOrtRunner(endpoint: endpoint, blankId: library.blankId);
        final decoder = TextCtcDecoder(library.vocab, blankId: library.blankId);
        final windowSamples = (_windowSeconds * sampleRate).round();
        final hopSamples = (_hopSeconds * sampleRate).round();

        // 每个窗口只推理一次；不同参数共用同一份声学证据与转写。
        final windows = <_TuneWindow>[];
        for (var start = 0; start + windowSamples <= samples.length; start += hopSamples) {
          final audio = Float32List.sublistView(samples, start, start + windowSamples);
          final evidence = await runner.run(audio);
          final decoded = decoder.decode(evidence.logprobs, evidence.timeSteps, evidence.vocabSize);
          final text = QuranText.normalize(decoded.text);
          if (text.isEmpty) continue;
          windows.add(
            _TuneWindow(
              startSample: start,
              endSample: start + windowSamples,
              evidence: evidence,
              decoded: decoded,
              text: text,
              words: text.split(' ').where((word) => word.isNotEmpty).toList(growable: false),
            ),
          );
        }
        stdout.writeln('音频 ${(samples.length / sampleRate).toStringAsFixed(1)}s，'
            '有效窗口 ${windows.length} 个（${_windowSeconds.toInt()}s / 步长 ${_hopSeconds.toInt()}s）');

        final reports = <Map<String, Object?>>[];
        for (final maxSpan in _maxSpans) {
          for (final penalty in _penalties) {
          final service = QuranMatchService(
            library: library,
            config: BroadcastMatchConfig(spanPenalty: penalty, maxSpan: maxSpan),
          );
          var matched = 0;
          var coverageSum = 0.0;
          var inflation = 0;
          var regress = 0;
          var spanSum = 0;
          var coveredVersesSum = 0;
          final spanHistogram = <String, int>{};
          int? previousAyah;
          final refs = <String>[];

          for (final window in windows) {
            final outcome = service.match(window.toFragment(sampleRate));
            final matches = outcome.matches;
            if (matches.isEmpty) continue;
            matched++;
            final span = matches.last.ayah - matches.first.ayah + 1;
            spanSum += span;
            coveredVersesSum += matches.length;
            spanHistogram['$span'] = (spanHistogram['$span'] ?? 0) + 1;
            coverageSum += outcome.coverage ?? 0;
            final referenceWords = outcome.metrics.referenceWords ?? 0;
            if (referenceWords > window.words.length * _inflationRatio) inflation++;
            final ayah = matches.first.ayah;
            if (previousAyah != null && ayah < previousAyah) regress++;
            previousAyah = ayah;
            refs.add(matches.first.ref);
          }
          reports.add(<String, Object?>{
            'maxSpan': maxSpan,
            'spanPenalty': penalty,
            'windows': windows.length,
            'matchedWindows': matched,
            'matchRate': windows.isEmpty ? 0 : matched / windows.length,
            'meanCoverage': matched == 0 ? 0 : coverageSum / matched,
            'inflationRate': matched == 0 ? 0 : inflation / matched,
            'regressRate': matched <= 1 ? 0 : regress / (matched - 1),
            'meanSpan': matched == 0 ? 0 : spanSum / matched,
            'meanMatchedVerses': matched == 0 ? 0 : coveredVersesSum / matched,
            'spanHistogram': spanHistogram,
            'refs': refs,
          });
          }
        }

        stdout.writeln('\n跨度上限  惩罚   命中率   平均覆盖  膨胀率   回退率   平均跨度  跨度分布');
        for (final report in reports) {
          final histogram = (report['spanHistogram']! as Map<String, int>).entries.toList()
            ..sort((a, b) => int.parse(a.key).compareTo(int.parse(b.key)));
          stdout.writeln(
            '${(report['maxSpan']! as int).toString().padRight(10)}'
            '${(report['spanPenalty']! as double).toStringAsFixed(2).padRight(6)}'
            '${(report['matchRate']! as double).toStringAsFixed(2).padRight(9)}'
            '${(report['meanCoverage']! as double).toStringAsFixed(2).padRight(10)}'
            '${(report['inflationRate']! as double).toStringAsFixed(2).padRight(9)}'
            '${(report['regressRate']! as double).toStringAsFixed(2).padRight(9)}'
            '${(report['meanSpan']! as double).toStringAsFixed(2).padRight(10)}'
            '${histogram.map((entry) => '${entry.key}节×${entry.value}').join(' ')}',
          );
        }
        await File(outputPath).writeAsString(
          const JsonEncoder.withIndent('  ').convert(<String, Object?>{
            'windowSeconds': _windowSeconds,
            'hopSeconds': _hopSeconds,
            'inflationRatio': _inflationRatio,
            'defaultRunnerUpLimit': QuranMatcher.defaultRunnerUpLimit,
            'reports': reports,
          }),
        );
        stdout.writeln('\n明细已写入 $outputPath');
        await runner.dispose();
      }, _RealHttpOverrides());
    },
    timeout: const Timeout(Duration(minutes: 30)),
    skip: Platform.environment['QURAN_TUNE_WAV'] == null
        ? 'Set QURAN_TUNE_WAV and start the host ORT server to run this tuning.'
        : false,
  );
}

class _RealHttpOverrides extends HttpOverrides {}

/// 一个滑窗的推理结果。
class _TuneWindow {
  _TuneWindow({
    required this.startSample,
    required this.endSample,
    required this.evidence,
    required this.decoded,
    required this.text,
    required this.words,
  });

  final int startSample;
  final int endSample;
  final AcousticEvidence evidence;
  final TextCtcResult decoded;
  final String text;
  final List<String> words;

  /// 组装成匹配服务需要的片段结构（单段、无时间词）。
  BroadcastFragment toFragment(int sampleRate) => BroadcastFragment(
    words: words,
    timedWords: const [],
    segments: <BroadcastSegment>[
      BroadcastSegment(
        startSample: startSample,
        endSample: endSample,
        evidence: evidence,
        decoded: decoded,
        forcedBoundary: false,
      ),
    ],
    sampleRate: sampleRate,
  );
}
