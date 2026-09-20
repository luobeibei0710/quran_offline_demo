#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""跨度惩罚标定与门禁：同一音频下比较「正确单节」与「它的跨度扩展」。

背景：CTC 平均负对数似然以 **token 数** 为分母时，token 越多分母越大，长序列
天然占优 —— 单节诵读容易被判成多节连读（`112:1 → 112:1-3` 即此现象，且设备端
浮点差异会把差距放大）。Dart 侧已改为以 **帧数** 为分母（帧数对同一段音频是常数，
比较才是同口径）。

本脚本对 Tilawa 官方 5 条样本，分别计算：
- `按 token 归一化` 与 `按帧归一化` 两种口径下，正确单节与其跨度扩展的分数；
- 按帧口径 + 当前跨度惩罚时谁会被选为冠军；
- **每个样本允许的最大惩罚** `(跨度分 − 正确分) / (跨度 − 1)`，以及 5 条样本的
  公共上界（惩罚必须小于它，否则该样本的正确单节会被跨度扩展抢走）。

两处防漂移：
- 惩罚值默认**从 Dart 源码 `QuranMatcher.defaultSpanPenalty` 读取**，脚本与实现不会各说各话；
- `--check` 模式下任一不符即非零退出，可直接作为「改打分/改惩罚/换模型」后的门禁。

用法::

    .venv122/bin/python tune_span_penalty.py                 # 打印标定表
    .venv122/bin/python tune_span_penalty.py --check         # 门禁：不符即退出码 1
    .venv122/bin/python tune_span_penalty.py --penalties 0 0.1 0.2 0.3
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from diag_ctc import BISMILLAH, MODEL_PATH, ctc_score  # noqa: E402
from verify_conversion import ASSETS, VOCAB_PATH, load_audio  # noqa: E402

TOKENS_PATH = os.path.join(ASSETS, "quran_ctc_tokens.json")
SAMPLES_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "samples")
REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
MATCHER_PATH = os.path.join(REPO_ROOT, "lib", "quran_offline", "quran_matcher.dart")

#: 官方样本：音频文件 -> (正确节的 token 键, 展示名, 章, 起始节)
SAMPLES: list[tuple[str, str, str, int, int]] = [
    ("001001.mp3", "1:1:1", "1:1", 1, 1),
    ("001002.mp3", "1:2:2", "1:2", 1, 2),
    ("002255.mp3", "2:255:255", "2:255", 2, 255),
    ("036001.mp3", "36:1:1", "36:1", 36, 1),
    ("112001.mp3", "112:1:1", "112:1", 112, 1),
]


def read_dart_penalty() -> float:
    """从 Dart 源码读取 `QuranMatcher.defaultSpanPenalty`。

    Returns:
        Dart 侧当前的跨度惩罚系数。

    Raises:
        SystemExit: 未能在源码中定位该常量。
    """
    text = open(MATCHER_PATH, encoding="utf-8").read()
    match = re.search(r"defaultSpanPenalty\s*=\s*([0-9.]+)", text)
    if match is None:
        print(f"未能在 {MATCHER_PATH} 中找到 defaultSpanPenalty", file=sys.stderr)
        raise SystemExit(2)
    return float(match.group(1))


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
    if len(ranked) < 2:
        return ranked[0]["name"], float("inf")
    best = ranked[0][key] + penalty * (ranked[0]["span"] - 1)
    second = ranked[1][key] + penalty * (ranked[1]["span"] - 1)
    return ranked[0]["name"], second - best


def allowed_penalty(entries: list[dict]) -> float:
    """某样本「惩罚最多能取多大，正确单节才不会被跨度抢走」。

    正确单节胜出的条件是：对每个跨度候选，`跨度分 + P×(跨度−1) > 正确分`，
    即 `P < (跨度分 − 正确分) / (跨度 − 1)`。

    Args:
        entries: 该样本的候选列表（第一项为正确单节）。

    Returns:
        允许的最大惩罚；无跨度候选时返回 ``inf``。
    """
    correct = entries[0]["score_frame"]
    limits = [
        (entry["score_frame"] - correct) / (entry["span"] - 1)
        for entry in entries[1:]
        if entry["span"] > 1
    ]
    return min(limits) if limits else float("inf")


