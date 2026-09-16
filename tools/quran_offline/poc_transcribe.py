#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""P0 验证脚本：直接跑 Tilawa 声学模型，确认 16k 音频可解码出文本。

本脚本只做「声学模型 → 贪心 CTC 解码 → 阿拉伯语归一化」这一段，
用于验证模型输入输出规格与词表一致；Quran 约束匹配由 Dart 侧实现。

用法::

    .venv/bin/python poc_transcribe.py samples/001001.mp3
    .venv/bin/python poc_transcribe.py samples/001001.mp3 --start 0 --dur 6
    .venv/bin/python poc_transcribe.py samples/001001.mp3 --dump-logprobs /tmp/lp.npy
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys

import numpy as np
import onnxruntime as ort

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.abspath(os.path.join(HERE, "..", "..", "assets", "quran_offline"))
MODEL_PATH = os.path.join(ASSETS, "fastconformer_full_mixed.onnx")
VOCAB_PATH = os.path.join(ASSETS, "vocab.json")

SAMPLE_RATE = 16000
WORD_PREFIX = "\u2581"

# 与 Tilawa normalizer.ts 保持一致：去掉变音符号/ Tatweel，统一字母变体
DIACRITICS_RE = "[\u0610-\u061a\u064b-\u065f\u0670\u06d6-\u06de\u06df-\u06ed\u0640]"
NORM_MAP = {
    "\u0623": "\u0627",  # أ -> ا
    "\u0625": "\u0627",  # إ -> ا
    "\u0622": "\u0627",  # آ -> ا
    "\u0671": "\u0627",  # ٱ -> ا
    "\u0629": "\u0647",  # ة -> ه
    "\u0649": "\u064a",  # ى -> ي
}


def normalize_arabic(text: str) -> str:
    """阿拉伯语归一化，与 Tilawa 的 normalizer.ts 等价。"""
    import re

    text = text.replace("\ufeff", "")
    text = re.sub(DIACRITICS_RE, "", text)
    text = "".join(NORM_MAP.get(ch, ch) for ch in text)
    return " ".join(text.split())


def load_audio(path: str, start: float | None, dur: float | None) -> np.ndarray:
    """用 ffmpeg 解码任意音频为 16kHz 单声道 float32。"""
    cmd = ["ffmpeg", "-v", "error"]
    if start:
        cmd += ["-ss", str(start)]
    cmd += ["-i", path]
    if dur:
        cmd += ["-t", str(dur)]
    cmd += ["-f", "f32le", "-ac", "1", "-ar", str(SAMPLE_RATE), "-"]
    raw = subprocess.run(cmd, capture_output=True, check=True).stdout
    return np.frombuffer(raw, dtype=np.float32)


def greedy_ctc(logprobs: np.ndarray, vocab: dict[int, str], blank_id: int) -> tuple[str, list[int]]:
    """贪心 CTC 解码：逐帧 argmax → 去重 → 去 blank → 拼 token 文本。"""
    frame_ids = np.argmax(logprobs, axis=1).tolist()
    token_ids: list[int] = []
    previous = -1
    for token in frame_ids:
        if token != previous and token != blank_id:
            token_ids.append(token)
        previous = token
    text = "".join(vocab.get(i, "") for i in token_ids if vocab.get(i) not in ("<unk>", "<blank>"))
    text = text.replace(WORD_PREFIX, " ")
    return normalize_arabic(text), token_ids


def main() -> int:
    parser = argparse.ArgumentParser(description="Tilawa 声学模型 P0 验证")
    parser.add_argument("audio", help="输入音频（任意格式，ffmpeg 解码）")
    parser.add_argument("--start", type=float, default=None, help="起始秒")
    parser.add_argument("--dur", type=float, default=None, help="截取时长（秒）")
    parser.add_argument("--dump-logprobs", default="", help="把 logprobs 存为 .npy 便于后续复用")
    args = parser.parse_args()

    with open(VOCAB_PATH, "r", encoding="utf-8") as handle:
        vocab_json = json.load(handle)
    vocab = {int(k): v for k, v in vocab_json.items()}
    max_id = max(vocab)
    blank_id = max_id  # 与 text-ctc-decode.ts 的默认 blankId 一致

    session = ort.InferenceSession(MODEL_PATH, providers=["CPUExecutionProvider"])
    print("== 模型输入 ==")
    for item in session.get_inputs():
        print(f"  {item.name}: shape={item.shape} type={item.type}")
    print("== 模型输出 ==")
    for item in session.get_outputs():
        print(f"  {item.name}: shape={item.shape} type={item.type}")

    audio = load_audio(args.audio, args.start, args.dur)
    print(f"\n== 音频 ==\n  samples={audio.shape[0]} duration={audio.shape[0] / SAMPLE_RATE:.2f}s")

    outputs = session.run(
        None,
        {
            "audio_signal": audio[None, :].astype(np.float32),
            "length": np.array([audio.shape[0]], dtype=np.int64),
        },
    )
    logprobs = outputs[0]
    print(f"\n== 推理输出 ==\n  shape={logprobs.shape} dtype={logprobs.dtype}")

    if logprobs.ndim == 3:
        _, time_steps, vocab_size = logprobs.shape
        flat = logprobs[0]
    else:
        flat = logprobs
        time_steps, vocab_size = flat.shape

    print(f"  timeSteps={time_steps} vocabSize={vocab_size} (vocab.json 条目={len(vocab)})")

    text, token_ids = greedy_ctc(flat, vocab, blank_id)
    print(f"\n== 贪心 CTC 解码 ==\n  tokens={len(token_ids)}\n  transcript: {text}")

    if args.dump_logprobs:
        np.save(args.dump_logprobs, flat)
        print(f"\n[INFO] logprobs 已保存: {args.dump_logprobs}")

    # 与经文库做一次朴素的规范化子串匹配，粗略验证归属
    quran_path = os.path.join(ASSETS, "quran.json")
    if os.path.exists(quran_path) and text:
        with open(quran_path, "r", encoding="utf-8") as handle:
            quran = json.load(handle)
        print(f"\n== 经文库 ==\n  条目数={len(quran)} 首条样例键={list(quran[0].keys())[:8]}")
        hits = []
        probe = text.split()
        for verse in quran:
            verse_text = verse.get("text_clean") or verse.get("text_uthmani") or ""
            if not verse_text:
                continue
            normalized = normalize_arabic(verse_text)
            words = normalized.split()
            if len(words) >= 3 and " ".join(words[:3]) in text:
                hits.append((verse.get("surah"), verse.get("ayah"), normalized[:60]))
        print(f"  前三词命中的经文数={len(hits)}")
        for hit in hits[:5]:
            print(f"    surah={hit[0]} ayah={hit[1]} -> {hit[2]}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
