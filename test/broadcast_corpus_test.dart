import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quran_offline_demo/broadcast/data/broadcast_corpus.dart';
import 'package:quran_offline_demo/quran_offline/quran_matcher.dart';
import 'package:quran_offline_demo/quran_offline/quran_text.dart';

/// 记录所有资产请求，用来证明广播功能没有读取旧经文库。
class _RecordingBundle extends CachingAssetBundle {
  final List<String> requested = <String>[];

  @override
  Future<ByteData> load(String key) async {
    requested.add(key);
    return rootBundle.load(key);
  }

  @override
  Future<String> loadString(String key, {bool cache = true}) async {
    requested.add(key);
    return rootBundle.loadString(key, cache: cache);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BroadcastQuranLibrary 资源完整性', () {
    late BroadcastQuranLibrary library;

    setUpAll(() async {
      library = await BroadcastQuranLibrary.load();
    });

    test('覆盖第 1、67、112 章共 41 节，节号连续且唯一', () {
      expect(library.verses, hasLength(41));
      expect(library.manifest.verseCount, 41);
      expect(library.manifest.surahs, <int>[1, 67, 112]);
      expect(library.manifest.corpusId, 'tanzil-1.1-uthmani-surah-001-067-112');
      expect(library.manifest.corpusVersion, '1.1');

      final refs = <String>[for (final verse in library.verses) verse.ref];
      expect(refs.toSet(), hasLength(41));

      const expected = <int, int>{1: 7, 67: 30, 112: 4};
      for (final entry in expected.entries) {
        final verses = library.versesOfSurah(entry.key)!;
        expect(verses, hasLength(entry.value));
        expect(
          <int>[for (final verse in verses) verse.ayah],
          <int>[for (var ayah = 1; ayah <= entry.value; ayah++) ayah],
        );
      }
    });

    test('新库只含三章，其他章明确不可用（不回退旧库）', () {
      for (final surah in <int>[2, 18, 36, 55, 68, 114]) {
        expect(library.versesOfSurah(surah), isNull, reason: '第 $surah 章不属于新库');
        expect(library.verse(surah, 1), isNull);
        expect(library.tokensFor(surah, 1, 1), isNull);
      }
    });

    test('每一节都有 token 序列，且解码回原文', () {
      for (final verse in library.verses) {
        final tokens = library.tokensFor(verse.surah, verse.ayah, verse.ayah);
        expect(tokens, isNotNull, reason: '${verse.ref} 缺少 token 序列');
        expect(tokens, isNotEmpty);
        final decoded = <String>[
          for (final id in tokens!)
            if ((library.vocab[id] ?? '').isNotEmpty && !library.vocab[id]!.startsWith('<'))
              library.vocab[id]!,
        ].join().replaceAll('\u2581', ' ');
        expect(
          QuranText.normalize(decoded),
          QuranText.normalize(verse.textUthmani),
          reason: '${verse.ref} token 往返不一致',
        );
      }
    });

    test('章首太斯米与首节主体被分开，节数不增加', () {
      final opening = library.structure(67, 1)!;
      final ikhlas = library.structure(112, 1)!;
      expect(opening.hasOpening, isTrue);
      expect(opening.openingWords, BroadcastQuranLibrary.bismillahWords);
      expect(opening.bodyWords, isNotEmpty);
      expect(ikhlas.hasOpening, isTrue);
      expect(ikhlas.openingWords, BroadcastQuranLibrary.bismillahWords);
      expect(ikhlas.bodyWords, QuranText.normalize('قل هو الله احد').split(' '));

      // 开端章的太斯米属于 1:1 本身，不能当成章首引导额外剥离。
      final fatihah = library.structure(1, 1)!;
      expect(fatihah.hasOpening, isFalse);
      expect(fatihah.bodyWords, BroadcastQuranLibrary.bismillahWords);

      // 无前缀的普通节不带引导。
      expect(library.structure(67, 2)!.hasOpening, isFalse);
      expect(library.structure(67, 2)!.openingWords, isEmpty);
    });

    test('原样保留上游 sourceText，不改写', () async {
      final raw =
          jsonDecode(
                await rootBundle.loadString(
                  '${BroadcastQuranLibrary.assetDir}/verses_001_067_112.json',
                ),
              )
              as Map<String, dynamic>;
      final verses = raw['verses'] as List<dynamic>;
      for (final item in verses) {
        final map = item as Map<String, dynamic>;
        expect(
          library.verse(map['surah'] as int, map['ayah'] as int)!.textUthmani,
          map['sourceText'],
          reason: '${map['surah']}:${map['ayah']} 的展示文本必须与上游逐字一致',
        );
      }
      // 67:1 的上游文本带章首太斯米前缀，派生结构把它单独识别出来。
      expect(
        QuranText.normalize(library.verse(67, 1)!.textUthmani).startsWith(
          BroadcastQuranLibrary.bismillahWords.join(' '),
        ),
        isTrue,
      );
    });
  });

  group('广播功能与旧经文库的隔离', () {
    test('加载只请求广播资源与词表，从不请求旧经文与旧 token 表', () async {
      final recorder = _RecordingBundle();
      await BroadcastQuranLibrary.load(bundle: recorder);

      expect(recorder.requested, isNotEmpty);
      for (final key in recorder.requested) {
        expect(
          key.endsWith('quran.json') || key.endsWith('quran_ctc_tokens.json'),
          isFalse,
          reason: '广播功能不得读取旧库文件：$key',
        );
      }
      expect(
        recorder.requested,
        containsAll(<String>[
          '${BroadcastQuranLibrary.assetDir}/manifest.json',
          '${BroadcastQuranLibrary.assetDir}/verses_001_067_112.json',
          '${BroadcastQuranLibrary.assetDir}/verse_ctc_tokens.json',
        ]),
      );
      expect(recorder.requested, contains('assets/quran_offline/vocab.json'));
    });

    test('注入新库索引的匹配器只在 41 节内检索', () async {
      final library = await BroadcastQuranLibrary.load();
      final matcher = QuranMatcher(library);
      expect(matcher.verseIndex.verses, hasLength(41));

      final recalled = matcher.recall('قل هو الله احد');
      expect(recalled, isNotEmpty);
      for (final entry in recalled) {
        final verse = library.verses[entry.key];
        expect(<int>[1, 67, 112], contains(verse.surah));
      }
    });
  });

  group('新库 token 表清单', () {
    test('跨度条目与节数一致，且不超过最大跨度', () async {
      final raw =
          jsonDecode(await rootBundle.loadString(
                '${BroadcastQuranLibrary.assetDir}/verse_ctc_tokens.json',
              ))
              as Map<String, dynamic>;
      final tokens = raw['tokens'] as Map<String, dynamic>;
      final singles = tokens.keys.where((key) {
        final parts = key.split(':');
        return parts[1] == parts[2];
      });
      expect(singles, hasLength(41));
      for (final key in tokens.keys) {
        final parts = key.split(':').map(int.parse).toList();
        expect(parts[2] - parts[1], inInclusiveRange(0, 3));
      }
    });
  });
}
