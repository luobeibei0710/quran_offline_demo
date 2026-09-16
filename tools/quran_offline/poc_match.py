#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""P1 验证：文本召回 + CTC 约束重排，确认可精确定位 surah:ayah。

方案（也是 Dart 侧将要移植的方案）：
1. 贪心 CTC 解码得到阿拉伯语文本（normalized）
2. 用文本相似度从 6236 节中召回 top-K 候选
3. 用前向后向 CTC 对数似然（ctc-rescore.ts 的等价实现）对 top-K 精排
4. 输出冠军 surah:ayah 与置信度

用法::

    .venv/bin/python poc_match.py samples/001001.mp3
    .venv/bin/python poc_match.py samples/001001.mp3 --top-k 64
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import subprocess
import sys

import numpy as np
import onnxruntime as ort

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.abspath(os.path.join(HERE, "..", "..", "assets", "quran_offline"))
MODEL_PATH = os.path.join(ASSETS, "fastconformer_full_mixed.onnx")
VOCAB_PATH = os.path.join(ASSETS, "vocab.json")
QURAN_PATH = os.path.join(ASSETS, "quran.json")
CTC_TOKENS_PATH = os.path.join(ASSETS, "quran_ctc_tokens.json")

SAMPLE_RATE = 16000
WORD_PREFIX = "\u2581"
NEG_INF = float("-inf")
IMPOSSIBLE = 1e9

DIACRITICS_RE = re.compile("[\u0610-\u061a\u064b-\u065f\u0670\u06d6-\u06de\u06df-\u06ed\u0640\ufeff]")
NORM_MAP = {
    "\u0623": "\u0627",
    "\u0625": "\u0627",
    "\u0622": "\u0627",
    "\u0671": "\u0627",
    "\u0629": "\u0647",
    "\u0649": "\u064a",
}


def normalize_arabic(text: str) -> str:
    """与 Tilawa normalizer.ts 等价的归一化。"""
    text = DIACRITICS_RE.sub("", text)
    text = "".join(NORM_MAP.get(ch, ch) for ch in text)
    return " ".join(text.split())


# --------------------------------------------------------------------------- #
# 文本相似度（对应 levenshtein.ts 的 ratio / fragmentScore）
# --------------------------------------------------------------------------- #
def ratio(a: str, b: str) -> float:
    """归一化编辑相似度 0..1。"""
    if a == b:
        return 1.0
    if not a or not b:
        return 0.0
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, start=1):
        curr = [i] + [0] * len(b)
        for j, cb in enumerate(b, start=1):
            curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + (ca != cb))
        prev = curr
    return 1.0 - prev[len(b)] / max(len(a), len(b))


def fragment_score(query: str, target: str) -> float:
    """把 query 视为 target 的片段：取最优对齐窗口比例（近似 partialRatio）。"""
    if not query or not target:
        return 0.0
    if len(query) > len(target):
        query, target = target, query
    window = len(query)
    best = 0.0
    step = max(1, window // 4)
    for i in range(0, max(1, len(target) - window + 1), step):
        best = max(best, ratio(query, target[i : i + window]))
        if best == 1.0:
            break
    return best


# --------------------------------------------------------------------------- #
# CTC 对数似然打分（对应 ctc-rescore.ts 的 scoreCtcSequence）
# --------------------------------------------------------------------------- #
def log_add_exp(a: float, b: float) -> float:
    if a == NEG_INF:
        return b
    if b == NEG_INF:
        return a
    hi, lo = max(a, b), min(a, b)
    return hi + math.log1p(math.exp(lo - hi))


def score_ctc_sequence(logprobs: np.ndarray, ids: list[int], blank_id: int) -> float:
    """前向后向 CTC 对数似然，返回「平均每 token 的负对数似然」（越小越好）。"""
    time_steps, vocab_size = logprobs.shape
    target_length = len(ids)
    if target_length == 0:
        return IMPOSSIBLE
    if target_length * 2 + 1 > time_steps:
        return IMPOSSIBLE

    state_count = target_length * 2 + 1
    states = [blank_id if s % 2 == 0 else ids[(s - 1) >> 1] for s in range(state_count)]

    prev = np.full(state_count, NEG_INF, dtype=np.float64)
    prev[0] = logprobs[0, blank_id]
    if state_count > 1:
        prev[1] = logprobs[0, states[1]]

    for t in range(1, time_steps):
        curr = np.full(state_count, NEG_INF, dtype=np.float64)
        frame = logprobs[t]
        for s in range(state_count):
            total = prev[s]
            if s > 0:
                total = log_add_exp(total, prev[s - 1])
            if s > 1 and states[s] != blank_id and states[s] != states[s - 2]:
                total = log_add_exp(total, prev[s - 2])
            if total != NEG_INF:
                curr[s] = total + frame[states[s]]
        prev = curr

    final = prev[state_count - 1]
    if state_count > 1:
        final = log_add_exp(final, prev[state_count - 2])
    if not math.isfinite(final):
        return IMPOSSIBLE
    return -final / target_length


# --------------------------------------------------------------------------- #
# 主流程
# --------------------------------------------------------------------------- #
def load_audio(path: str) -> np.ndarray:
    raw = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", path, "-f", "f32le", "-ac", "1", "-ar", str(SAMPLE_RATE), "-"],
        capture_output=True,
        check=True,
    ).stdout
    return np.frombuffer(raw, dtype=np.float32)


