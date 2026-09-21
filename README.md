# 古兰经广播离线识别

[![CI](https://github.com/luobeibei0710/quran_offline_demo/actions/workflows/ci.yml/badge.svg)](https://github.com/luobeibei0710/quran_offline_demo/actions/workflows/ci.yml)

端侧**全离线**的《古兰经》广播识别应用（Flutter）：外部广播/诵读声 → 麦克风收音 →
ONNX 声学模型推理 → CTC 解码 → **全经 6236 节**经文匹配 → **权威人工译本查表**（62 种语言）
或端侧机器翻译兜底 → 本地历史留档。

识别全程**不联网、不上传音频**，音频与推理数据都不出设备。

Android 与 iOS 共用同一套 Dart 算法层，平台差异只在「调 ONNX Runtime 推理」这一层
（`quran_offline/ort` 通道）。

> **产品首页是广播识别**（`lib/broadcast/`）。
> 早期 Demo（实时跟读、语料准确度校核、流式诊断）已降级为**开发诊断**，
> 入口在首页右上角的扳手图标（或初始化失败页的「进入开发诊断」按钮），
> 说明见 [旧 Demo 与流式链路](docs/legacy-demo.md)。

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
- **实时预览 + 终稿**：收音过程中以 1 秒周期刷新草稿、候选经文与预览译文，
  片段结束（静音或超长切分）后落库为终稿；
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

匹配算法的完整口径（阈值、状态判据、指标定义、实测证据）见
[经文匹配与指标](docs/matching.md)。

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
| Android | Android SDK（compileSdk 随 Flutter）、JDK 17、NDK `29.0.14206865`、minSdk 26 |
| iOS | Xcode 26+、CocoaPods 1.16+、部署目标 **iOS 15.5**（详见 [iOS 平台说明](docs/platform-ios.md)） |

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

广播功能的**全经语料与译本已入版本库**（`assets/broadcast_quran/full/`），
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

`assets/broadcast_quran/full/`：

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
  --verses assets/broadcast_quran/full/quran.json \
  --vocab assets/quran_offline/vocab.json \
  --output assets/broadcast_quran/full/verse_ctc_tokens.json \
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
flutter test      # 24 个测试文件 / 207 个用例
```

测试所需的资产全部随仓库分发，**干净 clone 后无需下载任何东西**即可跑通全套测试：

- 旧 Demo 侧的用例通过 `FakeAssetBundle` 注入最小化内存资产、
  通过 `ScriptedOrtRunner` 注入合成声学证据、通过 `buildSpeechLikeSamples` 生成可驱动 VAD 的
  类语音信号，不读真实模型；
- 广播侧的 6 个测试文件读取**已入库**的全经语料与译本（`assets/broadcast_quran/full/**`），
  并需要共享词表 `assets/quran_offline/vocab.json`（也已入库，见
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
| 构建 iOS（模拟器） | 缓存 CocoaPods → `flutter build ios --simulator --debug`，只验证编译链接 |

> CI 只覆盖 `download_assets.sh` 提供的资产，**不含** `*_ort122.onnx` 与 `sample_*.wav`，
> 因此 CI 产出的 APK 仅用于验证编译链路，真实识别需在本地准备全部资产。

## 项目结构

```
lib/
├── main.dart                                          应用入口 + 引导页（首页 = 广播识别）
├── broadcast/                                         广播识别（产品功能）
│   ├── broadcast_services.dart                        依赖组装与生命周期（应用级单实例）
│   ├── application/
│   │   ├── microphone_source.dart                     16 kHz 单声道收音适配
│   │   ├── utterance_segmenter.dart                   断句状态机（本底自适应能量 + 静音时长）
│   │   ├── broadcast_transcriber.dart                 片段实际 ASR（保留声学证据供匹配复用）
│   │   ├── quran_match_service.dart                   全经匹配 + 候选裁决 + 指标与阈值
│   │   ├── translation_coordinator.dart               来源策略 / 缓存 / 重试 / 任务队列
│   │   └── broadcast_session_controller.dart          收音 → 断句 → 预览 → 终稿 → 落库
│   ├── data/
│   │   ├── app_database.dart                          SQLite 建库与迁移（schemaVersion 1）
│   │   ├── record_repository.dart                     事务保存 / 分页 / 幂等 / 重启恢复 / 缓存
│   │   ├── broadcast_corpus.dart                      全经语料库（数据驱动，含独立索引）
│   │   └── translation_catalog.dart                   62 语言译本目录与按需查表
│   ├── domain/utterance_record.dart                   三类文本 + 指标 + 译文模型与全部状态枚举
│   ├── translation/
│   │   ├── offline_translation_engine.dart            引擎契约与失败分类
│   │   ├── mlkit_translation_engine.dart              ML Kit 端侧翻译适配器（33 语言白名单）
│   │   └── verse_translation_repository.dart          校订译本仓储接口与空实现
│   └── ui/
│       ├── broadcast_home_page.dart                   三栏首页
│       ├── record_list_page.dart                      历史列表（分页 / 筛选 / 清空）
│       ├── record_detail_page.dart                    详情（三类文本 / 指标 / 逐词比对 / 追加语言）
│       └── widgets/text_section_card.dart             文本卡片（RTL 与徽标）
└── quran_offline/                                     旧 Demo 与共享算法层
    ├── arabic_presentation_forms.dart                 Unicode 15.0 Presentation Forms 兼容分解表
    ├── quran_text.dart                                阿拉伯语归一化与相似度
    ├── ctc_decoder.dart                               贪心 CTC 解码
    ├── ctc_scorer.dart                                前向后向对数似然 + 稳定前缀
    ├── quran_word_progress.dart                       词边界切分 + 已读词估算（提词器）
    ├── quran_assets.dart                              旧经文库 / 词表 / span 表加载 + VerseIndex
    ├── quran_matcher.dart                             召回 + 精排 + 置信度（两库共用）
    ├── ort_runner.dart                                推理桥接口（平台通道）
    ├── quran_recognizer.dart                          一次性识别 + 流式会话（含 VAD 门控）
    ├── transcript_stitcher.dart                       转写稿增量拼接（按最长词级重叠去重）
    ├── timed_transcript.dart                          带时间戳窗口的实际 ASR 转写拼接
    ├── offline_transcriber.dart                       声学暂停分段与有界离线实际 ASR
    ├── offline_corpus_check.dart                      无头端侧验收（不进 UI）
    ├── word_alignment.dart                            词级对齐、判定阈值与比对指标
    ├── word_error_rate.dart                           严格词错误率
    ├── reference_text.dart                            比对原文加载（设备文件 / 内置资产）
    ├── quran_compare_page.dart                        原文 / 转写逐词对照页
    ├── corpus_audio.dart                              语料 WAV 解码与格式校验
    ├── corpus_catalog.dart                            内置连续语料清单 + 设备自定义语料
    ├── corpus_runner.dart                             旧流式章节重建诊断（按实时节奏灌音）
    ├── corpus_verify_page.dart                        语料页（默认离线实际 ASR，可切旧流式诊断）
    └── quran_offline_demo_page.dart                   开发诊断主页面
android/app/src/main/java/com/llvision/quran_offline_demo/QuranOrtBridge.java   ONNX Runtime 桥
android/app/src/main/kotlin/com/llvision/quran_offline_demo/MainActivity.kt     通道注册
ios/Runner/QuranOrtBridge.{h,m}                     ONNX Runtime 桥
ios/Runner/AppDelegate.swift                        通道注册
test/                                               单元测试与页面冒烟测试
assets/broadcast_quran/full/                        广播全经语料 + 62 语言译本（入版本库）
assets/quran_offline/                               模型与旧库资产（模型不入版本库；vocab.json 入库）
assets/quran_offline/corpus/                        语料校核用的多节连续诵读（不入版本库）
assets/quran_reference/                             旧比对页原文（入版本库）
resources/broadcast_quran/                          上游归档 + 全经音频清单（音频不入版本库）
tools/broadcast_quran/                              全经语料构建、token 表生成、译本下载
tools/quran_offline/                                模型改造、资产下载与 Python 验证脚本
tool/                                               Dart 基准与标定脚本（flutter test / dart run）
docs/                                               架构、匹配、验收与平台文档
.github/workflows/ci.yml                            静态分析 + 测试 + APK 构建 + iOS 编译
```

## 真机验收记录

> **状态：Android 侧 4/6 满足，待 iOS 真机。**
> 2026-09-21 完成首轮全经连续播放（33 分钟 / 42 条记录 / 0 崩溃）。
> 验收矩阵收敛为 6 项：**时长、定位正确性、译文来源、Android 真机 4 项满足**；
> F1 实测达标（0.714 ≥ 0.60）但**阈值未经确认**；**iOS 真机未做**。
> **在 iOS 真机跑通前，广播链路不得声称已验收。**

| 维度 | 目标 | 状态 |
|------|------|------|
| 连续收听时长 | ≥ 30 分钟不间断，无崩溃 | ✅ 33 分钟，0 崩溃 |
| 定位正确性 | 节号随音频严格单调递增 | ✅ 满足（2 处表面跳跃已逐条查证：音源跳章、著名相似节的真实歧义） |
| 译文来源 | `curatedEdition` 占比接近 100% | ✅ 95.2%（40/42；另 2 条 `machineAsr` 落在未匹配上，属设计内兜底） |
| F1 | 已匹配记录 F1 均值 ≥ 0.60 | ⚠️ 实测 0.714 达标，但**阈值待确认** |
| Android 真机 | 链路在 Android 真机跑通 | ✅ Redmi 24117RK2CC |
| iOS 真机 | 链路在 iOS 真机跑通 | ❌ 未做（本轮 iOS 只作音源） |

其余维度（诵读者覆盖、章节覆盖、库外负样本、延迟、拾音分档）仍照常记录在
§3，但**不再作为验收门槛**。

完整矩阵、逐条记录与性能 P50/P95 见 [真机验收记录](docs/device-verification.md)，
机器可读证据在 [docs/evidence/](docs/evidence/)。
其余可复现证据（主机端到端、三段内置语料离线 ASR）见
[经文匹配与指标](docs/matching.md) 与 [离线语料准确度](docs/offline-accuracy.md)。

## 已知限制

- **广播链路的真机验收尚未完成（最重要的一条）**。首轮 33 分钟全经连续播放已证明链路在
  真实外放拾音下可用（42 条记录、0 崩溃、节号单调递增、`curatedEdition` 占 95.2%、
  已匹配记录 F1 均值 0.714）。收敛后的 6 项验收矩阵里 **Android 侧 4 项满足、
  F1 阈值待确认、iOS 真机完全未做**，因此尚不能声称已验收。
  见上方「真机验收记录」与 [真机验收记录](docs/device-verification.md)。
- **ML Kit 机器翻译未在真机运行过**：语言包需动态下载（不能随包分发），
  端侧翻译模型依赖 Google Play 服务，无 GMS 设备的可用性未验证；
  阿→中经英语中转，中文质量必须单独评估，不能用英文结果推定。
- **iOS 模拟器不能跑广播功能**：ML Kit 的传递依赖声明不支持 arm64 模拟器，
  iOS 侧只能真机验证（编译链接由 CI 覆盖）。
- **62 种译本只在中文与英文上做过端到端验证**，其余 60 种仅校验了目录条目、
  节数与查表命中，未做逐句语义抽检。
- **严格词准确率不是 90%**：内置语料的容错 F1/P/R ≥ 0.95，但严格 WER 仍有约 14%–17%，
  差异来自奥斯曼体与现代阿拉伯书写体、以及真实解码错误。两组指标口径不同，
  不能把 F1 解读成严格逐词准确率。
- **匹配阈值是独立标定的起点**：`spanPenalty = 0.1` 在真实整章音频上做过五档灵敏度
  检验（结果相同），`maxSpan = 8` 由端到端真实音频暴露的「跨度不足」确定；
  但标定素材是**单个诵读者 + 主机直连音频**，真机外放拾音下的确认与拒识行为
  仍需与人工标注对照。
- **预览路径未降配**：首轮真机实测预览匹配 P50 615 ms / P95 1696 ms（n=635），
  P95 已超过 1 s 的预览周期；调度是「上一次完成后再排下一次」所以不积压，
  代价是刷新率随片段长度下降。端到端终稿 P50 4062 ms / P95 5733 ms（n=42，含翻译）。
  理论上预览应使用更小的 `topK` / `maxSpan`，尚未验证必要性。
- **应用体积大**：包含 124.6 MB 模型 + 42.9 MB token 表 + 89 MB 译本，
  debug APK 约 380 MB；正式交付需按需下载或只打单 ABI。
- **旧 Demo 的流式链路仍是工程化简版**：实时路径的 VAD 音频内信噪比判据
  （峰值 ≥ 中位数 × 2.5）隐含「窗口里既有朗读也有停顿」的前提，
  一口气不停顿的长诵存在被挡风险；提词器的已读词估算改为帧级强制对齐后，
  高亮滞后/超前的量还没有按真人朗读实测。详见 [旧 Demo 与流式链路](docs/legacy-demo.md)。
- **置信度是启发式**：按「与次优的相对差距（15%）」映射，完美匹配与长窗口下会饱和到 1.00，
  仅用于界面提示，不参与判定。
- **模型与测试音频未入库**：模型、`sample_*.wav` 与内置语料 WAV 都不进版本库
  （词表 `vocab.json` 例外，仅 21 KB，随仓库分发以保证测试可离线运行），
  clone 后需分别准备，否则相应验证会显示「识别失败」或「不可用」。
- **iOS 真机仅覆盖离线语料路径**：三段内置语料的 F1/P/R 与 Android 完全一致，
  但麦克风实采与实时跟踪仍未在 iOS 上验证。

## 更多文档

| 文档 | 内容 |
|------|------|
| [docs/architecture.md](docs/architecture.md) | 分层结构、数据流、依赖组装、数据模型与状态机 |
| [docs/matching.md](docs/matching.md) | 匹配算法、阈值常量、指标口径、主机端到端证据与耗时 |
| [docs/offline-accuracy.md](docs/offline-accuracy.md) | 三段内置语料的离线实际 ASR 验收（主机 / Android / iOS） |
| [docs/device-verification.md](docs/device-verification.md) | **真机验收记录**（方法、命令、快照脚本与待补充的记录表） |
| [docs/platform-android.md](docs/platform-android.md) | Android 构建安装、系统限制与替代手段、抓音质量校准 |
| [docs/platform-ios.md](docs/platform-ios.md) | iOS 支持、必需配置、依赖共存与模拟器限制 |
| [docs/legacy-demo.md](docs/legacy-demo.md) | 旧 Demo（实时跟读 / 语料校核 / 流式诊断）与流式链路经验 |
| [docs/evidence/](docs/evidence/) | 机器可读验收证据（离线 ASR 指标、真机全经播放逐条记录与汇总） |

## 许可与致谢

- 本仓库代码：[MIT](LICENSE)；
- 声学模型、词表与旧库数据表来自 [yazinsai/tilawa](https://github.com/yazinsai/tilawa) v0.2.0
  （模型 CC-BY-4.0，基座 `nvidia/stt_ar_fastconformer_hybrid_large_pcd_v1.0`），
  `tools/quran_offline/reference/*.ts` 为 Tilawa 的 MIT 参考实现，仅用于对照 Dart 侧语义；
- 全经原文快照来自 [Tanzil Project](https://tanzil.net/)（CC-BY 3.0，许可与上游 SHA-256
  见 `assets/broadcast_quran/full/manifest.json` 与 `NOTICE.txt`）；
- 章名元数据来自 [risan/quran-json](https://github.com/risan/quran-json)（CC BY-SA 4.0）；
- 62 种语言人工译本来自 QuranEnc（经 [risan/quran-json](https://github.com/risan/quran-json) 分发），
  每个语言文件与目录条目都带出版方、版本、来源与许可全文，
  使用时必须遵守 QuranEnc 的署名与不得修改增删等义务，界面需展示署名。
