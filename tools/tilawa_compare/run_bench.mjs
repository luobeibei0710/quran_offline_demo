#!/usr/bin/env node
/**
 * 用 Tilawa 官方 npm 包（@tilawa/core）跑同一批语料，输出可对比的识别结果 JSON。
 *
 * 设计要点（保证对比公平）：
 * - **同一批音频**：读 `assets/quran_offline/corpus/`（我们的内置语料，16 kHz 单声道 WAV）；
 * - **同一份文本资产**：vocab.json / quran_ctc_tokens.json / quran.json 都来自 Tilawa v0.2.0
 *   官方发布包，两个工程用的是同一套；
 * - **等价模型**：默认用我们改造过的 `fastconformer_full_mixed_ort122.onnx`
 *   （把 57 个 ConvInteger 换成 DequantizeLinear + Conv，逐帧 argmax 与原模型一致率 100%），
 *   这样 Node 侧 ORT 1.22 也能加载；要跑原模型可设 `TILAWA_MODEL=<原始 onnx>`（需 ORT ≥1.30）；
 * - **默认配置**：完全用 Tilawa 自己的默认流式配置（BALANCED_STREAMING_CONFIG），
 *   不做任何调参，代表它开箱状态的能力；配置会一并写进结果 JSON。
 *
 * 用法：
 *   node run_bench.mjs                          # 全部内置语料
 *   OUT=/tmp/x.json CLIPS=corpus_036_001_005.wav node run_bench.mjs
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import ort from 'onnxruntime-node';
import { createTilawaSession } from '@tilawa/core';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '..', '..');
const ASSETS = path.join(REPO, 'assets', 'quran_offline');
const CORPUS = path.join(ASSETS, 'corpus');
const MODEL =
  process.env.TILAWA_MODEL ?? path.join(ASSETS, 'fastconformer_full_mixed_ort122.onnx');
const OUT = process.env.OUT ?? '/tmp/tilawa_bench.json';

/**
 * 读取 16 kHz / 单声道 / 16-bit PCM 的 WAV。
 *
 * @param {string} file 文件路径
 * @returns {Float32Array} 采样
 */
function readWav(file) {
  const bytes = fs.readFileSync(file);
  if (bytes.toString('ascii', 0, 4) !== 'RIFF' || bytes.toString('ascii', 8, 12) !== 'WAVE') {
    throw new Error(`不是 WAV：${file}`);
  }
  let offset = 12;
  let fmt = null;
  let pcm = null;
  while (offset + 8 <= bytes.length) {
    const id = bytes.toString('ascii', offset, offset + 4);
    const size = bytes.readUInt32LE(offset + 4);
    const body = offset + 8;
    if (id === 'fmt ') {
      fmt = {
        format: bytes.readUInt16LE(body),
        channels: bytes.readUInt16LE(body + 2),
        sampleRate: bytes.readUInt32LE(body + 4),
        bits: bytes.readUInt16LE(body + 14),
      };
    } else if (id === 'data') {
      pcm = bytes.subarray(body, Math.min(body + size, bytes.length));
    }
    offset = body + size + (size % 2);
  }
  if (!fmt || !pcm) throw new Error(`WAV 缺少 fmt/data：${file}`);
  if (fmt.format !== 1 || fmt.bits !== 16 || fmt.channels !== 1 || fmt.sampleRate !== 16000) {
    throw new Error(
      `格式不支持（需要 16 kHz/单声道/16bit）：${JSON.stringify(fmt)} @ ${file}`,
    );
  }
  const samples = new Float32Array(pcm.length / 2);
  for (let i = 0; i < samples.length; i++) {
    samples[i] = pcm.readInt16LE(i * 2) / 32768;
  }
  return samples;
}

/** 构建 Tilawa 需要的推理桥（ONNX Runtime Node 版）。 */
async function makeRunner() {
  const ortSession = await ort.InferenceSession.create(MODEL, { executionProviders: ['cpu'] });
  console.log(`模型：${path.basename(MODEL)}`);
  console.log(`输入：${ortSession.inputNames.join(', ')}  输出：${ortSession.outputNames.join(', ')}`);
  return {
    /**
     * 单次推理：喂 mono 16 kHz float32，取 [1, T, V] 的 log-probs。
     *
     * @param {Float32Array} audio 采样
     * @returns {Promise<{logprobs: Float32Array, timeSteps: number, vocabSize: number}>}
     */
    async run(audio) {
      const feeds = {
        audio_signal: new ort.Tensor('float32', audio, [1, audio.length]),
        length: new ort.Tensor('int64', BigInt64Array.from([BigInt(audio.length)]), [1]),
      };
      const outputs = await ortSession.run(feeds);
      const first = outputs[ortSession.outputNames[0]];
      const [, timeSteps, vocabSize] = first.dims;
      return { logprobs: first.data, timeSteps, vocabSize };
    },
  };
}

