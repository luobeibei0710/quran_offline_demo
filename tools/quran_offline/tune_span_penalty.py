#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""跨度惩罚标定与核验：同一音频下比较「正确单节」与「它的跨度扩展」。

背景：CTC 平均负对数似然以 **token 数** 为分母时，token 越多分母越大，长序列
天然占优 —— 单节诵读容易被判成多节连读（`112:1 → 112:1-3` 即此现象，且设备端
浮点差异会把差距放大）。Dart 侧已改为以 **帧数** 为分母（帧数对同一段音频是常数，
比较才是同口径）。

本脚本对 Tilawa 官方 5 条样本，分别计算：
- `按 token 归一化` 与 `按帧归一化` 两种口径下，正确单节与其跨度扩展的分数；
- 两种口径 + 不同跨度惩罚 `P` 时，谁会被选为冠军（以及领先差距）。

用途：改动打分口径或 `spanPenalty` 后跑一次，确认 5 条样本都仍选「正确单节」，
并按表格给出的安全区间取值。

用法::

    .venv122/bin/python tune_span_penalty.py                 # 用内置 5 条样本
    .venv122/bin/python tune_span_penalty.py --penalties 0 0.1 0.2 0.3
"""

from __future__ import annotations

import argparse
import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from diag_ctc import BISMILLAH, MODEL_PATH, ctc_score  # noqa: E402
from verify_conversion import ASSETS, VOCAB_PATH, load_audio  # noqa: E402

TOKENS_PATH = os.path.join(ASSETS, "quran_ctc_tokens.json")
SAMPLES_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "samples")

#: 官方样本：音频文件 -> (正确节的 token 键, 展示名, 章, 起始节)
SAMPLES: list[tuple[str, str, int, int]] = [
    ("001001.mp3", "1:1:1", "1:1", 1, 1),
    ("001002.mp3", "1:2:2", "1:2", 1, 2),
    ("002255.mp3", "2:255:255", "2:255", 2, 255),
    ("036001.mp3", "36:1:1", "36:1", 36, 1),
    ("112001.mp3", "112:1:1", "112:1", 112, 1),
]


def candidate_keys(surah: int, ayah: int, max_extra: int = 3) -> list[tuple[str, int]]:
    """构造「正确单节 + 跨度扩展」候选。

    Args:
        surah: 章号。
        ayah: 起始节。
        max_extra: 向后扩展的最大节数。

    Returns:
        ``(token 表键, 跨度节数)`` 列表，第一项为正确单节。
    """
    keys = [(f"{surah}:{ayah}:{ayah}", 1)]
    keys.extend((f"{surah}:{ayah}:{ayah + k}", k + 1) for k in range(1, max_extra + 1))
    return keys


def score_with_bismillah_trim(logprobs: np.ndarray, ids: list[int], blank_id: int) -> tuple[float, int]:
    """与 Dart 侧 `QuranMatcher._scoreTokens` 等价：候选带太斯米前缀时取更优者。

    Args:
        logprobs: ``[timeSteps, vocabSize]`` 对数概率。
        ids: 候选 token 序列。
        blank_id: blank token id。

    Returns:
        ``(平均负对数似然, 生效的 token 数)``；生效 token 数用于换算「按帧」分数
        —— 剥离太斯米后实际使用的是更短的序列，不能用原序列长度换算。
    """
    best = ctc_score(logprobs, ids, blank_id)
    length = len(ids)
    if len(ids) > len(BISMILLAH) and ids[: len(BISMILLAH)] == BISMILLAH:
        trimmed_score = ctc_score(logprobs, ids[len(BISMILLAH):], blank_id)
        if trimmed_score < best:
            best = trimmed_score
            length = len(ids) - len(BISMILLAH)
    return best, length


def pick_winner(entries: list[dict], normalize: str, penalty: float) -> tuple[str, float]:
    """按给定口径与惩罚挑冠军。

    Args:
        entries: 每个候选的 ``{"name", "span", "score_tok", "score_frame"}``。
        normalize: ``token`` 或 ``frame``。
        penalty: 每多连读一节的惩罚。

    Returns:
        ``(冠军名, 冠军与次优的差距)``。
    """
    key = "score_tok" if normalize == "token" else "score_frame"
    ranked = sorted(entries, key=lambda e: e[key] + penalty * (e["span"] - 1))
    margin = float("inf") if len(ranked) < 2 else (
        ranked[1][key] + penalty * (ranked[1]["span"] - 1) - (ranked[0][key] + penalty * (ranked[0]["span"] - 1))
    )
    return ranked[0]["name"], margin


def main() -> int:
    parser = argparse.ArgumentParser(description="跨度惩罚标定与核验")
    parser.add_argument("--penalties", nargs="*", type=float, default=[0.0, 0.05, 0.1, 0.15, 0.2, 0.3, 0.35])
    args = parser.parse_args()

    import onnxruntime as ort

    vocab = {int(k): v for k, v in json.load(open(VOCAB_PATH, encoding="utf-8")).items()}
    blank_id = max(vocab)
    tokens_table = json.load(open(TOKENS_PATH, encoding="utf-8"))
    session = ort.InferenceSession(MODEL_PATH, providers=["CPUExecutionProvider"])

    all_entries: dict[str, list[dict]] = {}
    for filename, correct_key, label, surah, ayah in SAMPLES:
        audio = load_audio(os.path.join(SAMPLES_DIR, filename))
        logprobs = session.run(
            None,
            {
                "audio_signal": audio[None, :].astype(np.float32),
                "length": np.array([audio.shape[0]], dtype=np.int64),
            },
        )[0][0]
        frames = logprobs.shape[0]

        entries: list[dict] = []
        for key, span in candidate_keys(surah, ayah):
            ids = tokens_table.get(key)
            if ids is None:
                continue
            score_tok, effective_tokens = score_with_bismillah_trim(logprobs, ids, blank_id)
            if score_tok >= 1e9:
                entries.append({"name": key, "span": span, "score_tok": 1e9, "score_frame": 1e9, "tokens": len(ids)})
                continue
            # 同口径换算：按帧 = 总 NLL / 帧数 = 按 token * 生效token数 / 帧数
            entries.append(
                {
                    "name": key,
                    "span": span,
                    "score_tok": score_tok,
                    "score_frame": score_tok * effective_tokens / frames,
                    "tokens": len(ids),
                }
            )
        all_entries[label] = entries

        print(f"\n=== {label}（{filename}，{len(audio) / 16000:.2f}s，{frames} 帧）正确节 {correct_key} ===")
        print(f"{'候选':<12}{'跨度':>4}{'token':>7}{'按token':>10}{'按帧':>9}")
        for entry in entries:
            tok = "不可行" if entry["score_tok"] >= 1e9 else f"{entry['score_tok']:.3f}"
            fr = "不可行" if entry["score_frame"] >= 1e9 else f"{entry['score_frame']:.3f}"
            print(f"{entry['name']:<12}{entry['span']:>4}{entry['tokens']:>7}{tok:>10}{fr:>9}")

    print("\n\n== 决策核验（冠军是否等于正确单节）==")
    header = f"{'样本':<8}{'按token(现状)':>16}" + "".join(f"{'按帧 P=' + str(p):>14}" for p in args.penalties)
    print(header)
    for label, entries in all_entries.items():
        correct = entries[0]["name"]
        name_tok, margin_tok = pick_winner(entries, "token", 0.35)
        cells = []
        for penalty in args.penalties:
            name_frame, margin_frame = pick_winner(entries, "frame", penalty)
            cells.append("正确" if name_frame == correct else f"错→{name_frame}")
        flag = "正确" if name_tok == correct else f"错→{name_tok}"
        print(f"{label:<8}{flag:>16}" + "".join(f"{cell:>14}" for cell in cells))
    return 0


if __name__ == "__main__":
    sys.exit(main())