def main() -> int:
    parser = argparse.ArgumentParser(description="跨度惩罚标定与门禁")
    parser.add_argument("--penalties", nargs="*", type=float, default=None,
                        help="对比用的惩罚取值（默认取 0/0.05/0.1/0.15/0.2/0.3/0.35）")
    parser.add_argument("--penalty", type=float, default=None,
                        help="门禁使用的惩罚值（默认从 Dart 源码读取 defaultSpanPenalty）")
    parser.add_argument("--check", action="store_true",
                        help="门禁模式：任一「正确单节未胜出」或「惩罚 ≥ 允许上界」即非零退出")
    args = parser.parse_args()

    penalty = args.penalty if args.penalty is not None else read_dart_penalty()
    penalties = args.penalties if args.penalties is not None else [0.0, 0.05, 0.1, 0.15, 0.2, 0.3, 0.35]
    if penalty not in penalties:
        penalties = sorted({penalty, *penalties})

    import onnxruntime as ort

    vocab = {int(k): v for k, v in json.load(open(VOCAB_PATH, encoding="utf-8")).items()}
    blank_id = max(vocab)
    tokens_table = json.load(open(TOKENS_PATH, encoding="utf-8"))
    session = ort.InferenceSession(MODEL_PATH, providers=["CPUExecutionProvider"])

    all_entries: dict[str, list[dict]] = {}
    allowed: dict[str, float] = {}
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
        allowed[label] = allowed_penalty(entries)

        print(f"\n=== {label}（{filename}，{len(audio) / 16000:.2f}s，{frames} 帧）正确节 {correct_key} ===")
        print(f"{'候选':<12}{'跨度':>4}{'token':>7}{'按token':>10}{'按帧':>9}")
        for entry in entries:
            tok = "不可行" if entry["score_tok"] >= 1e9 else f"{entry['score_tok']:.3f}"
            fr = "不可行" if entry["score_frame"] >= 1e9 else f"{entry['score_frame']:.3f}"
            print(f"{entry['name']:<12}{entry['span']:>4}{entry['tokens']:>7}{tok:>10}{fr:>9}")
        limit = allowed[label]
        print(f"→ 该样本允许的最大惩罚：{'∞' if limit == float('inf') else f'{limit:.3f}'}")

    print("\n\n== 决策核验（冠军是否等于正确单节）==")
    header = f"{'样本':<8}{'按token(旧口径)':>18}" + "".join(f"{'按帧 P=' + str(p):>14}" for p in penalties)
    print(header)
    for label, entries in all_entries.items():
        correct = entries[0]["name"]
        name_tok, _ = pick_winner(entries, "token", 0.35)
        cells = []
        for value in penalties:
            name_frame, _ = pick_winner(entries, "frame", value)
            cells.append("正确" if name_frame == correct else f"错→{name_frame}")
        flag = "正确" if name_tok == correct else f"错→{name_tok}"
        print(f"{label:<8}{flag:>18}" + "".join(f"{cell:>14}" for cell in cells))

    bound = min(allowed.values())
    print(f"\n按帧口径下的惩罚上界（5 条样本取最紧）：{bound:.3f}")
    print(f"当前离线惩罚（Dart `defaultSpanPenalty`）：{penalty}")
    if bound == float("inf"):
        print("无跨度候选可用于约束，跳过上界判断")
    elif penalty >= bound:
        print(f"✗ 惩罚 {penalty} ≥ 上界 {bound}：正确单节会被跨度扩展抢走")
    else:
        print(f"✓ 惩罚 {penalty} < 上界 {bound}，余量 {bound - penalty:.3f}")

    if args.check:
        failures: list[str] = []
        for label, entries in all_entries.items():
            correct = entries[0]["name"]
            winner, _ = pick_winner(entries, "frame", penalty)
            if winner != correct:
                failures.append(f"{label}: 冠军为 {winner}，期望 {correct}")
        if bound != float("inf") and penalty >= bound:
            failures.append(f"惩罚 {penalty} 不小于允许上界 {bound:.3f}")
        if failures:
            print("\n[门禁失败]")
            for item in failures:
                print(f" - {item}")
            return 1
        print(f"\n[门禁通过] 5 条官方样本均命中正确单节，惩罚 {penalty} 在安全区间内")
    return 0


if __name__ == "__main__":
    sys.exit(main())
