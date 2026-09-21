/// 匹配诊断：对指定音频窗口打印召回与 CTC 精排的真实数据。
///
/// 用于定位「转写覆盖 N 节却只匹配到 M 节」这类问题：先看正确节是否进入召回，
/// 再看以它为起点的跨度候选在精排里排到第几、打分多少。
///
/// ```bash
/// QURAN_ORT_URL=http://127.0.0.1:18765 \
/// QURAN_DIAG_AUDIO=/tmp/e2e_wav/001.wav \
/// QURAN_DIAG_START=16.4 QURAN_DIAG_WINDOW=30 QURAN_DIAG_SURAH=1 \
/// flutter test tool/diagnose_match_test.dart
/// ```
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:quran_offline_demo/broadcast/application/broadcast_transcriber.dart';
import 'package:quran_offline_demo/broadcast/data/broadcast_corpus.dart';
import 'package:quran_offline_demo/quran_offline/corpus_audio.dart';
import 'package:quran_offline_demo/quran_offline/ctc_decoder.dart';
import 'package:quran_offline_demo/quran_offline/quran_matcher.dart';
import 'package:quran_offline_demo/quran_offline/quran_text.dart';

import 'stream_benchmark_test.dart' show FileAssetBundle, HttpOrtRunner;

const int _sampleRate = 16000;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'diagnose recall and rerank for one window',
    () async {
      final audio = Platform.environment['QURAN_DIAG_AUDIO'];
      if (audio == null) {
        throw StateError('Set QURAN_DIAG_AUDIO.');
      }
      final start = double.parse(Platform.environment['QURAN_DIAG_START'] ?? '0');
      final window = double.parse(Platform.environment['QURAN_DIAG_WINDOW'] ?? '30');
      final focusSurah = int.parse(Platform.environment['QURAN_DIAG_SURAH'] ?? '1');
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
        final samples = CorpusAudio.decodeWav(File(audio).readAsBytesSync());
        final startSample = (start * _sampleRate).round();
        final windowSamples = (window * _sampleRate).round();
        final fragment = await transcriber.transcribe(
          Float32List.sublistView(samples, startSample, startSample + windowSamples),
          offsetSample: startSample,
        );
        final decoded = QuranText.normalize(fragment.text);
        stdout.writeln('转写（${fragment.words.length} 词）：$decoded');

        final matcher = QuranMatcher(library, recallBalance: 0.5);
        final recalled = matcher.recall(decoded, limit: 200);
        stdout.writeln('\n=== 召回前 15（ref 分数）===');
        for (final entry in recalled.take(15)) {
          final verse = library.verses[entry.key];
          stdout.writeln('  ${verse.ref}  ${entry.value.toStringAsFixed(4)}');
        }
        stdout.writeln('第 $focusSurah 章在召回中的排名：');
        for (var rank = 0; rank < recalled.length; rank++) {
          final verse = library.verses[recalled[rank].key];
          if (verse.surah != focusSurah) continue;
          stdout.writeln(
            '  第 ${rank + 1} 名  ${verse.ref}  ${recalled[rank].value.toStringAsFixed(4)}',
          );
        }

        final evidence = fragment.segments.first.evidence;
        final result = matcher.match(evidence, decoded, maxSpan: 8, runnerUpLimit: 2000);
        stdout.writeln('\n=== 精排结果 ===');
        final champion = result.champion;
        stdout.writeln(
          'champion: ${champion == null ? '无' : '${champion.surah}:${champion.ayahStart}-${champion.ayahEnd}'}'
          '  score=${champion?.sortScore.toStringAsFixed(3) ?? '-'}',
        );
        final all = <VerseMatchCandidate>[
          if (champion != null) champion,
          ...result.runnersUp,
        ];
        stdout.writeln('候选总数 ${all.length}；第 $focusSurah 章的候选：');
        for (var rank = 0; rank < all.length; rank++) {
          final candidate = all[rank];
          if (candidate.surah != focusSurah) continue;
          stdout.writeln(
            '  第 ${rank + 1} 名  '
            '${candidate.surah}:${candidate.ayahStart}-${candidate.ayahEnd}  '
            'score=${candidate.sortScore.toStringAsFixed(3)} '
            'tokens=${candidate.tokenLength}',
          );
        }
        await runner.dispose();
      }, _RealHttpOverrides());
    },
    timeout: const Timeout(Duration(minutes: 10)),
    skip: Platform.environment['QURAN_DIAG_AUDIO'] == null
        ? 'Set QURAN_DIAG_AUDIO to run the diagnosis.'
        : false,
  );
}

class _RealHttpOverrides extends HttpOverrides {}
