#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""逐节孤立识别诊断：把语料里的每一节**单独**喂给模型，量出「声学 + 解码 + 文本」的天花板。

为什么需要这个实验：整段灌音（87~159 s）跑出来 F1 只有 0.75~0.86 时，无法判断误差来自
「模型听不清」还是「滑窗/跟踪跟丢」。把同一批音频**按节切开、一节一次前向**，就得到不含
任何跟踪决策的纯上限：

- 词级准确率 = 1 − WER（词级编辑距离 / 原文词数，含替换/缺失/多余）；
- 完全一致率 = 识别文本与原文逐词完全相同的节占比；
- 字符级 CER、LCS 覆盖率（后者对「音频含太斯米而正文不含」更公平）。

若孤立上限只有 ~0.9x，说明流式侧再优化也到不了 1.0；若孤立上限 ≥0.98，则整段的差距全是
滑窗/跟踪决策造成的。

用法::

    .venv122/bin/python diag_ayah_isolated.py                    # 内置语料对应的三组节
    .venv122/bin/python diag_ayah_isolated.py --ranges 036 1 5   # 指定章与节区间
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from verify_conversion import ASSETS, VOCAB_PATH, load_audio, normalize_arabic  # noqa: E402
from verify_corpus import greedy_decode, levenshtein_ratio, lcs_coverage  # noqa: E402


MODEL_PATH = os.path.join(ASSETS, "fastconformer_full_mixed_ort122.onnx")
QURAN_JSON = os.path.join(ASSETS, "quran.json")
BASE_URL = os.environ.get("BASE_URL", "https://verses.quran.com")
RECITER = os.environ.get("RECITER", "Alafasy")
DEFAULT_RANGES = [(36, 1, 5), (55, 1, 13), (67, 1, 11)]

#: 识别结果缓存（汇总时做「软化正字法」二次比较用）
SOFT_CACHE: dict[tuple[int, int], list[str]] = {}


def soften(word: str) -> str:
    """去掉长音/正字法字母，只留辅音骨架（诊断用）。

    Args:
        word: 归一化后的词。

    Returns:
        软化后的词。
    """
    return "".join(ch for ch in word if ch not in "اوىيء")


def word_alignment(ref: list[str], hyp: list[str]) -> tuple[int, int, int, int]:
    """词级编辑对齐（返回匹配、替换、缺失、多余）。

    Args:
        ref: 原文词序列。
        hyp: 识别词序列。

    Returns:
        ``(一致词, 替换, 缺失, 多余)``。
    """
    n, m = len(ref), len(hyp)
    dp = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(1, n + 1):
        dp[i][0] = i
    for j in range(1, m + 1):
        dp[0][j] = j
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            cost = 0 if ref[i - 1] == hyp[j - 1] else 1
            dp[i][j] = min(dp[i - 1][j] + 1, dp[i][j - 1] + 1, dp[i - 1][j - 1] + cost)
    # 回溯统计
    i, j = n, m
    same = sub = dele = ins = 0
    while i > 0 or j > 0:
        if i > 0 and j > 0 and dp[i][j] == dp[i - 1][j - 1] + (0 if ref[i - 1] == hyp[j - 1] else 1):
            if ref[i - 1] == hyp[j - 1]:
                same += 1
            else:
                sub += 1
            i -= 1
            j -= 1
        elif i > 0 and dp[i][j] == dp[i - 1][j] + 1:
            dele += 1
            i -= 1
        else:
            ins += 1
            j -= 1
    return same, sub, dele, ins


def fetch_wav(surah: int, ayah: int, workdir: str) -> str:
    """取某一节的官方诵读并转成 16 kHz 单声道 WAV。

    Args:
        surah: 章号。
        ayah: 节号。
        workdir: 临时目录。

    Returns:
        WAV 路径。
    """
    key = f"{surah:03d}{ayah:03d}"
    mp3 = os.path.join(workdir, f"{key}.mp3")
    wav = os.path.join(workdir, f"{key}.wav")
    if not os.path.exists(wav):
        subprocess.run(
            ["curl", "-fsSL", "--retry", "3", "-o", mp3, f"{BASE_URL}/{RECITER}/mp3/{key}.mp3"],
            check=True,
        )
        subprocess.run(
            ["ffmpeg", "-y", "-loglevel", "error", "-i", mp3, "-ar", "16000", "-ac", "1",
             "-c:a", "pcm_s16le", wav],
            check=True,
        )
    return wav


