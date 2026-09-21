#!/usr/bin/env python3
"""Fetch the licence-cleared Quran translations for the whole-Quran corpus.

Why data instead of a translation engine: the Quran is a **fixed text**.  A human
translation of a fixed text is both more accurate than any on-device MT engine
and orders of magnitude faster (a map lookup versus a model call), and these
editions are already cleared for redistribution.

Source: https://quran-json.risanb.com (risan/quran-json).  Its published
generation only carries editions whose licence status is ``granted``; this tool
re-verifies that status for every edition it downloads, so a silently
re-licensed or withheld edition fails the fetch instead of shipping quietly.

Licence obligations recorded per edition (QuranEnc, 7 conditions): do not
modify; credit the publisher and QuranEnc.com; state the version; keep the
transcript information; report notes back; stay up to date; no inappropriate
advertising.  Each output file therefore carries publisher / version / source /
licence verbatim so the app can display them.

Usage:
    python3 tools/broadcast_quran/fetch_translations.py --check
    python3 tools/broadcast_quran/fetch_translations.py            # 全部语言
    python3 tools/broadcast_quran/fetch_translations.py --languages en,zh,fr
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
BASE_URL = "https://quran-json.risanb.com"
OUTPUT_DIR = REPO_ROOT / "assets" / "broadcast_quran" / "full" / "translations"
CORPUS_ID = "tanzil-1.1-uthmani-full"
CORPUS_VERSE_FILE = REPO_ROOT / "assets" / "broadcast_quran" / "full" / "quran.json"
USER_AGENT = "quran-offline-demo/1.0 (+tools/broadcast_quran/fetch_translations.py)"
TIMEOUT_SECONDS = 120

#: 每个语言的首选译本（其余语言取该语言在索引中的第一个 granted 译本）。
#: 选择依据是各语言的主流通行本，而不是任意取第一个。
PREFERRED_BY_LANGUAGE = {
    "chinese": "chinese_makin",
    "english": "english_saheeh",
    "french": "french_montada",
    "german": "german_bubenheim",
    "indonesian": "indonesian_affairs",
    "malay": "malay_basumayyah",
    "persian": "persian_ih",
    "russian": "russian_rwwad",
    "spanish": "spanish_montada_eu",
    "turkish": "turkish_shahin",
    "urdu": "urdu_junagarhi",
}

#: 应用内语言标签（BCP-47 近似）到数据源语言名的映射；未列出的直接用数据源语言名。
DISPLAY_NAMES = {
    "chinese": "简体中文",
    "english": "English",
    "french": "Français",
    "german": "Deutsch",
    "indonesian": "Bahasa Indonesia",
    "japanese": "日本語",
    "korean": "한국어",
    "malay": "Bahasa Melayu",
    "persian": "فارسی",
    "portuguese": "Português",
    "russian": "Русский",
    "spanish": "Español",
    "turkish": "Türkçe",
    "urdu": "اردو",
    "uyghur": "ئۇيغۇرچە",
    "vietnamese": "Tiếng Việt",
    "hindi": "हिन्दी",
    "bengali": "বাংলা",
    "thai": "ไทย",
    "italian": "Italiano",
    "dutch": "Nederlands",
    "swedish": "Svenska",
    "ukrainian": "Українська",
    "romanian": "Română",
    "serbian": "Српски",
    "croatian": "Hrvatski",
    "lithuanian": "Lietuvių",
    "macedonian": "Македонски",
    "tajik": "Тоҷикӣ",
    "pashto": "پښتو",
    "kurdish": "کوردی",
    "kyrgyz": "Кыргызча",
    "telugu": "తెలుగు",
    "kannada": "ಕನ್ನಡ",
    "malayalam": "മലയാളം",
    "punjabi": "ਪੰਜਾਬੀ",
    "gujarati": "ગુજરાતી",
    "sinhalese": "සිංහල",
    "somali": "Soomaali",
    "hausa": "Hausa",
    "yoruba": "Yorùbá",
    "fulani": "Fulfulde",
    "oromo": "Oromoo",
    "lingala": "Lingála",
    "kinyarwanda": "Kinyarwanda",
    "ikirundi": "Ikirundi",
    "moore": "Mòoré",
    "afar": "Qafar",
    "assamese": "অসমীয়া",
    "azeri": "Azərbaycan",
    "tagalog": "Tagalog",
    "bisayan": "Bisaya",
    "maguindanao": "Maguindanaon",
    "asante": "Asante",
    "ankobambara": "Bamanankan",
    "albanian": "Shqip",
    "amharic": "አማርኛ",
    "bosnian": "Bosanski",
    "khmer": "ខ្មែរ",
    "swahili": "Kiswahili",
    "uzbek": "Oʻzbek",
    "tamil": "தமிழ்",
}


def _get_json(url: str) -> object:
    """GET a JSON document with an explicit User-Agent (the CDN rejects default ones)."""
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
        return json.load(response)


def load_index() -> dict:
    """Download the edition index (licence metadata included)."""
    return _get_json(f"{BASE_URL}/translations/index.json")


def load_corpus_refs() -> list[str]:
    """Read the verse keys the corpus actually contains, in order."""
    corpus = json.loads(CORPUS_VERSE_FILE.read_text(encoding="utf-8"))
    return [f"{verse['surah']}:{verse['ayah']}" for verse in corpus["verses"]]


def pick_editions(index: dict, languages: list[str] | None) -> list[dict]:
    """Choose one granted edition per language."""
    by_language: dict[str, list[dict]] = {}
    for edition in index.get("editions", []):
        by_language.setdefault(edition["language"], []).append(edition)

    picked: list[dict] = []
    for language in sorted(by_language):
        if languages and language not in languages:
            continue
        candidates = by_language[language]
        preferred = PREFERRED_BY_LANGUAGE.get(language)
        chosen = next(
            (item for item in candidates if item["edition"] == preferred), candidates[0]
        )
        if chosen.get("license", {}).get("status") != "granted":
            raise SystemExit(
                f"{chosen['edition']} is not 'granted' "
                f"(status={chosen.get('license', {}).get('status')!r}); refusing to bundle"
            )
        picked.append(chosen)
    return picked


def fetch_edition(edition: dict, refs: list[str]) -> dict[str, str]:
    """Download one edition in a single request and keep the corpus verses.

    整部下载（1 次请求）而不是按章下载（114 次）：62 种语言下前者约 2 分钟，
    后者要 7000 多次请求、二十多分钟。语料本身就是全经，所以丢弃的极少。
    """
    wanted = set(refs)
    verses: dict[str, str] = {}
    payload = _get_json(f"{BASE_URL}{edition['files']['quran']}")
    chapters = payload["verses"] if isinstance(payload, dict) else payload
    for chapter in chapters:
        surah = int(chapter["id"])
        for item in chapter.get("verses", []):
            key = f"{surah}:{int(item['id'])}"
            if key in wanted:
                verses[key] = str(item["translation"]).strip()
    missing = [ref for ref in refs if ref not in verses]
    if missing:
        raise SystemExit(f"{edition['edition']}: 缺少 {len(missing)} 节（如 {missing[:3]}）")
    return verses


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="只校验语言与许可，不写文件")
    parser.add_argument("--languages", default="", help="逗号分隔的语言名（默认全部）")
    args = parser.parse_args()

    languages = [item.strip() for item in args.languages.split(",") if item.strip()]
    index = load_index()
    picked = pick_editions(index, languages or None)
    refs = load_corpus_refs()
    print(f"语料 {len(refs)} 节；待下载 {len(picked)} 种语言的译本")

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    catalogue: list[dict] = []
    for edition in picked:
        language = edition["language"]
        license_info = edition.get("license", {})
        entry = {
            "language": language,
            "displayName": DISPLAY_NAMES.get(language, edition.get("language", "")),
            "editionId": edition["edition"],
            "publisher": edition.get("author"),
            "version": edition.get("version"),
            "source": edition.get("source"),
            "licenseStatus": license_info.get("status"),
            "license": license_info.get("text"),
            "licenseUrl": license_info.get("url"),
        }
        if args.check:
            print(f"  [check] {language:14} {edition['edition']:28} v{edition.get('version')}")
            continue

        verses = fetch_edition(edition, refs)
        file_name = f"{edition['edition']}.json"
        document = {
            **entry,
            "retrievedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "corpusId": CORPUS_ID,
            "verseCount": len(verses),
            "note": "只包含广播语料覆盖的节；未做任何改写（许可要求不得修改、增删）。整节粒度。",
            "verses": verses,
        }
        (OUTPUT_DIR / file_name).write_text(
            json.dumps(document, ensure_ascii=False, separators=(",", ":")), encoding="utf-8"
        )
        entry["file"] = file_name
        catalogue.append(entry)
        print(f"  {language:14} {edition['edition']:28} {len(verses)} 节 -> {file_name}")

    if args.check:
        return 0

    catalogue_target = OUTPUT_DIR / "index.json"
    catalogue_target.write_text(
        json.dumps(
            {
                "corpusId": CORPUS_ID,
                "verseCount": len(refs),
                "languageCount": len(catalogue),
                "retrievedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "obligations": (
                    "QuranEnc 许可要求：不得修改增删；署名出版方与 QuranEnc.com；"
                    "注明版本号；保留转录信息；反馈问题；保持更新；不得附加不当广告。"
                ),
                "editions": catalogue,
            },
            ensure_ascii=False,
            indent=1,
        ),
        encoding="utf-8",
    )
    total_mb = sum((OUTPUT_DIR / item["file"]).stat().st_size for item in catalogue) / 1024 / 1024
    print(f"\n完成：{len(catalogue)} 种语言，译本合计 {total_mb:.1f} MB")
    print(f"目录清单：{catalogue_target.relative_to(REPO_ROOT)}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except urllib.error.URLError as error:
        print(f"网络错误：{error}", file=sys.stderr)
        sys.exit(2)
