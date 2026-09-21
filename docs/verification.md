# 验证记录

本工程的结论均来自实测。下表的「结果」都是当前代码在对应环境跑出来的，复现方式见各节说明。

> **本文记录的是旧 Demo（实时跟读 / 语料校核 / 流式诊断）的验证结果。**
> 2026-09-21 起产品首页改为**广播识别**，旧 Demo 移到首页右上角的「开发诊断」入口；
> 广播功能的交付内容、可复现证据与**未验收项**见
> [实施交付记录](broadcast-implementation-20260921.md)。下表的旧结论仍然有效，
> 但入口路径已变化。

## Android 真机（arm64-v8a）

| 项 | 结果 |
|----|------|
| 链路贯通 | 模型加载 → 端侧推理 → CTC 解码 → 召回 → CTC 精排 → UI 显示全部可用 |
| 模型加载耗时 | 端到端 1.48 s（经文库 518 ms + 会话创建 921 ms） |
| 内置样本自测 | **5/5**（打分口径修复前为 4/5：`sample_112001.wav` 被判成 `112:1-3`） |
| 158 s 连续诵读（外放 + 手机收音） | 识别序列与音频逐节吻合：`2:4 → 2:5 → 2:6 → … → 2:10` |
| 静音误触发 | 修复前 30 s 内 12 条事件，修复后 0 条 |
| 比对链路 | 原文资产（337 词）加载 → 转写拼接 → 词级对齐 → 指标输出全部正常 |
| 已确认进度 | 事件携带单调推进的 `committedSequence`（单测覆盖提交/防重复/跨段累加；真机行为待复验） |

## iOS 真机（iPhone 17 Pro / iOS 26.6，2026-09-20）

release 构建签名安装及模型加载通过，内置样本 **5/5**，连续离线语料 **3/3**。
三段 F1/P/R 为 **0.958333 / 0.976744 / 0.967213**，与 Android 指标完全一致；严格 WER、词数及分段数也相同。
本轮补充仅在验收开关开启时转发 iOS 原生日志，`flutter analyze --no-pub` 通过。
完整指标、代码指纹、模型哈希及日志见 [iOS 真机验收报告](offline-ios-20260920.md)。
这不涵盖 iOS 麦克风实采、实时跟踪或全经泛化；严格 WER 约 14%–17%，与容错 F1 分开解释。

## iOS 模拟器（iPhone 17 Pro / iOS 26.5）

| 项 | 结果 |
|----|------|
| 链路贯通 | 编译链接通过（ObjC 桥 + ORT 1.22 XCFramework 的 arm64 模拟器切片）并正常启动 |
| 经文库加载 | 6236 节 / 词表 1025 / span 表 35717 条，1.9 s |
| 模型加载 | 3.7 s（模拟器；Android 真机 1.5 s） |
| 内置样本自测 | **5/5**，与 Android 一致（修复前双方同为 4/5，失败项均为 `112:1 → 112:1-3`）；逐条声学分为 0.005 / 0.258 / 0.721 / 0.000 / 6.155 |
| 打分口径的跨平台一致性 | 按帧口径下与 x86 Mac 的同一样本分数差 <5%（Mac：0.005 / 0.236 / 0.736 / 0.000 / 0.457）；旧按 token 口径下同一样本曾差 10 倍（45.462 vs 4.562） |
| 样本转写准确率 | 5 条样本的转写文本与经文库标准文本**逐词一致**（覆盖率 / 准确率 / F1 均为 1.000；Android 对照 0.998，差异在 `2:255` 有 1 个词近似） |
| 推理数值 | `logprobs` min=-50.788 / avg=-31.926，与 Android（-50.046 / -31.894）接近，与 x86 Mac（-43.571 / -25.123）差距明显 |
| 设备切片 | `flutter build ios --debug --no-codesign` 通过 |

> 「样本转写准确率」按比对页同口径计算：剥离太斯米前缀后用 Needleman–Wunsch 对齐，
> 词相似度 ≥0.80 记一致、≥0.50 记近似（半分），对齐结果 × 经文库标准文本。

未覆盖：模拟器麦克风授权被系统拒绝（`simctl privacy grant microphone` 无效），
因此「麦克风采集 → 流式识别 → 比对页」这条链路只在 Android 真机上验证过；详见 [ios.md](ios.md)。

## Python 基准（Mac）

