#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""用 Tilawa 官方测试语料验证识别准确率（不需要懂阿拉伯语）。

语料命名规则即标准答案：``SSSAAA.mp3``，例如 ``001001`` = 第 1 章第 1 节、
``002255`` = 第 2 章第 255 节。因此判定「对不对」只需比较程序识别出的章节
与文件名是否一致，人工无需阅读阿拉伯语。

本脚本做的是**声学层**验证：把音频解码出的文本与该节标准文本（``text_clean``）
做归一化后的编辑相似度比较，输出命中率与逐条明细。

用法::

    .venv122/bin/python verify_corpus.py                    # 全部样本
    .venv122/bin/python verify_corpus.py --threshold 0.9     # 自定义判定阈值
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import sys
import time

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from verify_conversion import (  # noqa: E402  （复用解码与归一化实现）
    ASSETS,
    VOCAB_PATH,
    WORD_PREFIX,
    load_audio,
    normalize_arabic,
)

HERE = os.path.dirname(os.path.abspath(__file__))
QURAN_JSON = os.path.join(ASSETS, "quran.json")
MODEL_PATH = os.path.join(ASSETS, "fastconformer_full_mixed_ort122.onnx")

#: 模型帧率：FastConformer 每帧约 80 ms（12.5 fps），用于估算速度
FRAME_RATE = 12.5


def levenshtein_ratio(a: str, b: str) -> float:
    """归一化编辑相似度（0..1）。

    Args:
        a: 文本 A。
        b: 文本 B。

    Returns:
        1 - 编辑距离 / 较长串长度。
    """
    if not a and not b:
        return 1.0
    if not a or not b:
        return 0.0
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        curr = [i]
        for j, cb in enumerate(b, 1):
            curr.append(min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = curr
    return 1.0 - prev[-1] / max(len(a), len(b))


def lcs_coverage(decoded: str, expected: str) -> float:
    """识别文本被期望文本「顺序覆盖」的比例（最长公共子序列 / 识别长度）。

    诵读音频常在节首带「太斯米」（بسم الله الرحمن الرحيم），而该节正文本身不含
    太斯米；此时整句编辑相似度会偏低，但识别文本实际上是期望文本的子序列。
    用 LCS 覆盖率可以正确度量这种情况。

    Args:
        decoded: 识别文本。
        expected: 期望文本。

    Returns:
        覆盖率（0..1）。
    """
    if not decoded:
        return 0.0
    prev = [0] * (len(expected) + 1)
    for ca in decoded:
        curr = [0]
        for j, cb in enumerate(expected, 1):
            curr.append(prev[j - 1] + 1 if ca == cb else max(prev[j], curr[j - 1]))
        prev = curr
    return prev[-1] / len(decoded)


def parse_ref(path: str) -> tuple[int, int]:
    """从文件名解析期望的章号与节号。

    Args:
        path: 形如 ``001001.mp3`` 的路径。

    Returns:
        ``(surah, ayah)``。
    """
    base = os.path.basename(path).split(".")[0]
    return int(base[0:3]), int(base[3:6])


def greedy_decode(logprobs: np.ndarray, vocab: dict[int, str], blank_id: int) -> tuple[str, int]:
    """贪心 CTC 解码（去重后拼接，等同 Dart 侧实现）。

    Args:
        logprobs: 形状 ``[timeSteps, vocabSize]``。
        vocab: token 表。
        blank_id: blank token id。

    Returns:
        ``(归一化文本, token 数)``。
    """
    frame_ids = np.argmax(logprobs, axis=1).tolist()
    ids: list[int] = []
    previous = -1
    for token in frame_ids:
        if token != previous and token != blank_id:
            ids.append(token)
        previous = token
    raw = "".join(vocab.get(i, "") for i in ids if vocab.get(i) not in ("<unk>", "<blank>"))
    return normalize_arabic(raw.replace(WORD_PREFIX, " ")), len(ids)


def main() -> int:
    parser = argparse.ArgumentParser(description="官方语料准确率验证（文件名即标准答案）")
    parser.add_argument("--model", default=MODEL_PATH, help="模型路径")
    parser.add_argument("--samples", default=os.path.join(HERE, "samples"), help="样本目录")
    parser.add_argument("--threshold", type=float, default=0.85, help="判定命中的相似度阈值")
    args = parser.parse_args()

    import onnxruntime as ort

    vocab = {int(k): v for k, v in json.load(open(VOCAB_PATH, encoding="utf-8")).items()}
    blank_id = max(vocab)
    references = {(item["surah"], item["ayah"]): item for item in json.load(open(QURAN_JSON, encoding="utf-8"))}

    files = sorted(glob.glob(os.path.join(args.samples, "*.mp3")))
    if not files:
        print(f"[ERROR] {args.samples} 下没有样本")
        return 1

    session = ort.InferenceSession(args.model, providers=["CPUExecutionProvider"])
    print(f"ORT {ort.__version__} | 模型 {os.path.basename(args.model)} | 样本 {len(files)} 个")
    print(f"判定阈值：相似度 ≥ {args.threshold}\n")

    header = f"{'文件名':<12}{'期望':<10}{'识别文本':<34}{'相似度':>8}{'token':>7}{'耗时':>9}{'结果':>6}"
    print(header)
    print("-" * len(header.encode("utf-8").decode("utf-8")))

    hits = 0
    for path in files:
        surah, ayah = parse_ref(path)
        expected = references[(surah, ayah)]["text_clean"]
        audio = load_audio(path)

        start = time.time()
        logprobs = session.run(
            None,
            {
                "audio_signal": audio[None, :].astype(np.float32),
                "length": np.array([audio.shape[0]], dtype=np.int64),
            },
        )[0][0]
        elapsed_ms = (time.time() - start) * 1000

        decoded, token_count = greedy_decode(logprobs, vocab, blank_id)
        normalized_expected = normalize_arabic(expected)
        similarity = levenshtein_ratio(decoded, normalized_expected)
        coverage = lcs_coverage(decoded, normalized_expected)
        score = max(similarity, coverage)
        ok = score >= args.threshold
        hits += 1 if ok else 0

        audio_seconds = len(audio) / 16000
        rtf = elapsed_ms / 1000 / audio_seconds if audio_seconds else 0
        label = f"{surah}:{ayah}"
        print(
            f"{os.path.basename(path):<12}{label:<10}{decoded[:32]:<34}"
            f"{score * 100:>7.1f}%{token_count:>7}{elapsed_ms:>7.0f}ms"
            f"{'  ✅' if ok else '  ❌'}"
        )
        print(
            f"{'':12}{'':10}覆盖={coverage * 100:.0f}% 编辑={similarity * 100:.0f}% "
            f"期望: {normalized_expected[:40]}  (实时率 {rtf:.3f})"
        )

    print("-" * 60)
    print(f"命中率：{hits}/{len(files)} = {hits / len(files) * 100:.0f}%")
    return 0


if __name__ == "__main__":
    sys.exit(main())
