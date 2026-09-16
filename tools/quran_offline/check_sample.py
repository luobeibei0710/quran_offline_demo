#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""对长音频做流式分段识别，输出各时间段的匹配章节（Mac 端预期结果）。

用于与真机结果对照：按与 Dart 侧一致的策略（滑动窗口 + 贪心 CTC 解码 +
全文倒排覆盖率召回）逐段给出「章:节」，不依赖人工阅读阿拉伯语。

用法::

    .venv122/bin/python check_sample.py --audio "/path/to/1阿拉伯.mp3" --window 15 --step 7.5
"""

from __future__ import annotations

import argparse
import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from verify_conversion import ASSETS, VOCAB_PATH, WORD_PREFIX, load_audio, normalize_arabic  # noqa: E402

QURAN_JSON = os.path.join(ASSETS, "quran.json")
MODEL_PATH = os.path.join(ASSETS, "fastconformer_full_mixed_ort122.onnx")
TOKENS_PATH = os.path.join(ASSETS, "quran_ctc_tokens.json")

MIN_DECODED_CHARS = 6


def build_index() -> tuple[list[dict], dict[str, list[int]]]:
    """构建经文库与「词 → 经节下标」倒排索引。

    Returns:
        ``(verses, inverted)``。
    """
    verses = json.load(open(QURAN_JSON, encoding="utf-8"))
    inverted: dict[str, list[int]] = {}
    for i, verse in enumerate(verses):
        text = normalize_arabic(verse["text_clean"] or verse["text_uthmani"])
        for word in set(text.split()):
            inverted.setdefault(word, []).append(i)
    return verses, inverted


def greedy_decode(logprobs: np.ndarray, vocab: dict[int, str], blank_id: int) -> str:
    """贪心 CTC 解码并归一化。"""
    frame_ids = np.argmax(logprobs, axis=1).tolist()
    ids: list[int] = []
    previous = -1
    for token in frame_ids:
        if token != previous and token != blank_id:
            ids.append(token)
        previous = token
    raw = "".join(vocab.get(i, "") for i in ids if vocab.get(i) not in ("<unk>", "<blank>"))
    return normalize_arabic(raw.replace(WORD_PREFIX, " "))


def match_text(decoded: str, verses: list[dict], inverted: dict[str, list[int]], top_k: int = 24) -> list[tuple[str, float]]:
    """按覆盖率召回并返回候选 ``(章:节, 得分)``。"""
    words = {w for w in decoded.split() if w}
    if not words:
        return []
    hits: dict[int, int] = {}
    for word in words:
        for index in inverted.get(word, []):
            hits[index] = hits.get(index, 0) + 1
    scored: list[tuple[str, float]] = []
    for index, count in hits.items():
        verse = verses[index]
        verse_words = set(normalize_arabic(verse["text_clean"] or verse["text_uthmani"]).split())
        coverage = count / len(words)
        if coverage <= 0:
            continue
        scored.append((f"{verse['surah']}:{verse['ayah']}", coverage))
    scored.sort(key=lambda item: -item[1])
    return scored[:top_k]


def main() -> int:
    parser = argparse.ArgumentParser(description="长音频分段识别（Mac 端预期结果）")
    parser.add_argument("--audio", required=True, help="音频路径")
    parser.add_argument("--window", type=float, default=15.0, help="识别窗口（秒）")
    parser.add_argument("--step", type=float, default=7.5, help="滑动步长（秒）")
    args = parser.parse_args()

    import onnxruntime as ort

    vocab = {int(k): v for k, v in json.load(open(VOCAB_PATH, encoding="utf-8")).items()}
    blank_id = max(vocab)
    verses, inverted = build_index()

    audio = load_audio(args.audio)
    total = len(audio) / 16000
    session = ort.InferenceSession(MODEL_PATH, providers=["CPUExecutionProvider"])
    print(f"音频 {os.path.basename(args.audio)} | {total:.1f}s | 窗口 {args.window}s / 步长 {args.step}s")
    print(f"{'时间':<16}{'匹配':<12}{'覆盖':>6}   解码文本")
    print("-" * 100)

    start = 0.0
    while start < total:
        begin = int(start * 16000)
        end = min(len(audio), int((start + args.window) * 16000))
        chunk = audio[begin:end]
        if len(chunk) < 1600:
            break
        logprobs = session.run(
            None,
            {
                "audio_signal": chunk[None, :].astype(np.float32),
                "length": np.array([chunk.shape[0]], dtype=np.int64),
            },
        )[0][0]
        decoded = greedy_decode(logprobs, vocab, blank_id)
        label = "—"
        coverage = 0.0
        if len(decoded) >= MIN_DECODED_CHARS:
            candidates = match_text(decoded, verses, inverted)
            if candidates:
                label, coverage = candidates[0]
        print(f"{start:5.1f}-{min(start + args.window, total):5.1f}s{label:>12}{coverage:>6.2f}   {decoded[:48]}")
        start += args.step
    return 0


if __name__ == "__main__":
    sys.exit(main())
