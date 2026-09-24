/// 终稿转写与预览转写对照诊断：同一段音频、同一个模型，比较两条路径的识别结果。
///
/// 背景：真机第 12 章试播中，第 6 条终稿是 30 秒 `maxDuration` 强切片段，
/// 只识别出 12 个词并被判为 unmatched；而同一片段进行中的 12 秒预览窗口
/// 反复给出 `12:8` 候选。两者用的是同一份麦克风音频，却得到差异极大的转写。
///
/// 本脚本把「拾音质量」这一变量排除掉：直接用数字音源（不经外放与麦克风）
/// 在同一时间窗上分别跑
///
/// 1. 终稿路径 [BroadcastTranscriber.transcribe]：先按声学停顿切分子窗，
///    再逐窗推理并用 `lookaheadSeconds` 延迟提交尾词；
/// 2. 预览路径 [BroadcastTranscriber.transcribePreview]：整窗一次前向，无尾词延迟。
///
/// 若数字音源上终稿路径同样丢词，则根因在分段/尾词提交逻辑，与拾音无关；
/// 若只有真机丢词，则应继续排查外放拾音链路。
///
/// 运行方式（需先启动 host ORT 服务）：
/// ```bash
/// tools/quran_offline/.venv122/bin/python tools/quran_offline/host_ort_server.py --port 18765 &
/// QURAN_ORT_URL=http://127.0.0.1:18765 \
/// QURAN_DIAG_WAV=/tmp/quran_t1/012_16k.wav \
/// QURAN_DIAG_WINDOWS=150,155,160,165 \
/// QURAN_DIAG_OUT=/tmp/quran_t1/diag.json \
/// flutter test tool/diagnose_final_vs_preview_test.dart
/// ```
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:quran_broadcast_sdk/broadcast/application/broadcast_transcriber.dart';
import 'package:quran_broadcast_sdk/broadcast/application/quran_match_service.dart';
import 'package:quran_broadcast_sdk/broadcast/data/broadcast_corpus.dart';
import 'package:quran_offline_demo/quran_offline/corpus_audio.dart';
import 'package:quran_broadcast_sdk/quran_offline/ctc_decoder.dart';

import 'stream_benchmark_test.dart' show FileAssetBundle, HttpOrtRunner;

/// 采样率，必须与模型和音源一致。
const int _sampleRate = 16000;

/// 终稿窗口长度：与真机 `UtteranceSegmenterConfig.maxSeconds` 一致。
const double _finalWindowSeconds = 30;

