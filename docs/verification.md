# 验证记录

本工程的结论均来自实测。下表的「结果」都是当前代码在对应环境跑出来的，复现方式见各节说明。

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
2. 再 `flutter build apk --debug --target-platform android-arm64`（增量约 20~40 s）；
3. `adb install -r` 后用 `adb logcat` 看内置样本自测的命中率与诊断行。

## tools/quran_offline 脚本一览

| 脚本 | 用途 |
|------|------|
| `download_assets.sh` | 下载原版模型与数据表，含 sha256 校验（兼容 `shasum`/`sha256sum`） |
| `convert_for_ort122.py` | 把原版模型改造为 ORT 1.22 可加载版本 |
| `verify_conversion.py` | 对比改造前后模型的推理输出，验证等价性 |
| `verify_corpus.py` | 用 Tilawa 官方测试语料（文件名即答案）验证声学层准确率 |
| `check_sample.py` | 长音频流式分段识别，输出各时间段章节（与真机结果对照） |
| `diag_ctc.py` | 对比同一音频下不同候选 token 序列的 CTC 分数 |
| `tune_span_penalty.py` | 跨度惩罚标定与核验：对比「正确单节」与跨度扩展在两种归一化口径下的分数与冠军选择 |
| `poc_transcribe.py` | P0 验证：单次推理 + 贪心解码 |
| `poc_match.py` | P1 验证：文本召回 + CTC 约束精排 |
| `reference/` | Tilawa 侧 TypeScript 参考实现（对照语义用） |
