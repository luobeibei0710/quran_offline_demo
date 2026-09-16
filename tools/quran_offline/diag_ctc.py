#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""诊断脚本：对比同一音频下不同候选 token 序列的 CTC 分数。

用于定位「单节被误判为连读」这类问题的根因：打印若干候选序列的
平均负对数似然，以及模型在这些 token 上的平均帧概率。

用法::

    .venv122/bin/python diag_ctc.py --audio samples/112001.mp3 --keys 112:1:1 112:1:3 112:1:2
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from verify_conversion import ASSETS, VOCAB_PATH, load_audio  # noqa: E402

TOKENS_PATH = os.path.join(ASSETS, "quran_ctc_tokens.json")
MODEL_PATH = os.path.join(ASSETS, "fastconformer_full_mixed_ort122.onnx")

#: 太斯米 token 前缀
BISMILLAH = [351, 7, 59, 982, 986]


def ctc_score(logprobs: np.ndarray, ids: list[int], blank_id: int) -> float:
    """CTC 前向后向平均负对数似然（与 Dart 侧 CtcScorer 等价）。

    Args:
        logprobs: 形状 ``[timeSteps, vocabSize]`` 的对数概率。
        ids: 目标 token 序列。
        blank_id: blank token id。

    Returns:
        ``-logP(seq) / len(seq)``；不可行时返回 1e9。
    """
    time_steps, vocab_size = logprobs.shape
    target_length = len(ids)
    if target_length == 0 or target_length * 2 + 1 > time_steps:
        return 1e9

    state_count = target_length * 2 + 1
    states = [blank_id if s % 2 == 0 else ids[(s - 1) // 2] for s in range(state_count)]

    prev = np.full(state_count, -np.inf)
    prev[0] = logprobs[0][blank_id]
    if state_count > 1:
        prev[1] = logprobs[0][states[1]]

    for t in range(1, time_steps):
        curr = np.full(state_count, -np.inf)
        for s in range(state_count):
            total = prev[s]
            if s > 0:
                total = np.logaddexp(total, prev[s - 1]) if np.isfinite(total) else prev[s - 1]
            if s > 1 and states[s] != blank_id and states[s] != states[s - 2]:
                total = np.logaddexp(total, prev[s - 2]) if np.isfinite(total) else prev[s - 2]
            if np.isfinite(total):
                curr[s] = total + logprobs[t][states[s]]
        prev = curr

    final = prev[state_count - 1]
    if state_count > 1:
        final = np.logaddexp(final, prev[state_count - 2])
    if not np.isfinite(final):
        return 1e9
    return -final / target_length


def main() -> int:
    parser = argparse.ArgumentParser(description="候选 token 序列 CTC 打分对比")
    parser.add_argument("--audio", required=True, help="音频路径")
    parser.add_argument("--keys", nargs="+", required=True, help="token 表中的键，如 112:1:1")
    parser.add_argument("--extra", nargs="*", default=[], help="额外对比的 token id 列表（逗号分隔）")
    args = parser.parse_args()

    import onnxruntime as ort

    vocab = {int(k): v for k, v in json.load(open(VOCAB_PATH, encoding="utf-8")).items()}
    blank_id = max(vocab)
    tokens_table = json.load(open(TOKENS_PATH, encoding="utf-8"))

    audio = load_audio(args.audio)
    session = ort.InferenceSession(MODEL_PATH, providers=["CPUExecutionProvider"])
    logprobs = session.run(
        None,
        {
            "audio_signal": audio[None, :].astype(np.float32),
            "length": np.array([audio.shape[0]], dtype=np.int64),
        },
    )[0][0]
    print(f"音频 {os.path.basename(args.audio)} | {len(audio) / 16000:.2f}s | 帧数 {logprobs.shape[0]}")

    cases: list[tuple[str, list[int]]] = []
    for key in args.keys:
        seq = tokens_table.get(key)
        if seq is None:
            print(f"[跳过] {key} 不在 token 表中")
            continue
        cases.append((key, seq))
        if len(seq) > len(BISMILLAH) and seq[: len(BISMILLAH)] == BISMILLAH:
            cases.append((f"{key} (剥离太斯米)", seq[len(BISMILLAH) :]))
    for raw in args.extra:
        ids = [int(x) for x in raw.split(",")]
        cases.append((f"自定义 {raw}", ids))

    print(f"\n{'候选':<28}{'token数':>7}{'平均NLL':>10}   解码文本")
    for name, ids in cases:
        score = ctc_score(logprobs, ids, blank_id)
        text = "".join(vocab.get(i, "?") for i in ids).replace("\u2581", " ")
        print(f"{name:<28}{len(ids):>7}{score:>10.3f}   {text[:44]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
