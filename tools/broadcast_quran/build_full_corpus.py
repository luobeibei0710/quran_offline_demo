#!/usr/bin/env python3
"""Build the whole-Quran broadcast corpus from the archived Tanzil snapshot.

The broadcast feature matches against the whole Quran, so this tool turns the
already-downloaded Tanzil full snapshot into the corpus JSON the app consumes:

* verses              — 6236 entries, upstream text kept verbatim;
* chapter metadata    — Arabic name / transliteration / English name;
* chapter-opening flag — computed from the text itself, never hard-coded.

The chapter-opening flag matters because Tanzil's text puts the Basmala at the
start of the first verse of most surahs.  That Basmala is *not* an extra verse
(the corpus must stay at 6236), it belongs to the surah's opening, whereas for
1:1 the Basmala **is** the verse.  The detection below mirrors
``BroadcastQuranLibrary.buildStructure`` in Dart: normalise the first words and
compare against the Basmala, and only treat it as a prefix when further words
follow.

Usage:
    python3 tools/broadcast_quran/build_full_corpus.py --check
    python3 tools/broadcast_quran/build_full_corpus.py
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import unicodedata
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SOURCE_TXT = REPO_ROOT / "resources" / "broadcast_quran" / "tanzil_1_1" / "quran-uthmani.txt"
NOTICE_TXT = REPO_ROOT / "resources" / "broadcast_quran" / "tanzil_1_1" / "NOTICE.txt"
OUTPUT_DIR = REPO_ROOT / "packages" / "quran_broadcast_sdk" / "assets" / "broadcast_quran" / "full"
CORPUS_ID = "tanzil-1.1-uthmani-full"
CHAPTERS_URL = "https://quran-json.risanb.com/chapters.json"
USER_AGENT = "quran-offline-demo/1.0 (+tools/broadcast_quran/build_full_corpus.py)"

BISMILLAH = ["بسم", "الله", "الرحمن", "الرحيم"]

#: Same code point set as ``QuranText._strippable`` (diacritics, tatweel, BOM).
STRIPPABLE = re.compile("[\u0610-\u061a\u064b-\u065f\u0670\u06d6-\u06de\u06df-\u06ed\u0640\ufeff]")
LETTER_MAP = {
    "\u0623": "\u0627",
    "\u0625": "\u0627",
    "\u0622": "\u0627",
    "\u0671": "\u0627",
    "\u0629": "\u0647",
    "\u0649": "\u064a",
}
PRESENTATION_FORM_RANGES = ((0xFB50, 0xFDFF), (0xFE70, 0xFEFF))
_FORMS: dict[str, str] = {}


def _presentation_forms() -> dict[str, str]:
    if _FORMS:
        return _FORMS
    for start, end in PRESENTATION_FORM_RANGES:
        for code_point in range(start, end + 1):
            char = chr(code_point)
            if not unicodedata.decomposition(char):
                continue
            decomposed = unicodedata.normalize("NFKD", char)
            if decomposed != char:
                _FORMS[char] = decomposed
    return _FORMS


def normalize(text: str) -> str:
    """Mirror of ``QuranText.normalize`` (Dart)."""
    forms = _presentation_forms()
    expanded = "".join(forms.get(char, char) for char in text)
    stripped = STRIPPABLE.sub("", expanded)
    folded = "".join(LETTER_MAP.get(char, char) for char in stripped)
    return " ".join(part for part in re.split(r"\s+", folded) if part)


def has_chapter_opening_prefix(text: str) -> bool:
    """True when the verse text carries a Basmala prefix plus more content."""
    words = normalize(text).split(" ")
    if len(words) <= len(BISMILLAH):
        # 1:1 is exactly the Basmala — the Basmala *is* that verse, not a prefix.
        return False
    return words[: len(BISMILLAH)] == BISMILLAH


def load_verses() -> list[tuple[int, int, str]]:
    """Parse ``surah|ayah|text`` lines from the archived Tanzil snapshot."""
    verses: list[tuple[int, int, str]] = []
    for line in SOURCE_TXT.read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        parts = line.split("|", 2)
        if len(parts) != 3:
            continue
        verses.append((int(parts[0]), int(parts[1]), parts[2].strip()))
    if len(verses) != 6236:
        raise SystemExit(f"expected 6236 verses in the snapshot, parsed {len(verses)}")
    return verses


def load_chapters() -> list[dict]:
    """Fetch chapter metadata (name / transliteration / ayah count)."""
    request = urllib.request.Request(CHAPTERS_URL, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=60) as response:
        chapters = json.load(response)
    if len(chapters) != 114:
        raise SystemExit(f"expected 114 chapters, got {len(chapters)}")
    return chapters


def build_document() -> dict:
    """Assemble the whole-Quran corpus document."""
    verses = load_verses()
    chapters = load_chapters()
    counts: dict[int, int] = {}
    for surah, _, _ in verses:
        counts[surah] = counts.get(surah, 0) + 1
    for chapter in chapters:
        expected = int(chapter["total_verses"])
        if counts.get(chapter["id"]) != expected:
            raise SystemExit(
                f"surah {chapter['id']} has {counts.get(chapter['id'])} verses in the "
                f"snapshot but metadata says {expected}"
            )

    prefix_count = 0
    entries = []
    for surah, ayah, text in verses:
        prefixed = has_chapter_opening_prefix(text)
        if prefixed:
            prefix_count += 1
        entries.append(
            {
                "surah": surah,
                "ayah": ayah,
                "sourceText": text,
                "hasChapterOpeningPrefix": prefixed,
            }
        )

    return {
        "corpusId": CORPUS_ID,
        "version": "1.1",
        "provider": "Tanzil Project",
        "sourceFile": "resources/broadcast_quran/tanzil_1_1/quran-uthmani.txt",
        "sourceSha256": hashlib.sha256(SOURCE_TXT.read_bytes()).hexdigest(),
        "sourceVerseCount": len(verses),
        "selectedSurahs": list(range(1, 115)),
        "verseCount": len(entries),
        "chapterOpeningPrefixCount": prefix_count,
        "notice": NOTICE_TXT.read_text(encoding="utf-8") if NOTICE_TXT.is_file() else "",
        "chapterMetadata": {
            "source": CHAPTERS_URL,
            "license": "CC BY-SA 4.0（risan/quran-json 元数据）",
            "note": "章名与章号是事实性元数据；阿拉伯原文与前缀标记来自 Tanzil 快照。",
        },
        "chapters": [
            {
                "surah": int(chapter["id"]),
                "nameArabic": chapter["name"],
                "nameTransliterated": chapter["transliteration"],
                "nameEnglish": chapter["translation"],
                "ayahCount": int(chapter["total_verses"]),
            }
            for chapter in chapters
        ],
        "verses": entries,
    }


def build_manifest(document: dict, token_table: Path) -> dict:
    """Assemble the shipping manifest for the whole-Quran corpus."""
    manifest = {
        "corpusId": document["corpusId"],
        "corpusVersion": document["version"],
        "provider": document["provider"],
        "licenseUrl": "https://tanzil.net/docs/Text_License",
        "sourceFile": document["sourceFile"],
        "sourceSha256": document["sourceSha256"],
        "sourceVerseCount": document["sourceVerseCount"],
        "surahCount": len(document["chapters"]),
        "verseCount": document["verseCount"],
        "chapterOpeningPrefixCount": document["chapterOpeningPrefixCount"],
        "versesFile": "quran.json",
        "noticeFile": "NOTICE.txt",
        "normalizationVersion": "quran-text-normalize-1",
        "tokenTableFile": "verse_ctc_tokens.json",
        "tokenTableNote": (
            "由 tools/broadcast_quran/generate_verse_tokens.py 从 assets/quran_offline/vocab.json "
            "与全经语料独立生成，不含旧经文库的任何文本或索引。上游 unigram 分词分数未公开，"
            "本表用确定性最少 token 数分词，因此排序分数的绝对值口径与旧库不同；"
            "跨度惩罚与跨度上限应结合目标语料重新标定。"
        ),
        "chapterMetadata": document["chapterMetadata"],
    }
    if token_table.is_file():
        manifest["tokenTableSha256"] = hashlib.sha256(token_table.read_bytes()).hexdigest()
        manifest["tokenTableBytes"] = token_table.stat().st_size
    else:
        manifest["tokenTableSha256"] = ""
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="只统计，不写文件")
    args = parser.parse_args()

    document = build_document()
    print(
        f"语料 {document['verseCount']} 节 / {len(document['chapters'])} 章，"
        f"章首太斯米前缀 {document['chapterOpeningPrefixCount']} 节"
    )
    if args.check:
        return 0

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    target = OUTPUT_DIR / "quran.json"
    target.write_text(json.dumps(document, ensure_ascii=False, indent=1), encoding="utf-8")
    size_mb = target.stat().st_size / 1024 / 1024
    print(f"wrote {target.relative_to(REPO_ROOT)}（{size_mb:.2f} MB）")

    notice_target = OUTPUT_DIR / "NOTICE.txt"
    notice_target.write_text(document["notice"], encoding="utf-8")
    print(f"wrote {notice_target.relative_to(REPO_ROOT)}")

    token_table = OUTPUT_DIR / "verse_ctc_tokens.json"
    manifest = build_manifest(document, token_table)
    manifest_target = OUTPUT_DIR / "manifest.json"
    manifest_target.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=1), encoding="utf-8"
    )
    token_state = "已记录哈希" if manifest["tokenTableSha256"] else "缺少 token 表，哈希留空（请先运行 token 生成脚本）"
    print(f"wrote {manifest_target.relative_to(REPO_ROOT)}（{token_state}）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
