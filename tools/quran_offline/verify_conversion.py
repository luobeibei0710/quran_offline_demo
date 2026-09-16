#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""模型改造等价性验证：对比原模型与新模型的推理输出。

用法（在两个不同的 ORT 环境下各跑一次）::

    # 环境 A（ORT 1.30，原模型）
    .venv/bin/python verify_conversion.py --model ../../assets/quran_offline/fastconformer_full_mixed.onnx \
        --audio samples/001001.mp3 --dump /tmp/lp_orig.npy

    # 环境 B（ORT 1.22，改造后模型）
    .venv122/bin/python verify_conversion.py --model ../../assets/quran_offline/fastconformer_full_mixed_ort122.onnx \
        --audio samples/001001.mp3 --dump /tmp/lp_new.npy

    # 对比
    .venv/bin/python verify_conversion.py --compare /tmp/lp_orig.npy /tmp/lp_new.npy
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.abspath(os.path.join(HERE, "..", "..", "assets", "quran_offline"))
VOCAB_PATH = os.path.join(ASSETS, "vocab.json")

SAMPLE_RATE = 16000
WORD_PREFIX = "\u2581"
DIACRITICS_RE = re.compile("[\u0610-\u061a\u064b-\u065f\u0670\u06d6-\u06de\u06df-\u06ed\u0640\ufeff]")
NORM_MAP = {"\u0623": "\u0627", "\u0625": "\u0627", "\u0622": "\u0627",
            "\u0671": "\u0627", "\u0629": "\u0647", "\u0649": "\u064a"}


def normalize_arabic(text: str) -> str:
    """与 Tilawa normalizer.ts 等价的归一化。"""
    text = DIACRITICS_RE.sub("", text)
    text = "".join(NORM_MAP.get(ch, ch) for ch in text)
    return " ".join(text.split())


def load_audio(path: str) -> np.ndarray:
    """ffmpeg 解码为 16k 单声道 float32。"""
    raw = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", path, "-f", "f32le", "-ac", "1", "-ar", str(SAMPLE_RATE), "-"],
        capture_output=True,
        check=True,
    ).stdout
    return np.frombuffer(raw, dtype=np.float32)


def run_model(model_path: str, audio_path: str, dump: str) -> None:
    """执行一次推理并输出解码文本。"""
    import onnxruntime as ort

    vocab = {int(k): v for k, v in json.load(open(VOCAB_PATH, encoding="utf-8")).items()}
    blank_id = max(vocab)

    audio = load_audio(audio_path)
    print(f"ORT {ort.__version__} | 模型 {os.path.basename(model_path)} | 音频 {len(audio) / SAMPLE_RATE:.2f}s")

    session = ort.InferenceSession(model_path, providers=["CPUExecutionProvider"])
    logprobs = session.run(
        None,
        {
            "audio_signal": audio[None, :].astype(np.float32),
            "length": np.array([audio.shape[0]], dtype=np.int64),
        },
    )[0][0]

    frame_ids = np.argmax(logprobs, axis=1).tolist()
    token_ids, previous = [], -1
    for token in frame_ids:
        if token != previous and token != blank_id:
            token_ids.append(token)
        previous = token
    text = normalize_arabic(
        "".join(vocab.get(i, "") for i in token_ids if vocab.get(i) not in ("<unk>", "<blank>")).replace(
            WORD_PREFIX, " "
        )
    )
    print(f"  frames={logprobs.shape[0]} tokens={len(token_ids)}")
    print(f"  解码: {text}")

    if dump:
        np.save(dump, logprobs)
        print(f"  已保存 logprobs: {dump}")


def compare(a_path: str, b_path: str) -> int:
    """对比两份 logprobs。"""
    a = np.load(a_path)
    b = np.load(b_path)
    print(f"形状: {a.shape} vs {b.shape}")
    if a.shape != b.shape:
        print("[FAIL] 形状不一致")
        return 1
    diff = np.abs(a - b)
    print(f"最大绝对差: {diff.max():.6f}")
    print(f"平均绝对差: {diff.mean():.6f}")
    # 逐帧 argmax 一致率（对最终解码最关键）
    same = np.mean(np.argmax(a, axis=1) == np.argmax(b, axis=1))
    print(f"逐帧 argmax 一致率: {same * 100:.2f}%")
    if same > 0.99:
        print("[OK] 改造模型与原模型解码路径一致")
        return 0
    print("[WARN] 存在差异，需人工确认")
    return 2


def main() -> int:
    parser = argparse.ArgumentParser(description="模型改造等价性验证")
    parser.add_argument("--model", default="", help="模型路径")
    parser.add_argument("--audio", default="samples/001001.mp3", help="测试音频")
    parser.add_argument("--dump", default="", help="保存 logprobs 的 .npy 路径")
    parser.add_argument("--compare", nargs=2, metavar=("A", "B"), help="对比两份 logprobs")
    args = parser.parse_args()

    if args.compare:
        return compare(args.compare[0], args.compare[1])

    if not args.model:
        parser.error("需要 --model 或 --compare")
    run_model(args.model, args.audio, args.dump)
    return 0


if __name__ == "__main__":
    sys.exit(main())
