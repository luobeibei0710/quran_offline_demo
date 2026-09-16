# 古兰经离线识别 Demo

[![CI](https://github.com/luobeibei0710/quran_offline_demo/actions/workflows/ci.yml/badge.svg)](https://github.com/luobeibei0710/quran_offline_demo/actions/workflows/ci.yml)

端侧**全离线**的古兰经诵读识别验证工程：麦克风采集 → ONNX 声学模型推理 → CTC 解码 →
经文约束匹配 → 提词器展示。

验证通过后再移植回主工程（courier-mobile）。

## 技术方案（路线 B）

```
麦克风 16 kHz PCM16 → float32
   ↓
ONNX Runtime（原生：Android AAR / iOS onnxruntime-objc）—— 只做张量翻译
   ↓  log_probs [1, T, 1025]
纯 Dart 算法层（Android / iOS 共用）
   ├─ 贪心 CTC 解码（TextCtcDecoder）
   ├─ 文本召回（首词倒排 + 编辑相似度）
   ├─ CTC 约束精排（前向后向对数似然）→ surah:ayah
   ├─ 词级进度（逐词前缀 CTC 打分）→ 提词器高亮
   └─ 能量 VAD 门控（峰值/本底信噪比）→ 过滤噪声窗口
   ↓
本地经文库取标准经文 → 界面展示
```

设计要点：**算法层用纯 Dart 实现，两端共享**；平台差异只存在于「调 ORT 推理」这一层，因此不引入两套业务逻辑。

## 模型与数据

来源 [yazinsai/tilawa](https://github.com/yazinsai/tilawa) v0.2.0（SDK MIT；模型 CC-BY-4.0，基座 `nvidia/stt_ar_fastconformer_hybrid_large_pcd_v1.0`）。

| 文件 | 体积 | 说明 |
|------|------|------|
| `fastconformer_full_mixed.onnx` | 88 MB | 原版：FastConformer，int4 MatMul + int8 Conv 混合量化，含 57 个 `ConvInteger` 节点 |
| `fastconformer_full_mixed_ort122.onnx` | 130 MB | **移动端实际加载**：由上一行数学等价改造而来（见下节），供 ORT 1.22 使用 |
| `quran_ctc_tokens.json` | 12 MB | span 表，键 `surah:ayahStart:ayahEnd`，值为该跨度 token 序列 |
| `quran.json` | 3 MB | 6236 节经文（`text_uthmani` 带音标 / `text_clean` 归一化） |
| `vocab.json` | 21 KB | 1025 个 token，最大 id 为 blank |
| `sample_*.wav` | 0.1–1.7 MB | 5 条 16 kHz 单声道样本（文件名 `SSSAAA` 即标准答案），供页面内置批量验证 |

资产体积大，**均未纳入版本库**：

```bash
# 1) 下载原版模型与数据表（含 sha256 校验）
bash tools/quran_offline/download_assets.sh

# 2) 生成移动端可用的改造版模型（需 venv：onnx / onnxruntime / numpy）
tools/quran_offline/.venv/bin/python tools/quran_offline/convert_for_ort122.py
```

`sample_*.wav` 不由下载脚本提供，需自行准备（命名 `sample_SSSAAA.wav` 放入 `assets/quran_offline/`）。

### 为什么需要两版模型

`ConvInteger`（int8 量化卷积）只有较新版本的 ORT CPU EP 实现，而移动端可用的
`onnxruntime-android` 最新为 1.22.0，加载原模型会报
`NOT_IMPLEMENTED: Could not find an implementation for ConvInteger(10)`。

`tools/quran_offline/convert_for_ort122.py` 做**数学等价**改造：

```
x_q → ConvInteger(x_q, w_q, x_zp, w_zp) → Cast → Mul(·, x_scale*w_scale)
        ↓
x_q → DequantizeLinear(x_q, x_scale, x_zp) → Conv(x_dq, w_fp32)
```

代价是该 57 个卷积的权重由 int8 变 float32（模型 88 MB → 130 MB，推理走 FP32 卷积），
收益是模型能在移动端实际可用的 ORT 版本上运行。等价性由
`tools/quran_offline/verify_conversion.py` 对比两版模型输出验证。

## 运行

```bash
flutter pub get
flutter run                   # 需要真机（麦克风）
```

使用步骤：

1. 点击「加载模型」（首次会把 130 MB 模型复制到应用私有目录，后续启动复用缓存）；
2. 加载完成后自动执行一遍**内置样本验证**：逐条读取 `sample_*.wav` 走完整识别链路，
   日志区输出「期望 vs 实际 / 命中与否 / 召回数 / 耗时」，末尾汇总命中率；
3. 点击「开始识别」诵读，界面实时显示章节、标准经文、识别原文、候选与置信度，
   提词器按词高亮并自动居中滚动；静音 1.5 s 或手动停止时做一次收尾识别。

## 流式策略

`QuranStreamingSession`（工程化简版，便于移动端稳定运行）：

| 机制 | 参数（默认） | 作用 |
|------|--------------|------|
| 能量 VAD 门控 | `speechRmsThreshold=0.03`、`speechSnrRatio=2.5` | 只看最近 2 s 音频的 20 ms 帧能量：90 分位需高于中位数的 2.5 倍且高于绝对下限，才算「此刻在说话」。用比值判据而非固定阈值，以适应不同底噪环境；纯静音不再产出臆测结果 |
| 触发间隔 | `triggerSeconds=0.75` | 每累积约 0.75 s 尝试一次识别 |
| 窗口范围 | `minWindowSeconds=1.2`、`maxWindowSeconds=15` | 太短的窗口不识别；识别时只取最近 15 s |
| 静音收尾 | `silenceRmsThreshold=0.012`、`finalSilenceSeconds=1.5` | 连续静音 1.5 s 判定一段诵读结束 |
| 稳定锁定 | `stableRounds=2` | 连续多轮命中同一章节才标记为「稳定」，避免逐帧抖动 |
| 词级进度 | 见 `QuranWordProgress` | 对「前 k 个词」的 token 前缀分别做 CTC 打分，取分数处于最优容差内的最长前缀，即为已读词数 |

## 测试与 CI

```bash
flutter analyze   # 静态分析
flutter test      # 56 个用例
```

测试**不依赖** `assets/quran_offline/` 下的真实资产：用例通过 `FakeAssetBundle` 注入最小化的
内存资产、通过 `ScriptedOrtRunner` 注入合成声学证据、通过 `buildSpeechLikeSamples` 生成
可驱动 VAD 的类语音信号，因此 clone 后无需下载任何模型资产即可跑通全链路
（真机麦克风与模型推理仍需 `flutter run` 验证）。

| 测试文件 | 覆盖内容 |
|----------|----------|
| `quran_text_test.dart` | 阿拉伯语归一化（音标/Tatweel/字母变体/BOM）、相似度与片段相似度 |
| `ctc_decoder_test.dart` | 贪心 CTC 解码、相邻重复折叠、blank 处理、词边界下标 |
| `ctc_scorer_test.dart` | 前向后向对数似然、可行性下界、最长稳定前缀选择 |
| `quran_word_progress_test.dart` | 词边界切分、已读词估算、词表与 token 词组对齐 |
| `quran_assets_test.dart` | 词表/经文/span 表解析、排序索引、缓存 |
| `quran_recognizer_test.dart` | 「解码 → 召回 → 精排」端到端、VAD 门控与流式会话行为 |
| `widget_test.dart` | 页面首帧、「加载模型 → 内置样本验证 → 就绪」流程 |
| `support/quran_test_fixtures.dart` | 夹具：内存资产包、脚本化推理桥、合成证据与类语音信号 |

CI 定义见 `.github/workflows/ci.yml`，两个 Job：

| Job | 内容 |
|-----|------|
| 静态分析 + 单元测试 | `flutter analyze` → `flutter test --coverage`，上传 `lcov.info` |
| 构建 Android APK | 缓存/下载模型资产 → `flutter build apk --debug`，上传 APK 产物 |

> CI 只覆盖 `download_assets.sh` 提供的资产，**不含** `*_ort122.onnx` 与 `sample_*.wav`，
> 因此 CI 产出的 APK 仅用于验证编译链路，内置样本验证与真实识别需在本地准备好全部资产。

## 已完成验证（Python 基准）

| 项 | 结果 |
|----|------|
| 模型可用性 | 6.03 s 音频（1:1）→ 解码 `بسم الله الرحمن الرحيم`，完全正确 |
| 推理耗时 | 0.116 s（Mac CPU，6 s 音频） |
| 召回 + 精排 | 冠军 1:1，acoustic=0.074，与次优差距 1.18（区分度极大） |

首次使用需自建两个 venv（用途不同）：

```bash
# 模型改造与「原版模型」验证：需要 onnx（图改写）+ ORT ≥ 1.30（支持 ConvInteger）
python3.12 -m venv tools/quran_offline/.venv
tools/quran_offline/.venv/bin/pip install onnx onnxruntime numpy

# 改造版模型验证：对齐移动端实际可用的版本
python3.12 -m venv tools/quran_offline/.venv122
tools/quran_offline/.venv122/bin/pip install onnxruntime==1.22.0 numpy
```

> `convert_for_ort122.py` / `verify_conversion.py` 用 `.venv`（本机实测 onnxruntime 1.30.0、
> onnx 1.22.0）；`verify_corpus.py` / `check_sample.py` 用 `.venv122`（onnxruntime 1.22.0）。

> 注意：加载**原版**模型需 ORT ≥ 1.30（ORT 1.19 会报 `NOT_IMPLEMENTED`）；
> 改造后的 `*_ort122.onnx` 在 ORT 1.22 上即可加载。

### tools/quran_offline 脚本一览

| 脚本 | 用途 |
|------|------|
| `download_assets.sh` | 下载原版模型与数据表，含 sha256 校验（兼容 `shasum`/`sha256sum`） |
| `convert_for_ort122.py` | 把原版模型改造为 ORT 1.22 可加载版本 |
| `verify_conversion.py` | 对比改造前后模型的推理输出，验证等价性 |
| `verify_corpus.py` | 用 Tilawa 官方测试语料（文件名即答案）验证声学层准确率 |
| `check_sample.py` | 长音频流式分段识别，输出各时间段章节（与真机结果对照） |
| `diag_ctc.py` | 对比同一音频下不同候选 token 序列的 CTC 分数 |
| `poc_transcribe.py` | P0 验证：单次推理 + 贪心解码 |
| `poc_match.py` | P1 验证：文本召回 + CTC 约束精排 |
| `reference/` | Tilawa 侧 TypeScript 参考实现（对照语义用） |

## 目录结构

```
lib/
├── main.dart
└── quran_offline/
    ├── quran_text.dart              阿拉伯语归一化与相似度
    ├── ctc_decoder.dart             贪心 CTC 解码
    ├── ctc_scorer.dart              前向后向对数似然 + 稳定前缀
    ├── quran_word_progress.dart     词边界切分 + 已读词估算（提词器）
    ├── quran_assets.dart            经文库 / 词表 / span 表加载
    ├── quran_matcher.dart           召回 + 精排 + 置信度
    ├── ort_runner.dart              推理桥接口（平台通道）
    ├── quran_recognizer.dart        一次性识别 + 流式会话（含 VAD 门控）
    └── quran_offline_demo_page.dart Demo 界面（提词器 + 内置样本验证）
android/app/src/main/java/.../QuranOrtBridge.java   ONNX Runtime 桥
android/app/src/main/kotlin/.../MainActivity.kt     通道注册
ios/Runner/QuranOrtBridge.{h,m}                     ONNX Runtime 桥
ios/Runner/AppDelegate.swift                        通道注册
test/                                               单元测试与页面冒烟测试
assets/quran_offline/                               模型与数据资产（不入版本库）
tools/quran_offline/                                资产下载、模型改造与 Python 验证脚本
.github/workflows/ci.yml                            静态分析 + 测试 + APK 构建
```

## 已知限制

- **模型体积**：移动端加载 130 MB 改造版模型，APK 因资产显著增大。
- **样本未入库**：`sample_*.wav` 与模型一样不进版本库，clone 后需自行准备，
  否则内置样本验证会逐条报「识别失败」。
- **首次加载**：模型复制到私有目录约需数秒；后续启动复用缓存（缓存文件名带 `_ort122`
  后缀，模型换代时会自动失效重建）。
- **流式仍为工程化简版**：滑窗重复识别 + 稳定锁定 + 词级前缀进度；尚未移植
  Tilawa `tracker.ts` 的词级对齐与推进策略。
- **iOS**：桥与 Podfile 已就绪（`pod 'onnxruntime-objc'`），尚未在 Xcode 侧构建验证。
