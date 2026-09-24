# 验收证据（公开摘要与机器可读汇总）

本目录公开经检查的汇总数据和脱敏说明。原始设备日志、麦克风录音与本地路径仅保存在执行者设备上，不提交到公开仓库。人读的说明见
[离线语料准确度](../offline-accuracy.md) 与 [真机验收记录](../device-verification.md)。

## 离线语料准确度（不经麦克风）

| 文件 | 内容 | 对应环境 |
|------|------|----------|
| `offline-accuracy-host.json` | 三段内置语料的逐段起止时间、原始模型转写文本、参考词数、指标 | 主机 ORT 1.22（`host_ort_server.py`） |
| `offline-accuracy-android.json` | 三段语料的 F1 / P / R / 严格 WER / 词数 / 分段数 / 耗时 | Redmi 24117RK2CC / Android 16 / arm64 |
| `offline-accuracy-ios.json` | 同上，另含源码指纹、模型 SHA-256、与 Android 的逐项差值 | iPhone 17 Pro / iOS 26.6 |
| `offline-accuracy-ios-console.txt` | iOS 真机控制台原始日志，仅本地留存（含 `OFFLINE_COMPLETE passed=3 total=3`） | iPhone 17 Pro / iOS 26.6 |

## 真机全经连续播放

| 文件 | 内容 |
|------|------|
| `full-run-20260921-summary.json` | 本轮汇总：42 条记录、状态分布、覆盖章节、时间窗、APK md5、崩溃数 |
| `full-run-20260921-records.csv` | 逐条记录：序号、匹配节范围、状态、F1、严格 WER、译文来源 |
| `full-run-20260921-translations.csv` | 译文来源与 `edition_id` 分布 |

口径与读法见 [真机验收记录](../device-verification.md)；**该轮验收矩阵未补齐**，
不要把这些数据当作「已验收」。

## 三栏新版 Android 局部播放

| 文件 | 内容 |
|------|------|
| [live-three-column-android-2026-09-23.md](live-three-column-android-2026-09-23.md) | 第 12 章约 452 秒试播的延迟、节号、译文来源与未解决点 |
| `live-three-column-android-2026-09-23.txt` | 同轮 `[Broadcast]` 与 `[BroadcastLatency]` 原始应用事件，仅本地留存 |

这轮仅是新版局部 Android 实测，不能替代完整播放或 iOS 广播链路验收。

## 三栏同步 iOS 真机（2026-09-23）

| 文件 | 内容 |
|------|------|
| [live-three-column-ios-2026-09-23.md](live-three-column-ios-2026-09-23.md) | iPhone 17 Pro / iOS 26.6 上首次跑通广播链路：本轮修掉的三个 iOS 阻塞点、指标与未覆盖范围 |
| `live-three-column-ios-2026-09-23.txt` | 同轮 `[Broadcast]` 与 `[BroadcastLatency]` 原始应用事件，仅本地留存 |

音源是近场外放的第 78 章诵读，与 Android 那份第 12 章数字音源**不可直接对比**。

## 三栏同步第二轮（2026-09-23）

| 文件 | 内容 |
|------|------|
| [codebuddy-three-column-followup-2026-09-23.md](codebuddy-three-column-followup-2026-09-23.md) | 第二轮：基线、数字音源对照、诊断埋点、候选统计、widget 回归与未验证项 |
| [digital-final-vs-preview-2026-09-23.json](digital-final-vs-preview-2026-09-23.json) | 同一份 `012.mp3` 数字音频上，终稿分段路径 / 12 秒预览 / 30 秒整窗单次的对照明细 |
| [preview-candidate-stats-2026-09-23.json](preview-candidate-stats-2026-09-23.json) | 由上一轮原始日志算出的候选重叠、跨章误提示与抖动统计 |

第二轮没有取得新的有效真机录音，`codebuddy-three-column-followup` 里的
Android ≥30 分钟与 iOS 两项状态均为**未验证**。

## 口径提醒

- `f1` / `precision` / `recall` 是**容错口径**（近似词计半分），
  `strictWer` 是精确词口径，两者不可互相换算；
- `seconds` / 耗时字段是**单次观测或分位数**，不是基准；
  主机侧的耗时包含推理缓存命中，不能用于宣称端侧性能；
- Android 为 debug 包、iOS 为 release 包，耗时不可跨平台比较。

## 命名约定

1. 环境或基线类数据用「主题-环境」命名（如 `offline-accuracy-android.json`）；
   单次运行类数据用「主题-日期」命名（如 `full-run-20260921-records.csv`），
   便于同一主题多轮运行并存与比较；
2. 同类数据保持同一结构（字段名与单位一致），便于脚本比较；
3. 只有真实跑出来的数据才放进来；未验证的维度在
   [真机验收记录](../device-verification.md) 里显式标注状态，
   **不要把「部分通过」写成「通过」**。