/// 预览窗口长度：与真机 `previewWindowSeconds` 一致。
const double _previewWindowSeconds = 12;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('同一音频：终稿分段路径 vs 预览整窗路径', () async {
    final wavPath = Platform.environment['QURAN_DIAG_WAV'];
    final outputPath = Platform.environment['QURAN_DIAG_OUT'];
    if (wavPath == null || outputPath == null) {
      throw StateError('Set QURAN_DIAG_WAV and QURAN_DIAG_OUT.');
    }
    final starts = (Platform.environment['QURAN_DIAG_WINDOWS'] ?? '150')
        .split(',')
        .where((item) => item.trim().isNotEmpty)
        .map((item) => double.parse(item.trim()))
        .toList();
    final endpoint = Uri.parse(
      Platform.environment['QURAN_ORT_URL'] ?? 'http://127.0.0.1:8765',
    );

    await HttpOverrides.runWithHttpOverrides(() async {
      final library = await BroadcastQuranLibrary.load(
        bundle: FileAssetBundle(Directory.current),
      );
      final runner = HttpOrtRunner(endpoint: endpoint, blankId: library.blankId);
      final transcriber = BroadcastTranscriber(
        runner: runner,
        decoder: TextCtcDecoder(library.vocab, blankId: library.blankId),
        vocab: library.vocab,
        sampleRate: _sampleRate,
      );
      final matcher = QuranMatchService(library: library);

      final samples = CorpusAudio.decodeWav(File(wavPath).readAsBytesSync());
      stdout.writeln(
        '音源 $wavPath：${(samples.length / _sampleRate).toStringAsFixed(1)} 秒',
      );

      final reported = <Map<String, Object?>>[];
      for (final startSeconds in starts) {
        final start = (startSeconds * _sampleRate).round();
        final finalEnd = start + (_finalWindowSeconds * _sampleRate).round();
        final previewEnd = start + (_previewWindowSeconds * _sampleRate).round();
        if (finalEnd > samples.length) {
          stdout.writeln('跳过起点 ${startSeconds}s：音频不足一个终稿窗口');
          continue;
        }

        final finalSamples = Float32List.sublistView(samples, start, finalEnd);
        final finalFragment = await transcriber.transcribe(
          finalSamples,
          offsetSample: 0,
        );
        final finalOutcome = matcher.match(finalFragment);

        final previewSamples = Float32List.sublistView(
          samples,
          start,
          previewEnd,
        );
        final previewFragment = await transcriber.transcribePreview(
          previewSamples,
          offsetSample: 0,
        );
        final previewOutcome = matcher.match(previewFragment);

        // 对照项：终稿的 30 秒音频走一次「整窗单前向」，只去掉分段与尾词延迟。
        // 用于区分「分段/尾词提交」与「窗口更长导致模型退步」两种解释。
        final wholeFragment = await transcriber.transcribePreview(
          finalSamples,
          offsetSample: 0,
        );
        final wholeOutcome = matcher.match(wholeFragment);

        final row = <String, Object?>{
          'startSeconds': startSeconds,
          'final': _describe(
            path: 'final',
            words: finalFragment.words,
            segmentCount: finalFragment.segments.length,
            segmentSeconds: [
              for (final segment in finalFragment.segments)
                double.parse(
                  ((segment.endSample - segment.startSample) / _sampleRate)
                      .toStringAsFixed(2),
                ),
            ],
            outcome: finalOutcome,
          ),
          'preview': _describe(
            path: 'preview',
            words: previewFragment.words,
            segmentCount: previewFragment.segments.length,
            segmentSeconds: [
              for (final segment in previewFragment.segments)
                double.parse(
                  ((segment.endSample - segment.startSample) / _sampleRate)
                      .toStringAsFixed(2),
                ),
            ],
            outcome: previewOutcome,
          ),
          'wholeWindowSinglePass': _describe(
            path: 'whole30sSinglePass',
            words: wholeFragment.words,
            segmentCount: wholeFragment.segments.length,
            segmentSeconds: [
              for (final segment in wholeFragment.segments)
                double.parse(
                  ((segment.endSample - segment.startSample) / _sampleRate)
                      .toStringAsFixed(2),
                ),
            ],
            outcome: wholeOutcome,
          ),
        };
        reported.add(row);
        final finalRow = row['final']! as Map<String, Object?>;
        final previewRow = row['preview']! as Map<String, Object?>;
        final wholeRow = row['wholeWindowSinglePass']! as Map<String, Object?>;
        stdout.writeln(
          '@${startSeconds}s  终稿 词数=${finalRow['wordCount']} '
          '子窗=${finalRow['segmentCount']} ${finalRow['segmentSeconds']} '
          '匹配=${finalRow['candidateRef']} 状态=${finalRow['status']} '
          '| 预览 词数=${previewRow['wordCount']} '
          '匹配=${previewRow['candidateRef']} 状态=${previewRow['status']} '
          '| 整窗单次 词数=${wholeRow['wordCount']} '
          '匹配=${wholeRow['candidateRef']} 状态=${wholeRow['status']}',
        );
        stdout.writeln('  终稿转写：${finalRow['asrText']}');
        stdout.writeln('  预览转写：${previewRow['asrText']}');
        stdout.writeln('  整窗单次：${wholeRow['asrText']}');
      }

      await File(outputPath).writeAsString(
        const JsonEncoder.withIndent('  ').convert(<String, Object?>{
          'wav': wavPath,
          'sampleRate': _sampleRate,
          'finalWindowSeconds': _finalWindowSeconds,
          'previewWindowSeconds': _previewWindowSeconds,
          'corpusId': library.manifest.corpusId,
          'windows': reported,
        }),
      );
      stdout.writeln('\n明细已写入 $outputPath');
      await runner.dispose();
    }, _RealHttpOverrides());
  }, timeout: const Timeout(Duration(minutes: 60)));
}

/// 汇总一条路径的结果。
Map<String, Object?> _describe({
  required String path,
  required List<String> words,
  required int segmentCount,
  required List<double> segmentSeconds,
  required BroadcastMatchOutcome outcome,
}) => <String, Object?>{
  'path': path,
  'wordCount': words.length,
  'segmentCount': segmentCount,
  'segmentSeconds': segmentSeconds,
  'asrText': words.join(' '),
  'status': outcome.status.name,
  'scope': outcome.scope.name,
  'candidateRef': outcome.candidateRef,
  'coverage': outcome.coverage,
  'precision': outcome.precision,
  'confidence': outcome.confidence,
  'rejectionReason': outcome.rejectionReason,
};

/// 允许真实 HTTP（host ORT 服务）的覆盖实现。
class _RealHttpOverrides extends HttpOverrides {}