async function main() {
  const runner = await makeRunner();
  const assets = {
    vocab: JSON.parse(fs.readFileSync(path.join(ASSETS, 'vocab.json'), 'utf8')),
    quranCtcTokens: JSON.parse(fs.readFileSync(path.join(ASSETS, 'quran_ctc_tokens.json'), 'utf8')),
    quran: JSON.parse(fs.readFileSync(path.join(ASSETS, 'quran.json'), 'utf8')),
    blankId: 1024,
  };
  const manifest = JSON.parse(fs.readFileSync(path.join(CORPUS, 'manifest.json'), 'utf8'));
  const only = process.env.CLIPS ? new Set(process.env.CLIPS.split(',')) : null;

  const results = [];
  for (const entry of manifest) {
    if (only && !only.has(entry.file)) continue;
    const file = path.join(CORPUS, entry.file);
    const samples = readWav(file);
    const expected = [];
    for (let ayah = entry.ayahStart; ayah <= entry.ayahEnd; ayah++) {
      expected.push(`${entry.surah}:${ayah}`);
    }

    const messages = [];
    const diagnostics = [];
    const session = createTilawaSession(runner, assets, {
      onOutput: (msg) => messages.push(msg),
      onDiagnostic: (event, data) => {
        if (event === 'transcribe') diagnostics.push({ text: data.text, champion: data.champion });
      },
    });
    const config = session.getConfig();
    const chunkMs = config.audioChunkMs;
    const chunkSamples = Math.round((16000 * chunkMs) / 1000);

    console.log(
      `\n== ${entry.file}（${(samples.length / 16000).toFixed(1)}s，${expected.length} 节，` +
        `audioChunkMs=${chunkMs}）==`,
    );
    const started = Date.now();
    for (let offset = 0; offset < samples.length; offset += chunkSamples) {
      const chunk = samples.subarray(offset, Math.min(offset + chunkSamples, samples.length));
      await session.feed(chunk);
      if ((offset / chunkSamples) % 200 === 0) {
        const fed = (offset / samples.length) * 100;
        console.log(`  …已喂 ${fed.toFixed(0)}%（${((Date.now() - started) / 1000).toFixed(1)}s）`);
      }
    }
    const elapsedSec = (Date.now() - started) / 1000;

    const oneShot = await session.transcribe(samples);
    const byType = {};
    for (const msg of messages) byType[msg.type] = (byType[msg.type] ?? 0) + 1;

    results.push({
      clip: entry.file,
      surah: entry.surah,
      ayahStart: entry.ayahStart,
      ayahEnd: entry.ayahEnd,
      expectedRefs: expected,
      durationSec: samples.length / 16000,
      elapsedSec,
      config,
      messageCounts: byType,
      verseMatches: messages
        .filter((m) => m.type === 'verse_match')
        .map((m) => ({ surah: m.surah, ayah: m.ayah, confidence: m.confidence })),
      finalSequences: messages
        .filter((m) => m.type === 'final_sequence')
        .map((m) => ({ verses: m.verses, confidence: m.confidence })),
      rawTranscripts: messages
        .filter((m) => m.type === 'raw_transcript')
        .map((m) => ({ text: m.text, confidence: m.confidence })),
      lastRawTranscript: [...messages].reverse().find((m) => m.type === 'raw_transcript')?.text ?? '',
      wordProgressCount: byType.word_progress ?? 0,
      oneShot: {
        surah: oneShot.surah,
        ayah: oneShot.ayah,
        ayahEnd: oneShot.ayah_end,
        score: oneShot.score,
      },
      diagnosticsTail: diagnostics.slice(-5),
    });
    console.log(
      `  完成：耗时 ${elapsedSec.toFixed(1)}s，消息 ` +
        `${Object.entries(byType).map(([k, v]) => `${k}=${v}`).join(' ')}`,
    );
  }

  fs.writeFileSync(OUT, JSON.stringify({ model: path.basename(MODEL), results }, null, 2));
  console.log(`\n结果已写入 ${OUT}`);
  // onnxruntime-node 在进程退出时偶发析构异常，结果写完后直接退出
  process.exit(0);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