| 项 | 结果 |
|----|------|
| 官方语料准确率（ORT 1.22 + 改造模型） | 5/5（文件名即标准答案） |
| 模型可用性 | 6.03 s 音频（1:1）→ 解码 `بسم الله الرحمن الرحيم`，完全正确 |
| 推理耗时 | 0.116 s（Mac CPU，6 s 音频） |
| 召回 + 精排 | 冠军 1:1，acoustic=0.074，与次优差距 1.18（区分度极大） |
| 改造等价性 | `verify_conversion.py` 逐帧 argmax 一致率 100% |

> **口径注意**：Python 脚本（`verify_corpus.py` / `poc_match.py` / `diag_ctc.py`）里的「平均 NLL」
> 按 **token 数**归一化，而 Dart 侧 `CtcScorer` 已改为按 **帧数**归一化，两者数值不可直接比较。
> 跨度判定相关结论一律以 `tune_span_penalty.py` 的「按帧」列为准（该列 = 按 token 分数 × 生效
> token 数 ÷ 帧数）。

首次使用需自建两个 venv（用途不同）：

```bash
# 模型改造与「原版模型」验证：需要 onnx（图改写）+ ORT ≥ 1.30（支持 ConvInteger）
python3.12 -m venv tools/quran_offline/.venv
tools/quran_offline/.venv/bin/pip install onnx onnxruntime numpy

# 改造版模型验证：对齐移动端实际可用的版本
python3.12 -m venv tools/quran_offline/.venv122
tools/quran_offline/.venv122/bin/pip install onnxruntime==1.22.0 numpy
```

> `convert_for_ort122.py` / `verify_conversion.py` 用 `.venv`（实测 onnxruntime 1.30.0、
> onnx 1.22.0）；`verify_corpus.py` / `check_sample.py` / `diag_ctc.py` 用 `.venv122`（onnxruntime 1.22.0）。
>
> 加载**原版**模型需 ORT ≥ 1.30（ORT 1.19 会报 `NOT_IMPLEMENTED`）；
> 改造后的 `*_ort122.onnx` 在 ORT 1.22 上即可加载。

## 推荐工作流

1. 算法改动先在 Mac 用 `.venv122` 回归（`verify_corpus.py` 应保持 5/5）；
2. 改了**打分口径、跨度惩罚或换了模型**时，再跑标定门禁（会从 Dart 源码读当前惩罚值）：

   ```bash
   tools/quran_offline/.venv122/bin/python tools/quran_offline/tune_span_penalty.py --check
   ```

   门禁校验两件事：5 条官方样本的冠军是否都等于正确单节、当前惩罚是否小于各样本算出的
   允许上界（当前 0.1 < 0.335）；不符即退出码 1。
3. 再 `flutter build apk --debug --target-platform android-arm64`（增量约 20~40 s）；
4. `adb install -r --no-streaming` 后用 `adb logcat` 看内置样本自测的命中率与诊断行。

> 门禁与语料级回归都需要**模型 + 官方语料**，两者都不入版本库（发布包也不含语料），
> 因此它们只能作为本地/发版门禁；CI 覆盖的是与真实数值无关的部分：打分口径契约、
> 门控与进度语义、页面渲染（见「测试与 CI」）。

## 准确度验证（离线实际 ASR，不经麦克风）

应用内「语料验证」页默认打开「离线校核」Switch：选中语料后，音频按声学暂停切成有界片段，
每段直接做模型实际 CTC 解码，再与运行前已冻结的原文逐词比对。关闭 Switch 才进入原来的
实时节奏灌音链路，用于观察章节匹配、稳定事件和窗口推进。也可无人值守跑默认离线校核：

```bash
bash tools/quran_offline/download_corpus.sh                    # 取内置多节语料（不入版本库）
flutter build apk --debug --target-platform android-arm64 --dart-define=quran_auto_corpus=true
adb install -r --no-streaming build/app/outputs/flutter-apk/app-debug.apk
adb logcat -c && adb shell am start -n com.llvision.quran_offline_demo/.MainActivity
adb logcat -d | grep -E "QuranCorpus"
```

内置语料的参考文本由 `manifest.json` 的 `includesBismillah` 在推理前确定；评测不会根据预测结果
在含/不含太斯米版本中选择较高 F1。离线转写器按 20 ms RMS 帧寻找连续至少 0.35 s 的低能量区，
低能量阈值为 `max(1e-5, 中位 RMS × 0.4)`，在静音中点切分；每段至少 2 s，剩余尾段至少 1 s。
没有足够暂停且连续段超过 30 s 时，才使用 30 s 窗口、8 s 重叠的有界回退并按时间戳拼接。

主机真实音频回放（2026-09-20，同一模型与三段内置语料）已验证：

