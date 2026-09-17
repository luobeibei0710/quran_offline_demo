# 古兰经离线识别 Demo

[![CI](https://github.com/luobeibei0710/quran_offline_demo/actions/workflows/ci.yml/badge.svg)](https://github.com/luobeibei0710/quran_offline_demo/actions/workflows/ci.yml)

端侧**全离线**的《古兰经》诵读识别 Demo（Flutter）：麦克风实时采集 → ONNX 声学模型推理 →
CTC 解码 → 经文约束匹配，实时给出「正在诵读第几章第几节」并渲染对应标准经文；另附
「原文 / 转写」逐词比对页，用于核对识别质量。**音频不出设备**。

本仓库是验证工程：先确认端侧识别链路与精度是否达标，再考虑移植到正式项目。
Android 与 iOS 共用同一套 Dart 算法层，平台差异只在「调 ONNX Runtime 推理」这一层。

## 功能特性

- **全离线**：声学模型、词表、经文库都在应用内，推理全部在本机完成；
- **实时跟读**：滑窗流式识别 + 稳定锁定，界面实时显示章节、标准经文、置信度与词进度；
- **6236 节全文召回 + CTC 约束精排**：先按识别文本召回候选，再用 CTC 前向后向对数似然精排，
  而不是把问题简化成分类；
- **原文 / 转写比对**：把朗读原文与识别转写逐词对齐，给出覆盖率 / 准确率 / F1 与逐词着色；
- **能量 VAD 门控**：用「峰值 / 本底」信噪比判据过滤噪声窗口，纯静音不再产出臆测结果；
- **两端共享算法层**：召回、精排、解码、比对全部是纯 Dart，Android / iOS 只差原生推理桥。

## 技术方案

```
麦克风 16 kHz PCM16 → float32
   ↓
ONNX Runtime（原生：Android AAR / iOS onnxruntime-objc）—— 只做张量翻译
   ↓  log_probs [1, T, 1025]
纯 Dart 算法层（Android / iOS 共用）
   ├─ 贪心 CTC 解码（TextCtcDecoder）
   ├─ 文本召回（分词倒排 + 覆盖率/编辑相似度）
   ├─ CTC 约束精排（前向后向对数似然）→ surah:ayah
   ├─ 词级进度（逐词前缀 CTC 打分）→ 提词器高亮
   ├─ 能量 VAD 门控（峰值/本底信噪比）→ 过滤噪声窗口
   └─ 转写拼接 + 词级对齐（动态规划）→ 原文 / 转写比对
   ↓
本地经文库取标准经文 → 界面展示
```

## 界面与交互

主界面为「指标置顶 + 主区经文」的 Streaming 布局，自上而下四段：

| 区域 | 内容 |
|------|------|
| 状态条 | 当前阶段文案、输入电平条、稳定命中次数 |
| 章节栏 | 「已锁定」徽标、章名与 `surah:ayah`，其下一行 11 px 小字汇总指标（置信度、声学分、词进度、窗口时长） |
| 主区 | 默认显示整句奥斯曼体经文（26 px、RTL、长节可纵向滚动） |
| 日志条 | 固定在底部 76 px，显示最近 5 条事件，同时输出到 logcat |

主区样式与自动化行为由编译期开关控制：

| 开关 | 默认 | 说明 |
|------|------|------|
| `_showTeleprompter` | `false` | `false` = 整句经文；`true` = 逐词提词器（已读 / 当前 / 未读三态高亮 + 自动居中滚动） |
| `_builtinSamples` | 5 条 | 加载完成后自动逐条跑内置样本并汇总命中率，无需麦克风 |
| `_autoStartListening` | `false` | 加载完成后自动开麦：`--dart-define=quran_auto_start=true` |
| `_autoStopSeconds` | `0` | 自动开始后多少秒自动停止并输出 `比对预览`（0 = 不停）：`--dart-define=quran_auto_stop_seconds=160` |

> 两个联调开关走 `--dart-define` 而非改源码，避免把联调状态误提交。
> Android 的 `input tap` 被系统禁用、iOS 模拟器无法脚本点击，无人值守验证只能靠它们。

## 原文 / 转写比对

把「朗读原文」（参考答案）与端侧「转写结果」逐词对照，核对模型听到了什么、错在哪里。
结束识别后日志会输出一行 `比对预览`（词数、F1、覆盖率、准确率、各状态词数、结论），
点 AppBar 的比对图标进入「左原文 / 右转写」逐词对照页。

转写稿来自本次识别的全部窗口结果，按「最长词级重叠」去重后拼接（`transcript_stitcher.dart`），
避免同一段话被多轮窗口重复计入。

### 判定阈值（`word_alignment.dart`）

逐词对齐用 Needleman–Wunsch 动态规划（缺词/多词各扣 `gapPenalty=0.5`），词相似度取归一化后的
字符级 Levenshtein 比例。一旦漏词、多词，按下标硬比会让后面所有词全部判错，动态规划可以避免。

| 状态 | 条件 | 颜色 |
|------|------|------|
| 一致 | 相似度 ≥ `matchThreshold=0.80` | 绿 |
| 近似 | `nearThreshold=0.50` ≤ 相似度 < 0.80 | 黄 |
| 错配 | 相似度 < 0.50 | 红 |
| 缺失 | 原文有、转写无 | 灰 |
| 多余 | 转写有、原文无 | 橙 |

整体指标：`覆盖率 = (一致 + 0.5×近似) / 原文词数`、`准确率 = (一致 + 0.5×近似) / 转写词数`、
`F1` 取两者调和平均；结论分档 `优秀 ≥0.90`、`良好 ≥0.75`、`一般 ≥0.55`、`较差 <0.55`。

两点口径说明：

- **近似词按半分计入**：阿拉伯语形近词（如 `الرحمن` / `الرحيم`）出错时通常读音相近而非完全跑偏，
  直接算错会低估可懂度，算对又会高估，故取半分；
- **覆盖率与准确率同时看**：只念了一小段时覆盖率低但准确率可能很高，乱识别时准确率低，
  F1 把两者拉平，避免单看一个指标得出相反结论。

### 原文来源

按优先级两条（见 `reference_text.dart`），页面顶部会显示当前用的是哪一份：

1. **设备文件覆盖**（换语料不必重新构建，推送后点右上角刷新即可生效）：
   见 [docs/android-device.md](docs/android-device.md)；
2. **内置资产** `assets/quran_reference/reference_text.txt`（随包发布，设备文件缺失时的回退）。

## 快速开始

### 环境要求

| 平台 | 要求 |
|------|------|
| 通用 | Flutter 3.41+（CI 固定 3.41.8）、Dart SDK ^3.11.5 |
| Android | Android SDK 36、JDK 17、AGP 默认 NDK |
| iOS | Xcode 26+、CocoaPods 1.16+、部署目标 iOS 15.1（见 [docs/ios.md](docs/ios.md)） |

### 1. 获取模型与数据

模型与大数据表不入版本库，需自行获取：

```bash
# 下载原版模型与数据表（含 sha256 校验）
bash tools/quran_offline/download_assets.sh

# 生成移动端可用的改造版模型（需 venv：onnx / onnxruntime / numpy）
tools/quran_offline/.venv/bin/python tools/quran_offline/convert_for_ort122.py
```

`sample_*.wav` 不由下载脚本提供，需自行准备（命名 `sample_SSSAAA.wav` 放入 `assets/quran_offline/`）。

### 2. 运行

```bash
flutter pub get
flutter run                   # 需要真机或模拟器（麦克风）
```

使用步骤：

1. 进入页面即自动加载经文库（6236 节 + 词表 + span 表）与 130 MB 声学模型
   （首次会把模型复制到应用私有目录，后续启动复用缓存）；
2. 加载完成后自动跑一遍**内置样本验证**：逐条读取 `sample_*.wav` 走完整链路，
   日志输出「期望 vs 实际 / 命中与否 / 召回数 / 耗时」，末尾汇总命中率；
3. 点「开始识别」诵读，主区实时渲染识别到的标准经文，章节栏显示章节、置信度、声学分与词进度；
   静音 1.5 s 或手动停止时做一次收尾识别，右上角「重置」清空本轮状态；
4. 结束后看日志的 `比对预览`，点右上角比对图标进入逐词对照页。

## 模型与数据

来源 [yazinsai/tilawa](https://github.com/yazinsai/tilawa) v0.2.0（SDK MIT；模型 CC-BY-4.0，
基座 `nvidia/stt_ar_fastconformer_hybrid_large_pcd_v1.0`）。

| 文件 | 体积 | 说明 |
|------|------|------|
| `fastconformer_full_mixed.onnx` | 88 MB | 原版：FastConformer，int4 MatMul + int8 Conv 混合量化，含 57 个 `ConvInteger` 节点 |
| `fastconformer_full_mixed_ort122.onnx` | 130 MB | **移动端实际加载**：由上一行数学等价改造而来，供 ORT 1.22 使用 |
| `quran_ctc_tokens.json` | 12 MB | span 表，键 `surah:ayahStart:ayahEnd`，值为该跨度 token 序列 |
| `quran.json` | 3 MB | 6236 节经文（`text_uthmani` 带音标 / `text_clean` 归一化） |
| `vocab.json` | 21 KB | 1025 个 token，最大 id 为 blank |
| `sample_*.wav` | 0.1–1.7 MB | 官方测试样本（文件名 `SSSAAA` 即标准答案），供内置批量验证 |

### 为什么需要两版模型

`ConvInteger`（int8 量化卷积）只有较新版本的 ORT CPU EP 实现，而移动端可用的
`onnxruntime-android` / `onnxruntime-objc` 当时最新为 1.22.0，加载原模型会报
`NOT_IMPLEMENTED: Could not find an implementation for ConvInteger(10)`。

`tools/quran_offline/convert_for_ort122.py` 做**数学等价**改造：

```
x_q → ConvInteger(x_q, w_q, x_zp, w_zp) → Cast → Mul(·, x_scale*w_scale)
        ↓
x_q → DequantizeLinear(x_q, x_scale, x_zp) → Conv(x_dq, w_fp32)
```

代价是该 57 个卷积的权重由 int8 变 float32（模型 88 MB → 130 MB，推理走 FP32 卷积），
收益是模型能在移动端可用的 ORT 版本上运行。等价性由 `verify_conversion.py` 对比两版模型输出验证
（逐帧 argmax 一致率 100%）。

> 经文库的 token 表有个坑：`s:1:N`（N≥2）不含太斯米前缀，而单节序列可能含，
> 真实音频则不一定有太斯米；`QuranMatcher._scoreTokens()` 会做「剥离太斯米前缀再打分，取更优」。

## 流式策略

`QuranStreamingSession`（工程化简版，便于移动端稳定运行）：

| 机制 | 参数（默认） | 作用 |
|------|--------------|------|
| 能量 VAD 门控 | `speechRmsThreshold=0.03`、`speechSnrRatio=2.5` | 只看最近 2 s 音频的 20 ms 帧能量：90 分位需高于中位数的 2.5 倍且高于绝对下限，才算「此刻在说话」。用比值判据而非固定阈值以适应不同底噪；纯静音不再产出臆测结果 |
| 触发间隔 | `triggerSeconds=0.75` | 每累积约 0.75 s 尝试一次识别 |
| 窗口范围 | `minWindowSeconds=1.2`、`maxWindowSeconds=15` | 太短的窗口不识别；识别时只取最近 15 s |
| 静音收尾 | `silenceRmsThreshold=0.012`、`finalSilenceSeconds=1.5` | 连续静音 1.5 s 判定一段诵读结束 |
| 稳定锁定 | `stableRounds=2` | 连续多轮命中同一章节才标记为「稳定」，避免逐帧抖动 |
| 词级进度 | 见 `QuranWordProgress` | 对「前 k 个词」的 token 前缀分别做 CTC 打分，取分数处于最优容差内的最长前缀，即为已读词数 |
| 召回 + 精排 | `topK=64`、`maxSpan=4`、`spanPenalty=0.35` | 召回候选数、最大连读跨度、跨度惩罚系数 |

## 测试与 CI

```bash
flutter analyze   # 静态分析
flutter test      # 82 个用例
```

测试**不依赖** `assets/quran_offline/` 下的真实资产：用例通过 `FakeAssetBundle` 注入最小化的
内存资产、通过 `ScriptedOrtRunner` 注入合成声学证据、通过 `buildSpeechLikeSamples` 生成可驱动
VAD 的类语音信号，因此 clone 后无需下载任何模型资产即可跑通全链路（真机麦克风与模型推理仍需
`flutter run` 验证）。

| 测试文件 | 覆盖内容 |
|----------|----------|
| `quran_text_test.dart` | 阿拉伯语归一化（音标/Tatweel/字母变体/BOM）、相似度与片段相似度 |
| `ctc_decoder_test.dart` | 贪心 CTC 解码、相邻重复折叠、blank 处理、词边界下标 |
| `ctc_scorer_test.dart` | 前向后向对数似然、可行性下界、最长稳定前缀选择 |
| `quran_word_progress_test.dart` | 词边界切分、已读词估算、词表与 token 词组对齐 |
| `quran_assets_test.dart` | 词表/经文/span 表解析、排序索引、缓存 |
| `quran_recognizer_test.dart` | 「解码 → 召回 → 精排」端到端、VAD 门控与流式会话行为 |
| `word_alignment_test.dart` | 词级对齐（漏词不连带判错）、一致/近似/错配/缺失/多余判定、覆盖率与 F1、结论分档 |
| `transcript_stitcher_test.dart` | 逐窗结果的最长重叠去重、整段已包含不重复追加、归一化后比较 |
| `reference_text_test.dart` | 原文来源优先级（设备文件 → 内置资产）、空白内容回退、双来源缺失报错 |
| `quran_compare_page_test.dart` | 比对页左右两栏渲染、缺失侧占位、指标与结论、原文加载失败提示 |
| `widget_test.dart` | 页面首帧、「加载模型 → 内置样本验证 → 就绪」流程 |
| `support/quran_test_fixtures.dart` | 夹具：内存资产包、脚本化推理桥、合成证据与类语音信号 |

CI 定义见 `.github/workflows/ci.yml`，两个 Job：

| Job | 内容 |
|-----|------|
| 静态分析 + 单元测试 | `flutter analyze` → `flutter test --coverage`，上传 `lcov.info` |
| 构建 Android APK | 缓存/下载模型资产 → `flutter build apk --debug`，上传 APK 产物 |

> CI 只覆盖 `download_assets.sh` 提供的资产，**不含** `*_ort122.onnx` 与 `sample_*.wav`，
> 因此 CI 产出的 APK 仅用于验证编译链路，内置样本验证与真实识别需在本地准备好全部资产。

## 项目结构

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
    ├── transcript_stitcher.dart     转写稿增量拼接（按最长词级重叠去重）
    ├── word_alignment.dart          词级对齐、判定阈值与比对指标
    ├── reference_text.dart          比对原文加载（设备文件 / 内置资产）
    ├── quran_compare_page.dart      原文 / 转写逐词对照页
    └── quran_offline_demo_page.dart Demo 界面（Streaming 经文主区 / 可切换提词器 / 内置样本验证 / 比对入口）
android/app/src/main/java/.../QuranOrtBridge.java   ONNX Runtime 桥
android/app/src/main/kotlin/.../MainActivity.kt     通道注册
ios/Runner/QuranOrtBridge.{h,m}                     ONNX Runtime 桥
ios/Runner/AppDelegate.swift                        通道注册
test/                                               单元测试与页面冒烟测试
assets/quran_offline/                               模型与数据资产（不入版本库）
assets/quran_reference/                             比对用原文（约 3 KB，入版本库）
tools/quran_offline/                                资产下载、模型改造与 Python 验证脚本
docs/                                               验证记录、平台联调说明
.github/workflows/ci.yml                            静态分析 + 测试 + APK 构建
```

## 已知限制

- **`112:1` 跨度偏长**：内置样本 `sample_112001.wav`（`قل هو الله احد`）在 Android 真机与
  iOS 模拟器上都输出 `112:1-3`，而 x86 Mac 上输出 `112:1`（章号与起始节均正确，仅结束节多算）。
  根因是**平台间推理数值存在系统性差异**：ARM 侧 `logprobs` 为 min≈-50.8 / avg≈-31.9，
  x86 Mac 为 min=-43.571 / avg=-25.123；浮点累加顺序差异在深层网络中被放大，argmax 与识别文本
  不受影响，但 CTC 连乘对数概率对数值敏感，在「短音频 + 静音帧占多数」的边界场景足以翻转跨度判定。
  可选修法（未实施）：给排序分加「候选 token 数与识别 token 数偏离」的先验惩罚 / 归一化从
  `-logP/len(seq)` 改为按帧数 / 容差内取最短跨度（需权衡长诵读场景）。
- **比对结果上限由抓音质量决定**：转写稿只包含 VAD 判定为「有语音」的窗口，收音电平接近底噪时
  多数窗口会被跳过，指标随之偏低。校准方法见 [docs/android-device.md](docs/android-device.md)。
- **模型体积**：移动端加载 130 MB 改造版模型（124.6 MiB），debug APK 约 300 MB；
  正式交付需按需下载模型或只打单 ABI。
- **提词器精度未定量评估**：`QuranWordProgress.defaultTolerance`（0.35）尚未按真人朗读调参；
  默认主区走整句样式，提词器逻辑保留且有单元测试覆盖。
- **iOS 未做真机验证**：模拟器已跑通模型加载、推理与内置样本自测，真机签名、麦克风实采与性能
  尚未验证，见 [docs/ios.md](docs/ios.md)。
- **流式仍是工程化简版**：滑窗重复识别 + 稳定锁定 + 词级前缀进度，尚未移植 Tilawa `tracker.ts`
  的词级对齐与推进策略。
- **样本未入库**：`sample_*.wav` 与模型一样不进版本库，clone 后需自行准备，否则内置样本验证
  会逐条报「识别失败」。

## 更多文档

| 文档 | 内容 |
|------|------|
| [docs/verification.md](docs/verification.md) | 各平台实测结果、Python 基准环境搭建、脚本清单与推荐工作流 |
| [docs/android-device.md](docs/android-device.md) | Android 真机联调、系统限制与替代手段、抓音质量校准 |
| [docs/ios.md](docs/ios.md) | iOS 支持说明、首次编译踩坑清单与必需配置 |

## 许可与致谢

- 本仓库代码：[MIT](LICENSE)；
- 声学模型、词表与数据表来自 [yazinsai/tilawa](https://github.com/yazinsai/tilawa) v0.2.0
  （模型 CC-BY-4.0，基座 `nvidia/stt_ar_fastconformer_hybrid_large_pcd_v1.0`），
  `tools/quran_offline/reference/*.ts` 为 Tilawa 的 MIT 参考实现，仅用于对照 Dart 侧语义；
- 经文库 `quran.json` 随 Tilawa 分发，使用前请确认其许可与标注要求。
