# 古兰经广播离线识别

[![CI](https://github.com/luobeibei0710/quran_offline_demo/actions/workflows/ci.yml/badge.svg)](https://github.com/luobeibei0710/quran_offline_demo/actions/workflows/ci.yml)

端侧离线识别的《古兰经》广播应用（Flutter）：外部广播/诵读声 → 麦克风收音 →
ONNX 声学模型推理 → CTC 解码 → **全经 6236 节**经文匹配 → **权威人工译本查表**（62 种语言）
或端侧机器翻译兜底 → 本地历史留档。

识别全程**不联网、不上传音频**，音频与推理数据都不出设备。机器翻译的语言包可由宿主显式允许按需下载。

Android 与 iOS 共用同一套 Dart 算法层，平台差异只在「调 ONNX Runtime 推理」这一层
（`quran_offline/ort` 通道）。

广播功能已抽为可通过 path 依赖安装的 [Flutter SDK](packages/quran_broadcast_sdk/README.md)：
插件自带 Android/iOS 推理桥、全经语料与译本；宿主提供未入库的兼容 ONNX 模型与麦克风权限说明。

> **产品首页是广播识别**（`packages/quran_broadcast_sdk/lib/broadcast/`）。
> 早期 Demo（实时跟读、语料准确度校核、流式诊断）已降级为**开发诊断**，入口在首页右上角的扳手图标。

---

## 功能特性

- **全离线**：声学模型（124.6 MB ONNX）、词表、全经语料与译本全部内置，
  推理与查表都在本机完成；
- **全经覆盖**：匹配库是 **114 章 6236 节** Tanzil 快照（`corpusId = tanzil-1.1-uthmani-full`），
  任意章节的广播内容都能定位，不再是抽样章节；
- **三栏显示，三类文本互不冒充**：实际 ASR 转写 / 匹配到的标准经文 / 目标语言译文，
  三栏各自标注来源，机器翻译不会被标成校订译本；
- **62 种语言权威译本**：命中经文后优先查**人工译本**表（中文马坚、英文 Saheeh International 等，
  QuranEnc 授权，界面显示出版方与版本），查不到才走机器翻译；
- **端侧机器翻译兜底**：ML Kit（`google_mlkit_translation` 0.14.0），
  阿拉伯语经英语中转；缺语言包时明确失败并支持重试，**不降级到云服务**；
- **实时预览 + 终稿**：有新音频时最短间隔 1 秒尝试刷新最近 12 秒的转写草稿与候选经文，
  同一候选连续两轮稳定后显示对应的预览译文；片段结束（静音或超长切分）后用完整音频复核并落库；
- **片段的粒度是「一句」不是「一节」**：支持半节、跨节连读、同节复读、跳章；
  匹配结果以节范围表达，不强行补全未听到的内容；
- **库外内容如实拒识**：匹配不到就显示未匹配并保留真实转写，
  不返回「任意最相似的经文」，也不回退任何其它语料库；
- **持久化历史**：SQLite 保存三类文本快照、匹配范围、比对指标、译文来源与任务状态，
  重启仍在；支持分页、语言/状态筛选、整体清空、同记录追加另一语言译本；
- **两端共享算法层**：断句、解码、召回、精排、裁决、对齐、指标全部是纯 Dart。

## 技术方案

```
外部广播 / 诵读声
   ↓
麦克风 16 kHz 单声道 PCM16 → float32
   ↓
ONNX Runtime（Android AAR / iOS onnxruntime-objc 1.22.0）—— 只做张量翻译
   ↓  log_probs [1, T, 1025]
纯 Dart 算法层（Android / iOS 共用）
   ├─ 断句状态机（本底自适应的能量 + 静音时长）
   ├─ 贪心 CTC 解码（TextCtcDecoder）
   ├─ 经文召回（倒排分词 + 覆盖率 / 长度匹配度）
   ├─ CTC 约束精排（前向后向对数似然，按帧归一化）
   ├─ 候选二次裁决（解释比例分带 + 候选差距）→ confirmed / partial / candidate / unmatched
   ├─ 词级对齐（Needleman–Wunsch）与比对指标（P / R / F1 / 严格 WER）
   └─ 翻译来源裁决（校订译本 / 标准原文机翻 / 转写机翻）
   ↓
本地全经库取标准经文 + 译本查表 → 三栏展示 → SQLite 落库
```

## 界面与交互

### 首页（三栏）

| 区域 | 内容 |
|------|------|
| 顶部 | 目标语言下拉（识别中禁用并提示「识别中不可切换」）、离线资源状态与「准备语言包」按钮、当前阶段文案 |
| 第一栏 识别转写 | 模型实际输出的阿拉伯语（RTL 22 px），识别中显示草稿 |
| 第二栏 匹配经文 | 全经库标准原文 + `surah:ayah` 范围 + 状态徽标（已确认 / 部分节 / 候选 / 未匹配） |
| 第三栏 目标译文 | 译文正文 + 来源徽标（校订译本为青色，机器翻译为橙色）+ 输入范围说明 |
| 底部 | 「开始识别 / 停止识别」大按钮 |

AppBar 右上角两个入口：**记录 N**（历史列表）与**扳手图标**（开发诊断）。

### 历史列表与详情

- 列表：稳定序号 `#000123`、时间、语言徽标、匹配摘要、转写与译文摘要、删除按钮；
  分页 50 条，滚动到底自动加载；支持**语言筛选 + 状态筛选**与**全部删除**（识别中禁止）；
- 详情：三类文本快照 + 比对指标（P / R / F1 / 严格 WER / S-D-I / 词数）
  + **逐词比对**（一致绿 / 近似黄 / 错配红 / 缺失蓝灰 / 多余橙）
  + 开发诊断折叠区（匹配证据 JSON、耗时、片段边界）
  + 「追加语言版本」菜单（同一记录追加另一语言译本，不覆盖已有译文）。

## 翻译来源策略

命中经文后按三条路径裁决，界面与数据库都记录真实来源，**不伪造译本**：

| 来源 | 触发条件 | 输入 | 界面标记 |
|------|----------|------|----------|
| `curatedEdition` | 匹配到经文，且目标语言有 QuranEnc 授权人工译本 | 标准原文 | 校订译本 + 版本署名 |
| `machineCanonical` | 匹配到经文，但该语言无译本 | 标准原文（半节只取已确认词范围） | 机器翻译·标准原文 |
| `machineAsr` | 未匹配到经文 | 实际 ASR 转写 | 机器翻译·识别转写（未匹配经文） |

要点：

- 判据是**有没有匹配到节**；`candidate`（有明确候选、仅可信度未达确认门槛）同样走译本查表，
  不因为状态是「候选」就退化成机翻；
- 半节命中译本时，落库 `inputScope = fullVerseContext`，界面标注「整节译文（上下文）」，
  不冒充该片段的精确译文；
- 译本按语言**按需加载并只缓存当前语言**（62 种语言合计约 89 MB，不能全部常驻）；
- ML Kit 机器翻译是**显式白名单**（33 种语言）；未覆盖的语言仍可用译本查表，
  只是未匹配片段无法机翻，界面如实提示；
- 缓存键 = 输入哈希 + corpusId + corpusVersion + 目标语言 + 提供方 + 引擎代号 + 预处理版本。

## 快速开始

### 环境要求

| 平台 | 要求 |
|------|------|
| 通用 | Flutter 3.41+（CI 固定 3.41.8）、Dart SDK `^3.11.5` |
| Android | Android SDK 36（插件 compileSdk）、JDK 17、NDK `29.0.14206865`、minSdk 26 |
| iOS | Xcode 26+、CocoaPods 1.16+、部署目标 **iOS 15.5** |

### 1. 获取模型与数据

**模型与旧库数据表不入版本库**，需自行下载（词表 `vocab.json` 是唯一例外：
只有 21 KB，且广播侧单元测试加载语料库时需要它，因此随仓库分发）：

```bash
# 下载原版模型与数据表（含 sha256 校验）
bash tools/quran_offline/download_assets.sh

# 生成移动端可用的改造版模型（需 venv：onnx / onnxruntime / numpy）
tools/quran_offline/.venv/bin/python tools/quran_offline/convert_for_ort122.py
```

内置语料（语料校核用）同样不入版本库：

```bash
bash tools/quran_offline/download_corpus.sh
```

`:warning:` `sample_*.wav`（内置单节样本）不由任何脚本提供，需自行准备并按
`sample_SSSAAA.wav` 命名放入 `assets/quran_offline/`，否则开发诊断页的内置样本自测会显示失败。

广播功能的**全经语料与译本已入版本库**（`packages/quran_broadcast_sdk/assets/broadcast_quran/full/`），
无需额外下载。仅在需要重建时才运行构建脚本，见 [资产与脚本](#资产与脚本)。

### 2. 运行

```bash
flutter pub get
flutter run                   # 需要真机或模拟器（麦克风）
```

首次启动会加载全经索引（13 MB 级 token 表）、建库并加载 124.6 MB 声学模型，
约需数秒；模型会复制到应用私有目录缓存，后续启动复用。

使用步骤：

1. 启动 → 引导页初始化（独立经文库 / 数据库 / ASR 模型）→ 进入首页；
2. 选择目标语言（可选），点「准备语言包」按需下载 ML Kit 语言包（仅机器翻译需要）；
3. 点「开始识别」，把设备放在广播/诵读声源附近；
4. 三栏随识别刷新；一句结束（静音约 1.2 s 或超过 30 s）后自动落库；
5. 点右上角「记录 N」查看历史，进入详情可看逐词比对与指标，或追加另一语言译本。

## 模型与数据

### 声学模型

来自 [yazinsai/tilawa](https://github.com/yazinsai/tilawa) v0.2.0
（SDK MIT；模型 CC-BY-4.0，基座 `nvidia/stt_ar_fastconformer_hybrid_large_pcd_v1.0`）。

| 文件 | 体积 | 说明 |
|------|------|------|
| `fastconformer_full_mixed.onnx` | 约 84 MB | 原版：FastConformer，int4 MatMul + int8 Conv 混合量化，含 57 个 `ConvInteger` 节点 |
| `fastconformer_full_mixed_ort122.onnx` | 约 124.6 MB | **移动端实际加载**：由上一行数学等价改造而来，供 ORT 1.22 使用 |
| `vocab.json` | 约 21 KB | 1025 个 token，最大 id 为 blank（广播与旧 Demo 共用） |

**为什么需要两版模型**：`ConvInteger`（int8 量化卷积）只有较新版本的 ORT CPU EP 实现，
而移动端可用的 `onnxruntime-android` / `onnxruntime-objc` 为 1.22.0，加载原模型会报
`NOT_IMPLEMENTED: Could not find an implementation for ConvInteger(10)`。

`tools/quran_offline/convert_for_ort122.py` 做**数学等价**改造：

```
x_q → ConvInteger(x_q, w_q, x_zp, w_zp) → Cast → Mul(·, x_scale*w_scale)
        ↓
x_q → DequantizeLinear(x_q, x_scale, x_zp) → Conv(x_dq, w_fp32)
```

代价是这 57 个卷积的权重由 int8 变为 float32（88 MB → 130 MB，推理走 FP32 卷积），
收益是模型能在移动端可用的 ORT 版本上运行。等价性由 `verify_conversion.py` 对比两版模型输出
验证（逐帧 argmax 一致率 100%）。

两端原生桥都锁定 **ONNX Runtime 1.22.0**：跨平台数值差异会翻转 CTC 跨度判定，
版本必须对齐（见 [已知限制](#已知限制)）。

### 广播语料库（全经，入版本库）

`packages/quran_broadcast_sdk/assets/broadcast_quran/full/`：

| 文件 | 体积 | 说明 |
|------|------|------|
| `manifest.json` | 1.3 KB | corpusId / 版本 / 上游 SHA-256 / 许可 / 节数 / token 表校验 |
| `NOTICE.txt` | 1.1 KB | Tanzil 版权区块（CC-BY 3.0） |
| `quran.json` | 1.9 MB | 全经 6236 节原文（`sourceText` 逐字保留上游文本）+ 114 章章名元数据 |
| `verse_ctc_tokens.json` | 42.9 MB | 本仓库生成的 CTC token 表，键 `surah:ayahStart:ayahEnd`，含 46,752 条跨度（`maxSpan = 8`） |
| `translations/index.json` + 62 个译本 | 约 89 MB | QuranEnc 授权人工译本目录与正文（每语言约 1.4 MB） |

**token 表的口径偏差必须说清楚**：上游 `quran_ctc_tokens.json` 的 token 分数未公开，
无法逐 token 复现。本仓库用**确定性分词**（最少 token 数，同级取更长片段）从同一词表重新生成，
单节逐 token 与官方表的一致率约 21%。生成的序列 round-trip 全部正确
（解码回原文逐字相同），但**排序分数的绝对值口径与旧库不同**，因此广播侧的跨度惩罚与
可信度阈值是**独立标定**的，不能沿用旧库常数。

**章首太斯米前缀**由文本自动判定（不硬编码）：114 章中 112 章带前缀，
`1:1`（太斯米本身就是该节）与 `9:1`（忏悔章无太斯米）不带，与传统一致。
解析时只在「前缀匹配且后面还有词」的情况下剥离，`1:1` 不剥离。

**为什么要独立成库**：广播功能只检索自己的全经语料，
**不读取旧 Demo 的 `assets/quran_offline/quran.json` / `quran_ctc_tokens.json`**，
也不在任何情况下回退过去。这一点由自动化测试用「记录全部资产请求的 bundle」断言，
而不是靠代码约定。

### 旧 Demo 语料库（不入版本库）

`assets/quran_offline/`：旧经文库 `quran.json`（3 MB / 6236 节）、
`quran_ctc_tokens.json`（11.7 MB span 表，供旧流式链路）、
5 个 `sample_*.wav`、`corpus/`（3 段多节连续诵读音 + `manifest.json`）。

`assets/quran_reference/reference_text.txt`（3.2 KB）是旧比对页的内置参考答案，入版本库，可由设备文件覆盖。

### 上游归档与音频

`resources/broadcast_quran/`：

- `tanzil_1_1/`：Tanzil 全经原文快照（`quran-uthmani.txt`，SHA-256 已记入 manifest）与版权说明，入版本库；
- `manifest.json`：文本快照与全经音频的来源、字节数、逐章 SHA-256 记录；
- `full_recitation/`：Alafasy 全经整章 MP3（114 章，约 1.7 GB），**不入版本库**，
  按 `resources/broadcast_quran/manifest.json` 的清单重新获取。

## 资产与脚本

### 语料与译本构建（`tools/broadcast_quran/`）

```bash
# 从 Tanzil 快照生成全经语料 JSON + NOTICE + manifest 的取值（--check 只统计不写文件）
python3 tools/broadcast_quran/build_full_corpus.py --check
python3 tools/broadcast_quran/build_full_corpus.py

# 生成 CTC token 表（跨度上限 8；--verify-legacy 可与官方表比对一致率）
python3 tools/broadcast_quran/generate_verse_tokens.py \
  --verses packages/quran_broadcast_sdk/assets/broadcast_quran/full/quran.json \
  --vocab assets/quran_offline/vocab.json \
  --output packages/quran_broadcast_sdk/assets/broadcast_quran/full/verse_ctc_tokens.json \
  --max-span 8

# 下载 62 种语言译本（逐个校验 license.status == granted，未授权即拒绝打包）
python3 tools/broadcast_quran/fetch_translations.py --check
python3 tools/broadcast_quran/fetch_translations.py
```

### 模型与旧库工具（`tools/quran_offline/`）

| 脚本 | 用途 |
|------|------|
| `download_assets.sh` | 下载原版模型与数据表（含 sha256 校验） |
| `download_corpus.sh` | 从 Quran.com CDN 取逐节诵读、拼成 16 kHz 单声道 WAV（可配 `RECITER=` / `RANGES=` / `INCLUDES_BISMILLAH=`） |
| `convert_for_ort122.py` | 把原版模型改造为 ORT 1.22 可加载版本（`--check` 只校验） |
| `verify_conversion.py` | 对比改造前后模型输出，验证数学等价性 |
| `verify_corpus.py` | 用官方测试语料（文件名即答案）在声学层验证准确率 |
| `tune_span_penalty.py` | 跨度惩罚标定与**门禁**：`--check` 从 Dart 源码读取当前惩罚值，校验 5 条官方样本的冠军是否都等于正确单节、惩罚是否仍在允许上界内，不符即非零退出 |
| `check_sample.py` / `diag_ctc.py` / `diag_ayah_isolated.py` | 长音频分段识别、候选 CTC 分数对比、逐节孤立上限诊断 |
| `host_ort_server.py` | 本机 ONNX Runtime HTTP 服务（只监听 `127.0.0.1`），供 `tool/` 下的 Dart 基准脚本使用 |
| `poc_transcribe.py` / `poc_match.py` | 最早的 P0/P1 链路验证（依赖原版模型） |
| `reference/*.ts` | Tilawa 侧 TypeScript 参考实现，仅用于对照 Dart 侧语义 |

### 基准与标定（`tool/`）

下列脚本需要**本机 host ORT 服务 + 真实音频**，CI 不覆盖：

| 脚本 | 运行方式 | 用途 |
|------|----------|------|
| `broadcast_end_to_end_test.dart` | `flutter test`（需 `QURAN_E2E_AUDIO_DIR` / `QURAN_E2E_CASES` / `QURAN_E2E_OUT`） | 广播端到端：真实音频 → 转写 → 全经匹配 → 译本 |
| `broadcast_span_tuning_test.dart` | `flutter test`（需 `QURAN_TUNE_WAV` / `QURAN_TUNE_OUT`） | 跨度参数标定（25 s 窗口 / 8 s 步长） |
| `diagnose_match_test.dart` | `flutter test`（需 `QURAN_DIAG_AUDIO` 等） | 单窗口召回 / 精排诊断 |
| `offline_benchmark_test.dart` | `flutter test`（需 `QURAN_BENCH_OUT`） | 三段内置语料的离线实际 ASR 基准，任一 F1/P/R < 0.9 即失败 |
| `stream_benchmark_test.dart` | `flutter test`（需 `QURAN_BENCH_OUT`；`QURAN_BENCH_ADVANCE=false` 可关闭窗口推进做消融） | 旧流式链路基准 |
| `tilawa_compare_metrics.dart` | `dart run` | 用同一套 `WordAlignment` 口径对比 Tilawa 官方包结果 |
| `generate_arabic_forms.py` | `python3`（`--check` 检查漂移） | 生成 `lib/quran_offline/arabic_presentation_forms.dart` |

上述需要推理服务的脚本默认连 `http://127.0.0.1:8765`，可用 `QURAN_ORT_URL` 覆盖。
`host_ort_server.py` 只监听 `127.0.0.1`，模型与音频都不上传。

## 测试与 CI

```bash
flutter analyze   # 静态分析
flutter test      # 26 个测试文件 / 231 个用例（2026-09-24 本地验证）
```

测试所需的资产全部随仓库分发，**干净 clone 后无需下载任何东西**即可跑通全套测试：

- 旧 Demo 侧的用例通过 `FakeAssetBundle` 注入最小化内存资产、
  通过 `ScriptedOrtRunner` 注入合成声学证据、通过 `buildSpeechLikeSamples` 生成可驱动 VAD 的
  类语音信号，不读真实模型；
- 广播侧测试读取**已入库**的全经语料与译本（`packages/quran_broadcast_sdk/assets/broadcast_quran/full/**`），
  并需要包内词表 `packages/quran_broadcast_sdk/assets/quran_offline/vocab.json`（也已入库，见
  [获取模型与数据](#1-获取模型与数据)）。

真机麦克风与模型推理仍需 `flutter run` 验证。

| 测试文件 | 覆盖内容 |
|----------|----------|
| `broadcast_corpus_test.dart` | 全经语料库完整性、章节索引、章首前缀判定，以及「只读新库、不请求旧库资产」的资产记录断言 |
| `broadcast_match_test.dart` | 召回 / CTC 精排 / 候选裁决 / 太斯米歧义 / 极短节抑制 / 阈值分带 |
| `broadcast_repository_test.dart` | SQLite：写入幂等、分页、删除与清空、迟到译文防护、任务重启恢复 |
| `broadcast_session_test.dart` | 会话状态机、断句、终稿队列、落库与翻译调度 |
| `broadcast_translation_test.dart` | 来源策略（三路径）、缓存键、重试与失败分类 |
| `broadcast_translation_catalog_test.dart` | 62 语言译本目录、节数一致性、语言注册顺序与查表 |
| `quran_text_test.dart` | 阿拉伯语归一化（音标 / Tatweel / 字母变体 / BOM / Presentation Forms-A、B）、相似度与片段相似度 |
| `ctc_decoder_test.dart` | 贪心 CTC 解码、相邻重复折叠、blank 处理、词边界下标 |
| `ctc_scorer_test.dart` | 前向后向对数似然、可行性下界、最长稳定前缀选择 |
| `quran_word_progress_test.dart` | 词边界切分、已读词估算、词表与 token 词组对齐 |
| `quran_assets_test.dart` | 旧库词表/经文/span 表解析、排序索引、缓存 |
| `quran_recognizer_test.dart` | 「解码 → 召回 → 精排」端到端、VAD 门控与流式会话行为 |
| `word_alignment_test.dart` | 词级对齐（漏词不连带判错）、一致/近似/错配/缺失/多余判定、覆盖率与 F1、结论分档 |
| `word_error_rate_test.dart` | 严格词错误率（替换/缺失/多余）与空参考边界 |
| `transcript_stitcher_test.dart` | 逐窗结果的最长重叠去重、整段已包含不重复追加 |
| `timed_transcript_test.dart` | 带时间戳重叠窗口的词级拼接、边界去重与尾词保留 |
| `offline_transcriber_test.dart` | 声学暂停分段、长段有界回退、静音/空音频、取消与实际解码拼接 |
| `reference_text_test.dart` | 原文来源优先级（设备文件 → 内置资产）、空白内容回退、双来源缺失报错 |
| `quran_compare_page_test.dart` | 比对页左右两栏渲染、缺失侧占位、指标与结论 |
| `corpus_audio_test.dart` | WAV 解码、非 44 字节头（夹其它块）仍可解、格式不符的报错与转码提示 |
| `corpus_catalog_test.dart` | 内置语料始终在列、检测到自定义音频时追加条目 |
| `corpus_runner_test.dart` | 旧流式诊断的灌音事件与章节重建稿、命中判定及取消 |
| `corpus_verify_page_test.dart` | 默认离线校核、流式诊断切换、完成后进入比对页与坏音频提示 |
| `widget_test.dart` | 开发诊断页首帧与「加载模型 → 内置样本验证 → 就绪」流程 |
| `support/*.dart` | 夹具：内存资产包、脚本化推理桥、合成证据与类语音信号、WAV 构造 |

CI 定义见 `.github/workflows/ci.yml`，三个 Job：

| Job | 内容 |
|-----|------|
| 静态分析 + 单元测试 | `flutter analyze` → `flutter test --coverage`，上传 `lcov.info` |
| 构建 Android APK | 缓存/下载模型资产（约 103 MB）→ `flutter build apk --debug`，上传 APK 产物 |
| 构建 iOS（设备切片，不签名） | 缓存 CocoaPods → `flutter build ios --debug --no-codesign`，只验证编译链接（**不用模拟器**：ML Kit 的传递依赖不支持 arm64 模拟器） |

> CI 只覆盖 `download_assets.sh` 提供的资产，**不含** `*_ort122.onnx` 与 `sample_*.wav`，
> 因此 CI 产出的 APK 仅用于验证编译链路，真实识别需在本地准备全部资产。

并发策略：**只有 PR 会取消在跑的运行，main 上的 push 不取消**。
两个构建 Job 都排在 `analyze-and-test` 之后（整条链路约 7 分钟），
如果 main 也取消，连续 push（例如连续改文档）会把上一次掐断，
只剩一堆 `cancelled`，拿不到完整结论。同一并发组内 GitHub 最多保留
「1 个在跑 + 1 个排队」，所以 main 上连续 push 时被顶掉的是排队中的旧运行，
**最新一次一定会完整跑完**。

## 项目结构

```text
packages/quran_broadcast_sdk/
├── lib/quran_broadcast_sdk.dart            对外入口：初始化、会话、语言、历史与页面
├── lib/broadcast/                     收音、断句、转写、全经匹配、翻译与 SQLite
├── lib/quran_offline/                 广播与旧 Demo 共用的 CTC、匹配、对齐算法
├── android/                           Flutter 插件、ONNX Runtime 1.22.0 推理桥
├── ios/                               Flutter 插件、ONNX Runtime 1.22.0 推理桥
└── assets/                            全经语料、词表与 62 种语言译本
lib/main.dart                         应用入口与启动引导页
lib/quran_offline/                    旧 Demo 页面、语料校核与诊断代码
assets/quran_offline/                宿主模型与旧 Demo 数据（模型不入库）
resources/broadcast_quran/            上游归档与未打包的全经音频
tools/                                模型转换、语料生成、基准与诊断脚本
test/                                 广播与旧 Demo 回归测试
docs/                                 本地开发与验收文档，不进入公开仓库
```

## 验证与已知限制

`flutter analyze` 和 `flutter test` 可在不下载模型的情况下检查 Dart 代码、语料索引、译本目录、匹配逻辑、数据库与界面状态。Android/iOS 编译、麦克风权限、真实诵读识别和语言包下载需在目标环境另行验证；单测不能代替真机音频链路。

- **模型需由宿主准备**：声学模型不在 Git 中。缺少兼容的 ONNX 资产时，SDK 初始化会返回明确错误；旧 Demo 的样本 WAV 与语料音频也需本地提供。
- **安装包较大**：全经 token 表约 42.9 MB、62 种译本约 89 MB，兼容模型约 124.6 MB。发布前应按目标语言与设备 ABI 评估体积。
- **翻译来源必须区分**：匹配经文时优先使用带署名的人工译本；未匹配语音只能标为机器翻译。ML Kit 机器翻译语言包可能需要宿主显式允许下载，无 GMS 设备的可用性应单独验证。
- **匹配指标有边界**：容错 F1 与严格 WER 是不同口径；候选经文和实时预览也不能当作最终确认结果。跨诵读者、噪声环境和长时间连续使用仍需目标设备验证。
- **iOS 模拟器受限**：ML Kit 依赖不支持部分 arm64 模拟器配置，iOS 侧以真机验收音频链路。

内部测试记录、设备日志、提示词与交接文档保留在本地，不随 GitHub 仓库分发。

## 许可与致谢

- 本仓库代码：[MIT](LICENSE)；
- 声学模型、词表与旧库数据表来自 [yazinsai/tilawa](https://github.com/yazinsai/tilawa) v0.2.0
  （模型 CC-BY-4.0，基座 `nvidia/stt_ar_fastconformer_hybrid_large_pcd_v1.0`），
  `tools/quran_offline/reference/*.ts` 为 Tilawa 的 MIT 参考实现，仅用于对照 Dart 侧语义；
- 全经原文快照来自 [Tanzil Project](https://tanzil.net/)（CC-BY 3.0，许可与上游 SHA-256
  见 `packages/quran_broadcast_sdk/assets/broadcast_quran/full/manifest.json` 与 `NOTICE.txt`）；
- 章名元数据来自 [risan/quran-json](https://github.com/risan/quran-json)（CC BY-SA 4.0）；
- 62 种语言人工译本来自 QuranEnc（经 [risan/quran-json](https://github.com/risan/quran-json) 分发），
  每个语言文件与目录条目都带出版方、版本、来源与许可全文，
  使用时必须遵守 QuranEnc 的署名与不得修改增删等义务，界面需展示署名。
