# 古兰经离线识别 Demo

[![CI](https://github.com/luobeibei0710/quran_offline_demo/actions/workflows/ci.yml/badge.svg)](https://github.com/luobeibei0710/quran_offline_demo/actions/workflows/ci.yml)

端侧**全离线**的《古兰经》诵读识别 Demo（Flutter）：麦克风实时采集 → ONNX 声学模型推理 →
CTC 解码 → 经文约束匹配，实时给出「正在诵读第几章第几节」并渲染对应标准经文；另附
「原文 / 转写」逐词比对页，用于核对识别质量。**音频不出设备**。

本仓库是验证工程：先确认端侧识别链路与精度是否达标，再考虑移植到正式项目。
Android 与 iOS 共用同一套 Dart 算法层，平台差异只在「调 ONNX Runtime 推理」这一层。

> **当前产品首页是「广播识别」**（`lib/broadcast/`）：外部广播收音 → 离线 ASR →
> **独立三章新库**（开端章 / 王权章 / 纯洁章，41 节）匹配 → ML Kit 端侧翻译 → 本地历史。
> 旧 Demo（实时跟读、语料校核、流式诊断）保留为**开发诊断**，入口在首页右上角扳手图标。
> 广播功能的实际交付范围、可复现证据与**未验收项**见
> [实施交付记录](docs/broadcast-implementation-20260921.md)。

## 功能特性

- **全离线**：声学模型、词表、经文库都在应用内，推理全部在本机完成；
- **广播识别（新首页）**：三栏显示「实际 ASR 转写 / 匹配经文 / 目标译文」，三类文本各自标注来源，
  机器翻译不会被标成校订译本；记录持久化，重启仍在；
- **独立全经语料库**：广播功能只检索自己的全经 6236 节语料（Tanzil 快照 + 独立生成的
  CTC token 表），检索不到就明确显示未匹配，**不回退旧 6236 节库**
  （有自动化测试证明它不读取旧库文件）；
- **62 种语言权威译本**：匹配到经文后查**人工译本**表（中文马坚、英文 Saheeh International
  等，均为 QuranEnc 授权，界面显示署名与版本），未匹配的解说内容才走 ML Kit 机器翻译；
- **实时跟读**：滑窗流式识别 + 稳定锁定，界面实时显示章节、标准经文、置信度与词进度；
- **6236 节全文召回 + CTC 约束精排**：先按识别文本召回候选，再用 CTC 前向后向对数似然精排，
  而不是把问题简化成分类；
- **原文 / 转写比对**：把朗读原文与识别转写逐词对齐，给出覆盖率 / 准确率 / F1 与逐词着色；
- **语料准确度验证**：右上角进入语料列表，默认用离线实际 ASR 转写直接比对固定原文；可关闭
  「离线校核」Switch，进入旧流式章节匹配与窗口推进诊断。两种模式都不经麦克风；
- **外部阿拉伯文本兼容**：归一化时展开 Unicode Arabic Presentation Forms-A/B；Flutter 继续接收
  逻辑字符并自行塑形，不对显示文本做正向 reshape；
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
   ├─ 词级进度（CTC 强制对齐的内容区判定）→ 提词器高亮
   ├─ 能量 VAD 门控（峰值/本底信噪比）→ 过滤噪声窗口
   └─ 实际 ASR 时间拼接 + 词级对齐（动态规划）→ 原文 / 转写比对
   ↑
语料默认校核（不经麦克风）：语料 WAV → 声学暂停分段 → 实际 CTC 转写 → 与固定原文比对
语料流式诊断（Switch 关闭）：语料 WAV → 原流式会话 → 章节重建稿、匹配与窗口推进诊断
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

右上角三个入口：**语料验证**（默认离线实际 ASR + 原文比对，采集进行中不可用）、**比对结果**（本轮转写 vs 原文）、
**重置**。

主区样式与自动化行为由编译期开关控制：

| 开关 | 默认 | 说明 |
|------|------|------|
| `_showTeleprompter` | `false` | `false` = 整句经文；`true` = 逐词提词器（已读 / 当前 / 未读三态高亮 + 自动居中滚动） |
| `_builtinSamples` | 5 条 | 加载完成后自动逐条跑内置样本并汇总命中率，无需麦克风 |
| `_autoStartListening` | `false` | 加载完成后自动开麦：`--dart-define=quran_auto_start=true` |
| `_autoStopSeconds` | `0` | 自动开始后多少秒自动停止并输出 `比对预览`（0 = 不停）：`--dart-define=quran_auto_stop_seconds=160` |
| `_autoCorpus` | `false` | 加载完成后自动进入语料验证并跑一遍全部语料：`--dart-define=quran_auto_corpus=true` |

> 三个联调开关走 `--dart-define` 而非改源码，避免把联调状态误提交。
> Android 的 `input tap` 被系统禁用、iOS 模拟器无法脚本点击，无人值守验证只能靠它们。

## 语料准确度验证（不经麦克风）

默认链路：**选中语料 → 按声学暂停分段 → 模型实际 CTC 转写 → 与预先冻结的原文逐词比对**。
页面 Switch 可切到旧流式诊断，观察章节匹配、稳定事件和窗口推进。三条链路的分工是：

| | 实时（主界面） | 离线校核（默认） | 流式诊断（Switch 关闭） |
|---|---|---|---|
| 输入 | 麦克风 | 同一语料 WAV | 同一语料 WAV 按实时节奏灌入 |
| 关注点 | 收音、延迟、实时章节与进度 | 模型实际转写的准确度 | 章节匹配、稳定事件与窗口推进 |
| 输出 | 实时章节与转写 | 实际 ASR 词、容错 F1/P/R、严格 WER | 章节重建稿与章节召回诊断 |

真机实测中麦克风外放收音的 RMS 常在 0.003~0.026（接近底噪）而被 VAD 挡掉，比对结果反映的是收音
而不是算法；离线语料路径用于把抓音与模型实际转写分开验证。

用法：

1. 主界面右上角「语料验证」→ 语料列表（**内置多节连续诵读** + 设备上的自定义语料）；默认打开
   「离线校核」；
2. 点一条即开始离线实际 ASR：按 20 ms RMS 找声学暂停并在暂停中点切段；连续低能量至少 0.35 s，
   阈值为 `max(1e-5, 中位 RMS × 0.4)`，每段至少 2 s、尾段至少 1 s。无足够暂停且超过 30 s 时，
   使用 30 s 窗口、8 s 重叠的有界回退；
3. 跑完**自动进入「原文 / 转写」比对页**：原文 = 该语料的经文库标准经文（内置语料）或你提供的
   原文（自定义语料），转写 = 模型实际输出；返回列表后保留 F1 与结论；
4. 右上角「全部跑一遍」批量校核，逐条要求容错 F1、准确率、覆盖率均 ≥0.9；日志同时单列严格 WER；
5. 关闭「离线校核」后再运行，才会进入原来的实时节奏灌音链路并显示章节召回诊断。

### 语料来源

| 来源 | 位置 | 说明 |
|------|------|------|
| 内置语料 | `assets/quran_offline/corpus/`（由 `manifest.json` 描述） | `bash tools/quran_offline/download_corpus.sh` 从 Quran.com CDN 取逐节诵读、拼接成 16 kHz 单声道 WAV；清单用 `includesBismillah` 预先声明音频是否包含太斯米，评测不会按预测结果择优；**音频与模型一样不入版本库**，clone 后需先跑该脚本 |
| 设备语料 | 应用私有目录 `files/corpus/*.wav` | 可有同名 `.txt` 作为原文；无 txt 时按文件名 `corpus_SSS_AAA_BBB.wav` 的章节区间取经文库原文 |

默认三段内置语料（短节连读 / 中长 / 长）：

| 语料 | 节数 | 原文词数 | 时长 |
|------|------|----------|------|
| `36:1-5` | 5 | 12 | 28 s |
| `55:1-13` | 13 | 43 | 87 s |
| `67:1-11` | 11 | 122 | 159 s |

### 转写稿口径（关键）

默认离线校核的转写稿是**模型实际 CTC 输出**。暂停切段互不重叠；超过 30 s 的无停顿段才用带时间戳的
重叠窗口拼接。转写器只接收音频、模型输出和词表，不查询期望章节或参考原文。

旧流式诊断的「转写稿」仍是**稳定命中章节的标准经文重建稿**，不是逐词 ASR。它保留用于分析章节
误匹配、稳定事件和窗口推进，不作为当前实际 ASR 准确度结论。旧链路曾因窗口重复覆盖而把 47 词语料
累积成 150 个原始输出词、126 词语料累积成 1258 词，随后才改用章节重建稿；这是历史诊断口径。

因此页面上的指标含义是：

- **覆盖率 / 准确率 / F1**：沿用容错词对齐，近似词计半分；这组数值用于当前“优秀 ≥0.90”门禁；
- **严格 WER**：归一化后按词精确计算替换、缺失和多余，不等于“90% 严格词准确率”；
- **章节命中**：仅属于关闭 Switch 后的旧流式诊断，不与默认离线实际 ASR 的 F1 混为同一口径。

### 当前离线实际 ASR 基准（主机与 Android 真机均已验）

| 语料 | 固定参考 | F1 | 准确率 P | 覆盖率 R | 严格 WER |
|------|----------|----|----------|----------|----------|
| `36:1-5` | 12 词 | 0.958333 | 0.958333 | 0.958333 | 0.166667 |
| `55:1-13` | 43 词 | 0.976744 | 0.976744 | 0.976744 | 0.139535 |
| `67:1-11` | 122 词 | 0.967213 | 0.967213 | 0.967213 | 0.163934 |

三条均达到容错 F1/P/R ≥0.9。这里的严格 WER 已单独列出，不能把 F1/P/R 解读成严格 90% 词准确率。
本表已在主机与 Redmi Android 16 真机分别复现，三段结果一致；真机处理约 0.9/2.6/4.9 秒，不含模型加载。完整证据见
[docs/offline-accuracy-20260920.md](docs/offline-accuracy-20260920.md)。

### 历史流式章节重建诊断（旧口径，保留作回归）

旧链路在 Redmi 24117RK2CC / Android 16 / arm64 上得到：`36:1-5` F1 0.744、`55:1-13` F1 0.861、
`67:1-11` F1 0.752，章节瞬时召回 25/29、整段全中 2/3。该 F1 的 hypothesis 是章节重建的标准经文，
当前表的 hypothesis 是模型实际 ASR 输出，两者**不能直接比较为算法提升幅度**。详情见
[docs/fragment-matching-experiment.md](docs/fragment-matching-experiment.md)。

### 旧流式灌音链路上的两个坑（已修并保留回归）

1. **能量门控会整段挡掉连续朗读**：语料帧能量的峰值/中位数只有 1.3~2.0，低于 `speechSnrRatio=2.5`
   （症状：灌音 0 事件、转写 0 词、F1 全 0）→ 灌音会话按「已知是朗读」建
   （`createSession(assumeSpeech: true)`），实时采集路径仍用完整门控；
2. **窗口推进在错误匹配下会裁掉真内容**：实测 159 s 语料被前移掉 155 s，越错越多
   → 现在只在冠军是**已确认序列的延续**（同节 / 往后 1~3 节 / 下一章开头）时才推进，
   且单次最多裁掉窗口的 60%。

### 一次失败的尝试（已回滚，留档）

为压掉「多余词」而试过**片段候选 + 内容帧短缺惩罚 + 信任门控 + 序列先验**四处改动，
真机跑批显示**净负收益**（`55:1-13` 覆盖率 0.926→0.649）并已全部回滚；
数据、原因与「下一步该怎么做」见 [docs/fragment-matching-experiment.md](docs/fragment-matching-experiment.md)。

### 与 Tilawa 原项目的对比

同一批语料、同一份资产、**同一套指标代码**下与 Tilawa 官方 npm 包（`@tilawa/core`，默认配置）
的实测对比见 [docs/tilawa-comparison.md](docs/tilawa-comparison.md)：Tilawa 在短句连读上更干净
（`36:1-5` F1 1.000）且更快，本项目的优势在「连读多节 + 含常见短语」的语料上
（`55:1-13` 本项目 13/13、Tilawa 锁错章 0/13）。复现脚本：`tools/tilawa_compare/` 与
`tool/tilawa_compare_metrics.dart`。

### 自定义语料（换语料不必重新构建）

需要 **16 kHz / 单声道 / 16-bit PCM 的 WAV**（引擎输入格式；mp3 请先转码）：

```bash
# 1) 转码（macOS 自带 afconvert；Windows/Linux 用 ffmpeg 等效参数）
afconvert -f WAVE -d LEI16@16000 -c 1 我的朗读.mp3 corpus_audio.wav

# 2) 推音频与（可选）原文到应用私有目录的 corpus/ 子目录
adb push corpus_audio.wav /data/local/tmp/
adb shell run-as com.llvision.quran_offline_demo mkdir -p files/corpus
adb shell run-as com.llvision.quran_offline_demo cp /data/local/tmp/corpus_audio.wav files/corpus/
adb push 我的朗读.txt /data/local/tmp/
adb shell run-as com.llvision.quran_offline_demo cp "/data/local/tmp/我的朗读.txt" files/corpus/corpus_audio.txt
```

回到语料验证页点右上角刷新即可看到「设备语料」；格式不符时列表上会直接标出原因
（例如 `采样率=44100`）并给出转码命令。

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
| 能量 VAD 门控 | `speechSnrRatio=2.5`、`speechQuietFloorRatio=2.0`、`speechRmsThreshold=0.004` | 三层判据（与绝对电平解耦）：① 峰值 ≥ 最近 2 s 帧能量中位数 × 2.5；② 峰值 ≥ 会话内「最安静窗口本底」× 2.0；③ 峰值 ≥ 0.004 的极低电平兜底。只看最近 2 s、20 ms 帧，比值判据适应不同底噪，纯静音与稳态噪声都不产出臆测结果 |
| 触发间隔 | `triggerSeconds=0.75` | 每累积约 0.75 s 尝试一次识别 |
| 窗口范围 | `minWindowSeconds=1.2`、`maxWindowSeconds=15` | 太短的窗口不识别；识别时只取最近 15 s |
| 静音收尾 | `silenceRmsThreshold=0.012`、`finalSilenceSeconds=1.5` | 连续静音 1.5 s 判定一段诵读结束 |
| 稳定锁定 | `stableRounds=2` | 连续多轮命中同一章节才标记为「稳定」，避免逐帧抖动 |
| 词级进度 | `QuranWordProgress` | 对候选序列做**帧级强制对齐**（`CtcScorer.alignFrames`），把被 CTC 挤到音频内容区之后的 token 判为「尚未念到」，取前缀词数即已读词数（`estimateReadWords`，不依赖容差常数）；序列帧数不足时回退到「前缀 CTC 打分 + 容差」（`estimateReadWordsByPrefix`） |
| 召回 + 精排 | `topK=64`、`maxSpan=4`、`spanPenalty=0.1` | 召回候选数、最大连读跨度、跨度惩罚系数（打分按帧归一化后的重标定值，见 `tools/quran_offline/tune_span_penalty.py`） |
| 已确认进度 | `commitWordRatio=0.6` | 稳定命中且已读词达该比例时提交一节到 `committedSequence`，使长诵读进度单调推进（同一节不重复提交） |
| 窗口推进 | `advanceWindowOnCommit=true`、`windowOverlapSeconds=1.0` | 提交已确认章节后，按帧级对齐的已读结束位置裁掉窗口前部音频（保留 1.0 s 重叠），使识别围绕当前位置进行而不是一直覆盖整段历史；事件带 `advancedSeconds` 便于观察 |

## 测试与 CI

```bash
flutter analyze   # 静态分析
flutter test      # 运行当前全部单元测试与页面测试
```

改动**打分口径、跨度惩罚或更换模型**后，除单测外还需跑一次真机/基准标定门禁（需要模型与官方语料，
CI 不覆盖）：

```bash
tools/quran_offline/.venv122/bin/python tools/quran_offline/tune_span_penalty.py --check
```

它会从 Dart 源码读取当前 `defaultSpanPenalty`，校验 5 条官方样本是否都命中正确单节、惩罚是否仍在
允许上界内（当前 0.1 < 上界 0.335），不符即非零退出。

测试**不依赖** `assets/quran_offline/` 下的真实资产：用例通过 `FakeAssetBundle` 注入最小化的
内存资产、通过 `ScriptedOrtRunner` 注入合成声学证据、通过 `buildSpeechLikeSamples` 生成可驱动
VAD 的类语音信号，因此 clone 后无需下载任何模型资产即可跑通全链路（真机麦克风与模型推理仍需
`flutter run` 验证）。

| 测试文件 | 覆盖内容 |
|----------|----------|
| `quran_text_test.dart` | 阿拉伯语归一化（音标/Tatweel/字母变体/BOM/Presentation Forms-A/B）、相似度与片段相似度 |
| `ctc_decoder_test.dart` | 贪心 CTC 解码、相邻重复折叠、blank 处理、词边界下标 |
| `ctc_scorer_test.dart` | 前向后向对数似然、可行性下界、最长稳定前缀选择 |
| `quran_word_progress_test.dart` | 词边界切分、已读词估算、词表与 token 词组对齐 |
| `quran_assets_test.dart` | 词表/经文/span 表解析、排序索引、缓存 |
| `quran_recognizer_test.dart` | 「解码 → 召回 → 精排」端到端、VAD 门控与流式会话行为 |
| `word_alignment_test.dart` | 词级对齐（漏词不连带判错）、一致/近似/错配/缺失/多余判定、覆盖率与 F1、结论分档 |
| `word_error_rate_test.dart` | 严格词错误率（替换/缺失/多余）与空参考边界 |
| `transcript_stitcher_test.dart` | 逐窗结果的最长重叠去重、整段已包含不重复追加、归一化后比较 |
| `timed_transcript_test.dart` | 带时间戳重叠窗口的词级拼接、边界去重与尾词保留 |
| `offline_transcriber_test.dart` | 声学暂停分段、长段有界回退、静音/空音频、取消与实际解码拼接 |
| `reference_text_test.dart` | 原文来源优先级（设备文件 → 内置资产）、空白内容回退、双来源缺失报错 |
| `quran_compare_page_test.dart` | 比对页左右两栏渲染、缺失侧占位、指标与结论、原文加载失败提示 |
| `corpus_audio_test.dart` | WAV 解码、非 44 字节头（夹其它块）仍可解、格式不符的报错与转码提示、时长换算 |
| `corpus_catalog_test.dart` | 官方语料始终在列、检测到自定义音频时追加条目、两条候选路径 |
| `corpus_runner_test.dart` | 旧流式诊断的灌音事件与章节重建稿、命中判定及取消 |
| `corpus_verify_page_test.dart` | 默认离线校核、流式诊断切换、完成后进入比对页与坏音频提示 |
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
├── broadcast/                                       广播识别（产品首页）
│   ├── broadcast_services.dart                      依赖组装与生命周期
│   ├── application/
│   │   ├── microphone_source.dart                   16 kHz 单声道收音适配
│   │   ├── utterance_segmenter.dart                 断句状态机（能量 + 静音时长）
│   │   ├── broadcast_transcriber.dart               片段实际 ASR（保留声学证据）
│   │   ├── quran_match_service.dart                 新库匹配 + 候选裁决 + 指标
│   │   ├── translation_coordinator.dart             来源策略 / 缓存 / 重试
│   │   └── broadcast_session_controller.dart        收音 → 断句 → 终稿 → 落库
│   ├── data/
│   │   ├── app_database.dart                        SQLite 建库与迁移
│   │   ├── record_repository.dart                   事务保存 / 分页 / 幂等 / 恢复
│   │   ├── broadcast_corpus.dart                    全经 6236 节 + 独立索引（数据驱动）
│   │   └── translation_catalog.dart                 62 语言译本目录与按需加载
│   ├── domain/utterance_record.dart                 三类文本 + 指标 + 译文模型
│   ├── translation/
│   │   ├── offline_translation_engine.dart          引擎契约与失败分类
│   │   ├── mlkit_translation_engine.dart            ML Kit 端侧翻译适配器
│   │   └── verse_translation_repository.dart        校订译本接口（当前为空实现）
│   └── ui/                                          首页三栏 / 历史 / 详情
└── quran_offline/
    ├── arabic_presentation_forms.dart Unicode 15.0 Presentation Forms 兼容分解表
    ├── quran_text.dart              阿拉伯语归一化与相似度
    ├── ctc_decoder.dart             贪心 CTC 解码
    ├── ctc_scorer.dart              前向后向对数似然 + 稳定前缀
    ├── quran_word_progress.dart     词边界切分 + 已读词估算（提词器）
    ├── quran_assets.dart            经文库 / 词表 / span 表加载
    ├── quran_matcher.dart           召回 + 精排 + 置信度
    ├── ort_runner.dart              推理桥接口（平台通道）
    ├── quran_recognizer.dart        一次性识别 + 流式会话（含 VAD 门控）
    ├── transcript_stitcher.dart     转写稿增量拼接（按最长词级重叠去重）
    ├── timed_transcript.dart        带时间戳窗口的实际 ASR 转写拼接
    ├── offline_transcriber.dart     声学暂停分段与有界离线实际 ASR
    ├── word_alignment.dart          词级对齐、判定阈值与比对指标
    ├── word_error_rate.dart         严格词错误率
    ├── reference_text.dart          比对原文加载（设备文件 / 内置资产）
    ├── quran_compare_page.dart      原文 / 转写逐词对照页
    ├── corpus_audio.dart            语料 WAV 解码与格式校验
    ├── corpus_catalog.dart          内置连续语料清单 + 设备自定义语料
    ├── corpus_runner.dart           旧流式章节重建诊断（按实时节奏灌音）
    ├── corpus_verify_page.dart      语料页（默认离线实际 ASR，可切旧流式诊断）
    └── quran_offline_demo_page.dart Demo 界面（Streaming 经文主区 / 可切换提词器 / 内置样本验证 / 两个入口）
android/app/src/main/java/.../QuranOrtBridge.java   ONNX Runtime 桥
android/app/src/main/kotlin/.../MainActivity.kt     通道注册
ios/Runner/QuranOrtBridge.{h,m}                     ONNX Runtime 桥
ios/Runner/AppDelegate.swift                        通道注册
test/                                               单元测试与页面冒烟测试
assets/quran_offline/                               模型与数据资产（不入版本库）
assets/quran_offline/corpus/                        语料验证用的多节连续诵读 + manifest.json
                                                    （download_corpus.sh 生成，不入版本库）
assets/quran_reference/                             比对用原文（约 3 KB，入版本库）
assets/broadcast_quran/tanzil_1_1/                  广播功能独立新库：41 节原文 + 生成的
                                                    CTC token 表 + manifest（入版本库，无音频）
resources/broadcast_quran/                          新库上游归档与音频候选（未接入安装包）
tools/quran_offline/                                资产下载、模型改造与 Python 验证脚本
tools/broadcast_quran/                              全经语料构建、CTC token 表生成、62 语言译本下载
docs/                                               验证记录、平台联调说明
.github/workflows/ci.yml                            静态分析 + 测试 + APK 构建
```

## 已知限制

- **`112:1` 跨度判定（已修复）**：内置样本 `sample_112001.wav`（`قل هو الله احد`）在 ARM 设备上
  曾被判成 `112:1-3`。根因不是「听错」（转写文本完全正确），而是打分口径：`CtcScorer` 以 token 数
  归一化，token 越多分母越大，多节连读会系统性占优，而设备端与 x86 的浮点差异把这个偏好放大成
  次序翻转。现改为**按帧数归一化**（同一段音频帧数是常数，各候选同口径），跨度惩罚随之重标定为
  `0.1`（依据 `tools/quran_offline/tune_span_penalty.py`：官方 5 条样本下正确单节与最佳跨度扩展的
  最小差距为 0.335）。修复后 Android 真机与 iOS 模拟器内置样本均为 **5/5**；按帧口径的跨平台数值
  也高度一致（同一样本 ARM 与 x86 的分数差 <5%，旧口径下曾差 10 倍）。
- **比对结果的上限受抓音质量影响（已改善）**：转写稿只包含 VAD 判定为「有语音」的窗口。原判据含
  `speechRmsThreshold=0.03` 的固定下限，会把远场/低音量收音（实测 RMS 0.003~0.026）整段挡掉；
  现改为三层判据（音频内信噪比 + 会话级最安静本底倍数 + 0.004 极低电平兜底），并加了「收音偏弱」
  自检与比对页低覆盖率提示。判据有单测覆盖（弱语音通过 / 稳态噪声拒绝 / 静音拒绝），但**真机上的
  弱信号效果尚未验证**（需设备）。
- **流式仍为工程化简版（已补进度推进与窗口推进）**：新增「已确认章节」序列（稳定命中且读满 60% 词
  时提交，同一节不重复提交、收尾不清空）与**窗口推进**（提交后按帧级对齐位置裁掉已读音频、保留
  1.0 s 重叠），识别不再一直覆盖整段历史；与 Tilawa `tracker.ts` 的剩余差距是**帧级细粒度推进**
  —— 当前只在提交节时前移窗口，未随每个词前移。
- **模型体积**：移动端加载 130 MB 改造版模型（124.6 MiB），debug APK 约 300 MB；
  正式交付需按需下载模型或只打单 ABI。
- **提词器精度未定量评估**：已读词估算改为帧级强制对齐（不依赖容差常数；回退路径仍用
  `defaultTolerance=0.35`），但高亮「滞后/超前」的量还没有按真人朗读实测；默认主区走整句样式，
  提词器逻辑保留且有单元测试覆盖。
- **置信度是启发式**：按「与次优的相对差距（15%）」映射，完美匹配与长窗口下会饱和到 1.00，
  仅用于界面提示，不参与判定。
- **iOS 真机离线验证已通过**：iPhone 17 Pro 内置样本 5/5，三段离线语料 F1/P/R 与 Android 完全一致
  （0.9583 / 0.9767 / 0.9672）；麦克风实采、实时跟踪与系统性性能测试仍未覆盖，见 [验收报告](docs/offline-ios-20260920.md)。
- **模型与测试音频未入库**：模型、`sample_*.wav` 和 `assets/quran_offline/corpus/` 下的连续语料音频
  都不进版本库。clone 后需分别准备模型/单节样本并运行 `download_corpus.sh`，否则相应验证会显示
  「识别失败」或「不可用」。
- **离线校核不能代替实时验收**：默认语料验证直接跑有界离线实际 ASR，主机三段真实音频已达到
  容错 F1/P/R ≥0.9；Android、iOS 真机均已复现三条相同指标。它不覆盖麦克风收音、实时延迟、章节锁定和词进度，
  这些仍需真机实测；关闭 Switch 后的旧流式诊断只用于章节匹配和窗口推进回归。
- **自定义语料要求 WAV**：必须是 16 kHz / 单声道 / 16-bit PCM，mp3/其它采样率会在列表上标错
  （附转码命令），暂不支持应用内解码压缩音频。
- **旧流式诊断的短句误匹配**：短窗口上引擎会稳定地误认成别的短句（实测 `2:1`「الم」、
  `1:3`「الرحمن الرحيم」反复出现），它们进转写稿后成为多余词，把 F1 从覆盖率水平拉下来；
  根因是片段/前缀匹配的缺失（Tilawa 有 `JOINT_FRAGMENT_BLEND`、`JOINT_PREFIX_*` 那套处理），
  尚未移植。旧章节重建口径下表现为「章节命中 25/29、整段全中 2/3」。此外，实时路径的 VAD
  音频内信噪比判据（峰值 ≥ 中位数 × 2.5）隐含「窗口里既有朗读也有停顿」的前提，
  实测连续朗读语料的该比值只有 1.3~2.0 —— 语料灌音已按「已知朗读」跳过该判据，
  **实时路径仍按原判据**，真人一口气不停顿地长诵时存在被挡风险（未做此场景的真人实测）。
- **广播功能尚未做真机验收（最重要的一条）**：新首页、独立三章库、SQLite 历史、ML Kit 翻译
  全部只用合成声学证据与假引擎验证过（189 个测试、双端构建通过）。**没有任何一条真实
  「外放 → 空气 → 麦克风 → 断句 → 匹配 → 翻译」的端到端记录**，实施方案里的广播验收矩阵
  （≥30 分钟、≥3 位诵读者、库外负样本、P95 延迟）一项未跑。
- **新库 CTC 排序阈值未标定**：上游 `quran_ctc_tokens.json` 的 token 分数未公开，新库 token 表
  由本仓库的确定性分词生成（单节逐 token 与官方表一致率约 21%，round-trip 正确）。因此
  `BroadcastMatchConfig` 的跨度惩罚与可信度阈值是**待标定起点**，不能当作已验收常数。
- **ML Kit 翻译未在真机运行过**：语言包需动态下载（不能随包分发），端侧翻译模型依赖
  Google Play 服务，无 GMS 设备的可用性未验证；阿→中经英语中转，中文质量必须单独评估。
  另外 ML Kit 的传递依赖不支持 arm64 模拟器，**iOS 只能真机验证**。
- **没有可分发的中英校订译本**：`curatedEdition` 路径目前恒为空实现，所有译文都标
  `machineCanonical` / `machineAsr`；未获授权前不打包、不伪造译本 ID。

## 更多文档

| 文档 | 内容 |
|------|------|
| [docs/broadcast-baseline-20260921.md](docs/broadcast-baseline-20260921.md) | 广播识别当前基线：主机/真机匹配指标、端侧性能、翻译质量样本与回归对照方法 |
| [docs/broadcast-implementation-20260921.md](docs/broadcast-implementation-20260921.md) | 广播识别与离线翻译的实际交付内容、可复现验证命令与未验收项 |
| [docs/broadcast-transcription-translation-plan-20260920.md](docs/broadcast-transcription-translation-plan-20260920.md) | 广播功能的需求与实施方案（含产品规格、数据设计与验收矩阵） |
| [docs/offline-accuracy-20260920.md](docs/offline-accuracy-20260920.md) | 默认离线实际 ASR 的设计、三段主机回放证据、指标口径与验收边界 |
| [docs/verification.md](docs/verification.md) | 各平台实测结果、Python 基准环境搭建、脚本清单与推荐工作流 |
| [docs/android-device.md](docs/android-device.md) | Android 真机联调、系统限制与替代手段、抓音质量校准 |
| [docs/ios.md](docs/ios.md) | iOS 支持说明、首次编译踩坑清单与必需配置 |

## 许可与致谢

- 本仓库代码：[MIT](LICENSE)；
- 声学模型、词表与数据表来自 [yazinsai/tilawa](https://github.com/yazinsai/tilawa) v0.2.0
  （模型 CC-BY-4.0，基座 `nvidia/stt_ar_fastconformer_hybrid_large_pcd_v1.0`），
  `tools/quran_offline/reference/*.ts` 为 Tilawa 的 MIT 参考实现，仅用于对照 Dart 侧语义；
- 经文库 `quran.json` 随 Tilawa 分发，使用前请确认其许可与标注要求。
