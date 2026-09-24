/// Headless on-device acceptance for the bundled corpus (debug define only).
library;

import 'dart:convert';
import 'package:flutter/services.dart';

import 'corpus_audio.dart';
import 'corpus_catalog.dart';
import 'package:quran_broadcast_sdk/quran_offline/offline_transcriber.dart';
import 'quran_recognizer.dart';
import 'reference_text.dart';
import 'package:quran_broadcast_sdk/quran_offline/word_alignment.dart';
import 'package:quran_broadcast_sdk/quran_offline/word_error_rate.dart';

Future<bool> checkOfflineCorpus(
  QuranRecognizer recognizer, {
  required void Function(String) log,
  AssetBundle? bundle,
}) async {
  final source = bundle ?? rootBundle;
  final items = await CorpusCatalog.load(bundle: source, listDir: (_) async => []);
  if (items.isEmpty) throw StateError('No bundled corpus available for acceptance');
  var passed = 0;
  for (final item in items) {
    final data = await source.load(item.audio.assetKey!);
    final samples = CorpusAudio.decodeWav(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
    final watch = Stopwatch()..start();
    final result = await OfflineTranscriber(
      runner: recognizer.runner,
      decoder: recognizer.decoder,
      vocab: recognizer.assets.vocab,
    ).transcribe(samples);
    watch.stop();
    final words = <String>[
      for (final ref in item.expectedRefs) ...recognizer.assets.versesByRef[ref]!.words,
    ];
    final reference = CorpusCatalog.fixedReference(
      ReferenceText(words: words, rawText: words.join(' '), source: item.id),
      includesBismillah: item.includesBismillah,
    );
    final metrics = WordAlignment.align(reference.words, result.words);
    final strict = WordErrorRate.compare(reference.words, result.words);
    final ok = metrics.f1 >= .9 && metrics.precision >= .9 && metrics.coverage >= .9;
    if (ok) passed++;
    final row = {
      'id': item.id, 'f1': metrics.f1, 'precision': metrics.precision,
      'recall': metrics.coverage, 'strictWer': strict.rate,
      'referenceWords': reference.words.length, 'hypothesisWords': result.words.length,
      'segments': result.segments.length, 'seconds': watch.elapsedMilliseconds / 1000,
      'passed': ok,
    };
    // Keep each JSON row below logcat's line limit; full text is in the host report.
    log('OFFLINE_RESULT ${jsonEncode(row)}');
  }
  log('OFFLINE_COMPLETE passed=$passed total=${items.length}');
  return passed == items.length;
}