def main() -> int:
    parser = argparse.ArgumentParser(description="逐节孤立识别诊断（声学 + 解码天花板）")
    parser.add_argument("--model", default=MODEL_PATH, help="模型路径")
    parser.add_argument("--show-errors", action="store_true", help="打印词级差异示例")
    parser.add_argument("--ranges", nargs=3, type=int, action="append", metavar=("SURAH", "START", "END"),
                        help="章 起始节 结束节（可多次）")
    args = parser.parse_args()

    ranges = [(a, b, c) for a, b, c in args.ranges] if args.ranges else DEFAULT_RANGES
    show_errors = args.show_errors

    import onnxruntime as ort

    vocab = {int(k): v for k, v in json.load(open(VOCAB_PATH, encoding="utf-8")).items()}
    blank_id = max(vocab)
    verses = {(v["surah"], v["ayah"]): v for v in json.load(open(QURAN_JSON, encoding="utf-8"))}
    session = ort.InferenceSession(args.model, providers=["CPUExecutionProvider"])

    total_same = total_ref_words = total_err = 0
    exact = total = 0
    rows: list[str] = []

    with tempfile.TemporaryDirectory() as workdir:
        for surah, start, end in ranges:
            print(f"\n=== {surah}:{start}-{end} ===")
            print(f"{'节':<10}{'时长':>7}{'词数':>6}{'一致':>6}{'替换':>6}{'缺失':>6}{'多余':>6}"
                  f"{'词级准确率':>11}{'逐词全对':>9}{'CER':>7}{'LCS':>7}")
            for ayah in range(start, end + 1):
                wav = fetch_wav(surah, ayah, workdir)
                audio = load_audio(wav)
                logprobs = session.run(
                    None,
                    {"audio_signal": audio[None, :].astype(np.float32),
                     "length": np.array([audio.shape[0]], dtype=np.int64)},
                )[0][0]
                text, _ = greedy_decode(logprobs, vocab, blank_id)
                reference = normalize_arabic(verses[(surah, ayah)]["text_clean"])
                ref_words = reference.split()
                hyp_words = text.split()
                SOFT_CACHE[(surah, ayah)] = hyp_words
                same, sub, dele, ins = word_alignment(ref_words, hyp_words)
                ref_word_count = len(ref_words)
                # 太斯米两个方向的偏差都要处理（取错误最少的组合）：
                # ① 音频含太斯米而经文库正文不含 → 去掉识别文本开头的太斯米；
                # ② 经文库正文含太斯米而音频不含（如 36:1、55:1）→ 去掉参考文本开头的太斯米。
                bismillah = ["بسم", "الله", "الرحمن", "الرحيم"]
                candidates = [(ref_words, hyp_words)]
                if len(hyp_words) > 4 and hyp_words[:4] == bismillah:
                    candidates.append((ref_words, hyp_words[4:]))
                if len(ref_words) > 4 and ref_words[:4] == bismillah:
                    candidates.append((ref_words[4:], hyp_words))
                best_errors = sub + dele + ins
                alt_ref_used, alt_hyp_used = ref_words, hyp_words
                for alt_ref, alt_hyp in candidates:
                    if not alt_ref or not alt_hyp:
                        continue
                    candidate = word_alignment(alt_ref, alt_hyp)
                    if sum(candidate[1:]) < best_errors:
                        same, sub, dele, ins = candidate
                        ref_word_count = len(alt_ref)
                        alt_ref_used, alt_hyp_used = alt_ref, alt_hyp
                        best_errors = sum(candidate[1:])
                errors = sub + dele + ins
                accuracy = 1 - errors / max(ref_word_count, 1)
                total_same += same
                total_ref_words += ref_word_count
                total_err += errors
                total += 1
                if errors == 0:
                    exact += 1
                cer = 1 - levenshtein_ratio(text, reference)
                lcs = lcs_coverage(text, reference)
                rows.append(f"{surah}:{ayah}")
                if errors > 0 and show_errors:
                    pairs = [
                        f"{r}→{h}" for r, h in zip(alt_ref_used, alt_hyp_used) if r != h
                    ]
                    print(f"        参考 {len(alt_ref_used)} 词 / 识别 {len(alt_hyp_used)} 词；"
                          f"差异示例：{'  '.join(pairs[:6])}")
                print(f"{f'{surah}:{ayah}':<10}{len(audio) / 16000:>6.1f}s{ref_word_count:>6}"
                      f"{same:>6}{sub:>6}{dele:>6}{ins:>6}{accuracy:>11.3f}"
                      f"{'是' if errors == 0 else '否':>9}{cer:>7.2f}{lcs:>7.2f}")

    print("\n== 汇总（逐节孤立：不含任何滑窗/跟踪决策）==")
    # 附加口径：软化「长音/正字法」差异后再比一次。
    # 经文库 text_clean 采用书写形式（Uthmani 常省略长音阿列夫/瓦乌），模型输出的是读音形式
    # （صرط vs صراط、سموت vs سماوات），严格逐词比对会把「同一句话」判成错误。
    # 这里把两边都去掉长音字母（ا و ي ء）再对齐，用来区分「书写差异」与「真听错」。
    soft_err = soft_ref_words = 0
    for surah, start, end in ranges:
        for ayah in range(start, end + 1):
            reference = normalize_arabic(verses[(surah, ayah)]["text_clean"])
            ref_words = reference.split()
            if len(ref_words) > 4 and ref_words[:4] == ["بسم", "الله", "الرحمن", "الرحيم"]:
                ref_words = ref_words[4:]
            cached = SOFT_CACHE.get((surah, ayah))
            if cached is None:
                continue
            hyp_words = cached
            soft_ref = [soften(w) for w in ref_words]
            soft_hyp = [soften(w) for w in hyp_words]
            soft_ref = [w for w in soft_ref if w]
            soft_hyp = [w for w in soft_hyp if w]
            result = word_alignment(soft_ref, soft_hyp)
            soft_err += sum(result[1:])
            soft_ref_words += len(soft_ref)
    if soft_ref_words:
        print(f"软化正字法后（去掉长音字母再比）：{soft_ref_words - soft_err}/{soft_ref_words} = "
              f"{(soft_ref_words - soft_err) / soft_ref_words:.3f}")
    print(f"节数：{total}；逐词完全一致的节：{exact}/{total}（{exact / max(total, 1):.1%}）")
    print(f"词级：一致 {total_same}/{total_ref_words} = {total_same / max(total_ref_words, 1):.3f}；"
          f"错误 {total_err} 词 → 词级准确率 {1 - total_err / max(total_ref_words, 1):.3f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
