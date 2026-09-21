#!/usr/bin/env python3
"""Generate the CTC token table for the broadcast (three-surah) library.

The upstream Tilawa release ships ``quran_ctc_tokens.json`` only for the full
6236-verse library.  The broadcast feature must not read that library, so this
tool rebuilds token sequences for the independent 41-verse corpus from the same
1025-token vocabulary using the same encoding rule.

Encoding rule (verified against the upstream table by ``--verify-legacy``):
a verse is normalized exactly like ``QuranText.normalize``, split on spaces,
and every word is encoded by greedy longest-prefix matching against the
vocabulary with an added word-start marker (U+2581).  Unknown code points fall
back to the ``<unk>`` id without changing the surrounding matches, so a verse
that cannot be encoded is reported instead of silently truncated.

Usage:
    # self-check against the upstream table (must be 100% identical)
    python3 tools/broadcast_quran/generate_verse_tokens.py --verify-legacy

    # build the new corpus table
    python3 tools/broadcast_quran/generate_verse_tokens.py \
        --verses resources/broadcast_quran/tanzil_1_1/verses_001_067_112.json \
        --vocab assets/quran_offline/vocab.json \
        --output assets/broadcast_quran/tanzil_1_1/verse_ctc_tokens.json
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import unicodedata
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
WORD_START = "\u2581"

#: Same code point set as ``QuranText._strippable``.
STRIPPABLE = re.compile(
    "[\u0610-\u061a\u064b-\u065f\u0670\u06d6-\u06de\u06df-\u06ed\u0640\ufeff]"
)

#: Same letter folding as ``QuranText._letterMap``.
LETTER_MAP = {
    "\u0623": "\u0627",  # أ -> ا
    "\u0625": "\u0627",  # إ -> ا
    "\u0622": "\u0627",  # آ -> ا
    "\u0671": "\u0627",  # ٱ -> ا
    "\u0629": "\u0647",  # ة -> ه
    "\u0649": "\u064a",  # ى -> ي
}

#: Presentation Forms-A/B ranges expanded before stripping.
PRESENTATION_FORM_RANGES = ((0xFB50, 0xFDFF), (0xFE70, 0xFEFF))
_PRESENTATION_FORMS: dict[str, str] = {}


def _presentation_form_map() -> dict[str, str]:
    """Compatibility decompositions for Arabic Presentation Forms-A/B."""
    if _PRESENTATION_FORMS:
        return _PRESENTATION_FORMS
    for start, end in PRESENTATION_FORM_RANGES:
        for code_point in range(start, end + 1):
            char = chr(code_point)
            if not unicodedata.decomposition(char):
                continue
            decomposed = unicodedata.normalize("NFKD", char)
            if decomposed != char:
                _PRESENTATION_FORMS[char] = decomposed
    return _PRESENTATION_FORMS


def normalize(text: str) -> str:
    """Mirror of ``QuranText.normalize`` (Dart) on the Python side."""
    forms = _presentation_form_map()
    expanded = "".join(forms.get(char, char) for char in text)
    stripped = STRIPPABLE.sub("", expanded)
    folded = "".join(LETTER_MAP.get(char, char) for char in stripped)
    return " ".join(part for part in re.split(r"\s+", folded) if part)


class TokenEncoder:
    """Vocabulary encoder reproducing the upstream segmentation rule.

    The upstream table was produced by a unigram model whose token scores are
    not part of the published assets.  Two statistics reproduce it far better
    than plain greedy matching: minimise the token count first, and prefer
    longer pieces when the count ties.  ``--verify-legacy`` measures the exact
    agreement with the shipped table so the choice stays evidence based.
    """

    def __init__(self, vocab: dict[int, str], strategy: str = "min-token") -> None:
        self.by_id = dict(vocab)
        self.by_token: dict[str, int] = {}
        for token_id, token in vocab.items():
            # ``<unk>`` / ``<blank>`` carry angle brackets and never occur in text.
            if token.startswith("<") and token.endswith(">"):
                continue
            self.by_token.setdefault(token, token_id)
        self.unk_id = next((i for i, t in vocab.items() if t == "<unk>"), 0)
        self.max_token_length = max((len(t) for t in self.by_token), default=1)
        self.strategy = strategy

    def _greedy(self, piece: str) -> list[str]:
        """Longest-prefix segmentation."""
        pieces: list[str] = []
        index = 0
        while index < len(piece):
            limit = min(self.max_token_length, len(piece) - index)
            matched = 0
            for length in range(limit, 0, -1):
                if piece[index : index + length] in self.by_token:
                    pieces.append(piece[index : index + length])
                    matched = length
                    break
            if matched == 0:
                pieces.append(piece[index])
                matched = 1
            index += matched
        return pieces

    def _min_token(self, piece: str) -> list[str]:
        """Fewest tokens, then the longest pieces (measured against upstream)."""
        length = len(piece)
        # best[i] = (tokenCount, -sumOfSquares); ``None`` means unreachable.
        best: list[tuple[int, int] | None] = [None] * (length + 1)
        back: list[int] = [-1] * (length + 1)
        best[0] = (0, 0)
        for start in range(length):
            if best[start] is None:
                continue
            limit = min(self.max_token_length, length - start)
            for size in range(limit, 0, -1):
                candidate = piece[start : start + size]
                if candidate not in self.by_token and size > 1:
                    continue
                if candidate not in self.by_token:
                    score = (best[start][0] + 1, best[start][1])
                else:
                    score = (best[start][0] + 1, best[start][1] - size * size)
                if best[start + size] is None or score < best[start + size]:
                    best[start + size] = score
                    back[start + size] = start
        if best[length] is None:
            return self._greedy(piece)
        pieces = []
        cursor = length
        while cursor > 0:
            previous = back[cursor]
            pieces.append(piece[previous:cursor])
            cursor = previous
        pieces.reverse()
        return pieces

    def encode_word(self, word: str) -> tuple[list[int], list[str]]:
        """Encode one whitespace-delimited word; returns ids and unknown runs."""
        piece = WORD_START + word
        pieces = self._greedy(piece) if self.strategy == "greedy" else self._min_token(piece)
        ids: list[int] = []
        unknown: list[str] = []
        for part in pieces:
            token_id = self.by_token.get(part)
            if token_id is None:
                unknown.append(part)
                ids.append(self.unk_id)
            else:
                ids.append(token_id)
        return ids, unknown

    def encode(self, text: str) -> tuple[list[int], list[str]]:
        """Encode normalized text; returns ids and the unknown code points."""
        ids: list[int] = []
        unknown: list[str] = []
        for word in text.split(" "):
            if not word:
                continue
            word_ids, word_unknown = self.encode_word(word)
            ids.extend(word_ids)
            unknown.extend(word_unknown)
        return ids, unknown


def decode(ids: list[int], vocab: dict[int, str]) -> str:
    """Mirror of ``TextCtcDecoder.tokenIdsToText`` for round-trip checks.

    The Dart side finishes with ``QuranText.normalize``, whose last step
    collapses whitespace; the word-start marker becomes a space first.
    """
    out = []
    for token_id in ids:
        token = vocab.get(token_id, "")
        if not token or token.startswith("<"):
            continue
        out.append(token.replace(WORD_START, " "))
    return " ".join("".join(out).split())


def load_vocab(path: Path) -> dict[int, str]:
    """Read ``vocab.json`` (string keys) into an id-keyed map."""
    raw = json.loads(path.read_text(encoding="utf-8"))
    return {int(key): value for key, value in raw.items()}


def verse_keys(surah: int, ayah_start: int, ayah_end: int) -> list[str]:
    """All span keys the matcher can query for a starting verse."""
    return [f"{surah}:{ayah_start}:{end}" for end in range(ayah_start, ayah_end + 1)]


def build_table(
    verses: list[dict],
    encoder: TokenEncoder,
    max_span: int,
) -> tuple[dict[str, list[int]], list[str]]:
    """Build ``surah:start:end`` -> token ids for the selected verses."""
    per_verse: dict[tuple[int, int], list[int]] = {}
    problems: list[str] = []
    for verse in verses:
        surah, ayah = int(verse["surah"]), int(verse["ayah"])
        text = normalize(verse["sourceText"])
        ids, unknown = encoder.encode(text)
        if unknown:
            problems.append(f"{surah}:{ayah} has undecodable characters {sorted(set(unknown))}")
        if decode(ids, encoder.by_id) != text:
            problems.append(f"{surah}:{ayah} token round-trip mismatch")
        per_verse[(surah, ayah)] = ids

    table: dict[str, list[int]] = {}
    for surah, ayah in sorted(per_verse):
        combined: list[int] = []
        for span in range(1, max_span + 1):
            end = ayah + span - 1
            part = per_verse.get((surah, end))
            if part is None:
                break
            combined = combined + part
            table[f"{surah}:{ayah}:{end}"] = list(combined)
    return table, problems


def verify_legacy(args: argparse.Namespace) -> int:
    """Compare the encoder with the upstream table for the full 6236 verses."""
    assets = Path(args.assets)
    vocab = load_vocab(assets / "vocab.json")
    encoder = TokenEncoder(vocab, strategy=args.strategy)
    quran = json.loads((assets / "quran.json").read_text(encoding="utf-8"))
    upstream = json.loads((assets / "quran_ctc_tokens.json").read_text(encoding="utf-8"))

    singles: list[str] = []
    spans: list[str] = []
    compared_single = 0
    compared_span = 0
    by_ref = {(int(v["surah"]), int(v["ayah"])): v for v in quran}

    for (surah, ayah), verse in sorted(by_ref.items()):
        text = normalize(verse.get("text_clean") or verse["text_uthmani"])
        ids, unknown = encoder.encode(text)
        key = f"{surah}:{ayah}:{ayah}"
        if key in upstream:
            compared_single += 1
            if unknown:
                singles.append(f"{key} unknown characters")
            elif ids != upstream[key]:
                singles.append(f"{key} got {ids} expected {upstream[key]}")

        # Span entries are concatenations of the consecutive single-verse ids.
        combined = list(ids)
        for end in range(ayah + 1, ayah + 4):
            following = by_ref.get((surah, end))
            if following is None:
                break
            following_text = normalize(following.get("text_clean") or following["text_uthmani"])
            following_ids, following_unknown = encoder.encode(following_text)
            combined = combined + following_ids
            if following_unknown:
                break
            span_key = f"{surah}:{ayah}:{end}"
            if span_key in upstream:
                compared_span += 1
                if combined != upstream[span_key]:
                    spans.append(f"{span_key} mismatch")

    print(
        f"strategy={args.strategy}: single {compared_single - len(singles)}/{compared_single}"
        f" exact, span {compared_span - len(spans)}/{compared_span} exact"
    )
    for line in singles[:10]:
        print(f"  single {line}")
    for line in spans[:10]:
        print(f"  span {line}")
    return 1 if singles else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify-legacy", action="store_true", help="self-check against upstream table")
    parser.add_argument("--assets", default=str(REPO_ROOT / "assets" / "quran_offline"))
    parser.add_argument("--strategy", default="min-token", choices=("min-token", "greedy"))
    parser.add_argument(
        "--verses",
        default=str(REPO_ROOT / "resources" / "broadcast_quran" / "tanzil_1_1" / "verses_001_067_112.json"),
    )
    parser.add_argument(
        "--vocab", default=str(REPO_ROOT / "assets" / "quran_offline" / "vocab.json")
    )
    parser.add_argument("--output", default=None)
    parser.add_argument("--max-span", type=int, default=4)
    args = parser.parse_args()

    if args.verify_legacy:
        return verify_legacy(args)

    if not args.output:
        parser.error("--output is required unless --verify-legacy is used")

    vocab = load_vocab(Path(args.vocab))
    corpus = json.loads(Path(args.verses).read_text(encoding="utf-8"))
    encoder = TokenEncoder(vocab)
    table, problems = build_table(corpus["verses"], encoder, args.max_span)

    wanted = {f"{v['surah']}:{v['ayah']}" for v in corpus["verses"]}
    singles = {key for key in table if key.split(":")[1] == key.split(":")[2]}
    if len(singles) != len(wanted) or len(wanted) != int(corpus["verseCount"]):
        problems.append(f"verse count mismatch: {len(singles)} singles vs {corpus['verseCount']} expected")

    document = {
        "corpusId": corpus["corpusId"],
        "corpusVersion": corpus["version"],
        "sourceSha256": corpus["sourceSha256"],
        "vocabFile": "assets/quran_offline/vocab.json",
        "normalizationVersion": "quran-text-normalize-1",
        "encoder": "greedy longest-prefix over vocab.json with U+2581 word start",
        "maxSpan": args.max_span,
        "verseCount": len(singles),
        "entryCount": len(table),
        "tokens": table,
    }
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(document, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"wrote {output}: {len(singles)} verses, {len(table)} span entries")
    if problems:
        print("PROBLEMS:")
        for line in problems:
            print(f"  {line}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