def main() -> int:
    parser = argparse.ArgumentParser(description="文本召回 + CTC 精确重排验证")
    parser.add_argument("audio")
    parser.add_argument("--top-k", type=int, default=64, help="CTC 精排的候选数")
    parser.add_argument("--recall", type=int, default=400, help="文本粗筛保留数")
    args = parser.parse_args()

    vocab = {int(k): v for k, v in json.load(open(VOCAB_PATH, encoding="utf-8")).items()}
    blank_id = max(vocab)
    quran = json.load(open(QURAN_PATH, encoding="utf-8"))
    ctc_tokens = json.load(open(CTC_TOKENS_PATH, encoding="utf-8"))
    print(f"经文库={len(quran)} 节, 词级 token 表={len(ctc_tokens)} 词")

    # 1) 推理
    session = ort.InferenceSession(MODEL_PATH, providers=["CPUExecutionProvider"])
    audio = load_audio(args.audio)
    outputs = session.run(
        None,
        {
            "audio_signal": audio[None, :].astype(np.float32),
            "length": np.array([audio.shape[0]], dtype=np.int64),
        },
    )
    logprobs = outputs[0][0]
    time_steps, vocab_size = logprobs.shape

    # 2) 贪心解码
    frame_ids = np.argmax(logprobs, axis=1).tolist()
    token_ids: list[int] = []
    previous = -1
    for token in frame_ids:
        if token != previous and token != blank_id:
            token_ids.append(token)
        previous = token
    decoded = normalize_arabic(
        "".join(vocab.get(i, "") for i in token_ids if vocab.get(i) not in ("<unk>", "<blank>")).replace(
            WORD_PREFIX, " "
        )
    )
    print(f"\n音节帧数={time_steps} token 数={len(token_ids)}")
    print(f"贪心解码: {decoded}")

    # 3) 文本召回（单节）：键格式为 surah:ayah_start:ayah_end，值是该 span 的 token 序列
    span_tokens: dict[tuple[int, int, int], list[int]] = {}
    for key, ids in ctc_tokens.items():
        s, a, e = (int(x) for x in key.split(":"))
        span_tokens[(s, a, e)] = ids
    single = sum(1 for s, a, e in span_tokens if a == e)
    print(f"\ntoken 表：单节={single} span={len(span_tokens) - single}")

    first_word = decoded.split()[0] if decoded.split() else ""
    scored: list[tuple[float, int, int, str]] = []
    for verse in quran:
        s, a = int(verse["surah"]), int(verse["ayah"])
        if (s, a, a) not in span_tokens:
            continue
        text = normalize_arabic(verse.get("text_clean") or verse["text_uthmani"])
        if first_word and first_word not in text:
            continue
        score = 0.55 * ratio(decoded, text) + 0.45 * fragment_score(decoded, text)
        scored.append((score, s, a, text))
    scored.sort(reverse=True, key=lambda item: item[0])
    print(f"文本召回候选={len(scored)}，top5：")
    for score, surah, ayah, _ in scored[:5]:
        print(f"  {surah}:{ayah}  text_score={score:.3f}")

    # 4) CTC 精排：对召回节点的 1..4 节 span 做前向后向打分
    rescored: list[tuple[float, int, int, int, float, int]] = []
    for text_score, s, a, _ in scored[: args.top_k]:
        for span_len in (1, 2, 3, 4):
            e = a + span_len - 1
            ids = span_tokens.get((s, a, e))
            if not ids:
                continue
            acoustic = score_ctc_sequence(logprobs, ids, blank_id)
            if acoustic < IMPOSSIBLE:
                rescored.append((acoustic, s, a, e, text_score, len(ids)))
    rescored.sort(key=lambda item: item[0])
    print(f"\nCTC 精排可行候选={len(rescored)}，top5（acoustic 越小越好）：")
    for acoustic, s, a, e, text_score, token_len in rescored[:5]:
        span = f"{s}:{a}" if a == e else f"{s}:{a}-{e}"
        print(f"  {span}  acoustic={acoustic:.4f}  text={text_score:.3f}  tokens={token_len}")

    if rescored:
        best = rescored[0]
        margin = rescored[1][0] - best[0] if len(rescored) > 1 else float("inf")
        span = f"{best[1]}:{best[2]}" if best[2] == best[3] else f"{best[1]}:{best[2]}-{best[3]}"
        print(f"\n>> 冠军: {span}  acoustic={best[0]:.4f}  与次优差距={margin:.4f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
