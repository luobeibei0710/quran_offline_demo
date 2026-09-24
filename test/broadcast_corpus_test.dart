import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quran_broadcast_sdk/broadcast/data/broadcast_corpus.dart';
import 'package:quran_broadcast_sdk/quran_offline/quran_assets.dart';
import 'package:quran_broadcast_sdk/quran_offline/quran_matcher.dart';
import 'package:quran_broadcast_sdk/quran_offline/quran_text.dart';

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

  group('全经语料库完整性', () {
    late BroadcastQuranLibrary library;

    setUpAll(() async {
      library = await BroadcastQuranLibrary.load();
    });

    test('覆盖 114 章 6236 节，节号连续且唯一', () {
      expect(library.verses, hasLength(6236));
      expect(library.manifest.verseCount, 6236);
      expect(library.manifest.surahCount, 114);
      expect(library.chapters, hasLength(114));
      expect(library.manifest.corpusId, 'tanzil-1.1-uthmani-full');

      final refs = <String>[for (final verse in library.verses) verse.ref];
      expect(refs.toSet(), hasLength(6236));

      for (final chapter in library.chapters.values) {
        final verses = library.versesOfSurah(chapter.surah)!;
        expect(verses, hasLength(chapter.ayahCount), reason: '第 ${chapter.surah} 章节数不符');
        expect(verses.first.ayah, 1);
        expect(verses.last.ayah, chapter.ayahCount);
      }
    });

    test('章名元数据可用于界面展示', () {
      // 转写按数据源原文（拼写包含长音 aa），不做「美化」以免与上游不一致。
      expect(library.chapter(112)!.nameTransliterated, 'Al-Ikhlaas');
      expect(library.chapter(67)!.nameTransliterated, 'Al-Mulk');
      expect(library.chapter(1)!.nameEnglish, 'The Opening');
      expect(library.chapter(1)!.label, '第 1 章 Al-Faatiha');
    });

    test('每一节都有 token 序列，抽查可解码回原文', () {
      final refs = <String>[
        '1:1',
        '2:255',
        '36:1',
        '55:1',
        '67:1',
        '112:1',
        '114:6',
      ];
      for (final ref in refs) {
        final parts = ref.split(':');
        final surah = int.parse(parts[0]);
        final ayah = int.parse(parts[1]);
        final tokens = library.tokensFor(surah, ayah, ayah);
        expect(tokens, isNotNull, reason: '$ref 缺少 token 序列');
        expect(tokens, isNotEmpty);
        final decoded = <String>[
          for (final id in tokens!)
            if ((library.vocab[id] ?? '').isNotEmpty && !library.vocab[id]!.startsWith('<'))
              library.vocab[id]!,
        ].join().replaceAll('\u2581', ' ');
        expect(
          QuranText.normalize(decoded),
          QuranText.normalize(library.verse(surah, ayah)!.textUthmani),
          reason: '$ref token 往返不一致',
        );
      }
      // 全量存在性：每节至少有一条单节 token 序列。
      var missing = 0;
      for (final verse in library.verses) {
        if (library.tokensFor(verse.surah, verse.ayah, verse.ayah) == null) missing++;
      }
      expect(missing, 0, reason: '有 $missing 节缺少 token 序列');
    });

    test('章首太斯米按文本判定：112 节带引导，1:1 与 9:1 不带', () {
      // 上游除第 1 章（太斯米即 1:1）与第 9 章（忏悔章无太斯米）外，
      // 其余 112 章的章首节都带太斯米前缀。
      var prefixed = 0;
      for (var surah = 1; surah <= 114; surah++) {
        if (library.hasChapterOpening(surah, 1)) prefixed++;
      }
      expect(prefixed, 112);
      expect(library.hasChapterOpening(1, 1), isFalse);
      expect(library.hasChapterOpening(9, 1), isFalse);
      expect(library.hasChapterOpening(2, 1), isTrue);

      final fatihah = library.structure(1, 1)!;
      expect(fatihah.hasOpening, isFalse);
      expect(fatihah.bodyWords, BroadcastQuranLibrary.bismillahWords);

      final baqarah = library.structure(2, 1)!;
      expect(baqarah.hasOpening, isTrue);
      expect(baqarah.openingWords, BroadcastQuranLibrary.bismillahWords);
      expect(baqarah.bodyWords, isNotEmpty);
      expect(baqarah.allWords.length, greaterThan(fatihah.allWords.length));

      // 无前缀的普通节也要返回结构（引导为空），而不是 null。
      final plain = library.structure(2, 2)!;
      expect(plain.hasOpening, isFalse);
      expect(plain.allWords, isNotEmpty);
    });

    test('原样保留上游 sourceText，不改写', () async {
      final raw =
          jsonDecode(await rootBundle.loadString('${BroadcastQuranLibrary.assetDir}/quran.json'))
              as Map<String, dynamic>;
      var mismatched = 0;
      for (final item in raw['verses'] as List<dynamic>) {
        final map = item as Map<String, dynamic>;
        final verse = library.verse(map['surah'] as int, map['ayah'] as int);
        if (verse == null || verse.textUthmani != map['sourceText']) mismatched++;
      }
      expect(mismatched, 0, reason: '展示文本必须与上游逐字一致');
    });
  });

  group('广播功能与旧经文库的隔离', () {
    test('加载只请求广播资源与词表，从不请求旧经文与旧 token 表', () async {
      final recorder = _RecordingBundle();
      await BroadcastQuranLibrary.load(bundle: recorder);

      expect(recorder.requested, isNotEmpty);
      for (final key in recorder.requested) {
        expect(
          key.endsWith('quran.json') && !key.contains('broadcast_quran'),
          isFalse,
          reason: '广播功能不得读取旧库文件：$key',
        );
        expect(
          key.endsWith('quran_ctc_tokens.json'),
          isFalse,
          reason: '广播功能不得读取旧库 token 表：$key',
        );
      }
      expect(
        recorder.requested,
        containsAll(<String>[
          '${BroadcastQuranLibrary.assetDir}/manifest.json',
          '${BroadcastQuranLibrary.assetDir}/quran.json',
          '${BroadcastQuranLibrary.assetDir}/verse_ctc_tokens.json',
        ]),
      );
      expect(recorder.requested, contains(QuranAssets.vocabAssetKey));
    });

    test('注入全经索引的匹配器只在广播语料内检索', () async {
      final library = await BroadcastQuranLibrary.load();
      final matcher = QuranMatcher(library);
      expect(matcher.verseIndex.verses, hasLength(6236));

      final recalled = matcher.recall('قل هو الله احد');
      expect(recalled, isNotEmpty);
      // 全经下 112:1 必须出现在候选里（内容完全一致）。
      final refs = <String>[for (final entry in recalled) library.verses[entry.key].ref];
      expect(refs, contains('112:1'));
    });
  });

  group('token 表清单', () {
    test('跨度条目覆盖全部单节且不超过最大跨度', () async {
      final raw =
          jsonDecode(
                await rootBundle.loadString(
                  '${BroadcastQuranLibrary.assetDir}/verse_ctc_tokens.json',
                ),
              )
              as Map<String, dynamic>;
      final tokens = raw['tokens'] as Map<String, dynamic>;
      final singles = tokens.keys.where((key) {
        final parts = key.split(':');
        return parts[1] == parts[2];
      });
      expect(singles, hasLength(6236));
      for (final key in tokens.keys) {
        final parts = key.split(':').map(int.parse).toList();
        // maxSpan=8：全经里有大量极短节（开端章 2–9 词/节），30 秒片段可跨 5–6 节，
        // 上限取 4 会让匹配范围明显窄于转写内容。
        expect(parts[2] - parts[1], inInclusiveRange(0, 7));
      }
    });
  });
}