| 语料 | 固定参考 | F1 | 准确率 P | 覆盖率 R | 严格 WER |
|------|----------|----|----------|----------|----------|
| `36:1-5` | 12 词 | 0.958333 | 0.958333 | 0.958333 | 0.166667 |
| `55:1-13` | 43 词 | 0.976744 | 0.976744 | 0.976744 | 0.139535 |
| `67:1-11` | 122 词 | 0.967213 | 0.967213 | 0.967213 | 0.163934 |

三条均达到容错 F1/P/R ≥0.9。F1/P/R 沿用 `WordAlignment` 的容错口径，近似词计半分；严格 WER
另按精确词计算替换、缺失和多余，因此不能把本表写成「严格词准确率超过 90%」。Android 真机已复现相同三段指标，
内置单节样本仍为 5/5；设备记录见 [offline-android-20260920.json](offline-android-20260920.json)。完整设计、原始输出与验收边界见
[offline-accuracy-20260920.md](offline-accuracy-20260920.md)。

### 历史流式章节重建诊断（旧口径）

2026-09-20 在 Redmi 24117RK2CC / Android 16 / arm64 上，旧流式诊断得到：`36:1-5` F1 0.744、
`55:1-13` F1 0.861、`67:1-11` F1 0.752，章节瞬时召回 25/29、整段全中 2/3。它的 hypothesis
是稳定命中章节的标准经文重建稿；上表的 hypothesis 是模型实际 CTC 输出，所以两组 F1
**不能直接相减或描述为同口径提升**。旧链路保留用于回归以下问题：

1. **能量门控挡掉连续朗读**：语料帧能量的峰值/中位数只有 1.3~2.0 < `speechSnrRatio=2.5`
   （症状：灌音 0 事件、F1 全 0）→ 灌音会话按「已知是朗读」建（`assumeSpeech: true`）；
2. **窗口推进在错误匹配下裁掉真内容**（159 s 语料被前移 155 s）→ 只在冠军是「已确认序列的延续」
   时才推进，且单次最多裁 60%；
3. **逐词 ASR 输出不能当长音频转写**（47 词语料拼出 150 词、126 词拼出 1258 词）→ 转写稿改取
   「稳定命中章节的标准经文、按新覆盖到的节累加」，逐词输出仅作诊断。

## 相关记录

- 默认离线实际 ASR 的设计、真实音频结果与验收边界：[offline-accuracy-20260920.md](offline-accuracy-20260920.md)
- 与 Tilawa 原项目的受控对比、误差预算（为什么上不了 0.95）：[tilawa-comparison.md](tilawa-comparison.md)
- 旧流式章节重建的一次失败尝试（片段候选/短缺惩罚/信任门控/序列先验）：[fragment-matching-experiment.md](fragment-matching-experiment.md)

## tools/quran_offline 脚本一览

| 脚本 | 用途 |
|------|------|
| `download_assets.sh` | 下载原版模型与数据表，含 sha256 校验（兼容 `shasum`/`sha256sum`） |
| `convert_for_ort122.py` | 把原版模型改造为 ORT 1.22 可加载版本 |
| `verify_conversion.py` | 对比改造前后模型的推理输出，验证等价性 |
| `verify_corpus.py` | 用 Tilawa 官方测试语料（文件名即答案）验证声学层准确率 |
| `check_sample.py` | 长音频流式分段识别，输出各时间段章节（与真机结果对照） |
| `diag_ctc.py` | 对比同一音频下不同候选 token 序列的 CTC 分数 |
| `diag_ayah_isolated.py` | 逐节孤立诊断：把每一节单独喂模型（不含滑窗/跟踪），量出「声学 + 解码 + 文本口径」天花板；`--show-errors` 打印词级差异，软化正字法后再比一次 |
| `tune_span_penalty.py` | 跨度惩罚标定与**门禁**：对比「正确单节」与跨度扩展在两种归一化口径下的分数、冠军选择与允许的惩罚上界；`--check` 不符即非零退出，惩罚值默认从 Dart 源码读取 |
| `poc_transcribe.py` | P0 验证：单次推理 + 贪心解码 |
| `poc_match.py` | P1 验证：文本召回 + CTC 约束精排 |
| `reference/` | Tilawa 侧 TypeScript 参考实现（对照语义用） |
| `../tilawa_compare/` | 用 Tilawa 官方 npm 包跑同一批语料，产出对比结果 JSON（`run_bench.mjs`） |
| `../../tool/tilawa_compare_metrics.dart` | 用本项目 `WordAlignment` 统一计算两侧指标（覆盖率 / 准确率 / F1 / 章节命中） |
| `../../tool/offline_benchmark_test.dart` | 主机回放默认离线实际 ASR，输出固定参考、F1/P/R 与严格 WER |
