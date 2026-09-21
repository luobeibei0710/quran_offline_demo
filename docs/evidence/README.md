# 验收证据（机器可读）

本目录存放可复现的验收原始数据。人读的说明见
[离线语料准确度](../offline-accuracy.md) 与 [真机验收记录](../device-verification.md)。

## 离线语料准确度（不经麦克风）

| 文件 | 内容 | 对应环境 |
|------|------|----------|
| `offline-accuracy-host.json` | 三段内置语料的逐段起止时间、原始模型转写文本、参考词数、指标 | 主机 ORT 1.22（`host_ort_server.py`） |
| `offline-accuracy-android.json` | 三段语料的 F1 / P / R / 严格 WER / 词数 / 分段数 / 耗时 | Redmi 24117RK2CC / Android 16 / arm64 |
| `offline-accuracy-ios.json` | 同上，另含源码指纹、模型 SHA-256、与 Android 的逐项差值 | iPhone 17 Pro / iOS 26.6 |
| `offline-accuracy-ios-console.txt` | iOS 真机控制台原始日志（含 `OFFLINE_COMPLETE passed=3 total=3`） | iPhone 17 Pro / iOS 26.6 |

## 真机全经连续播放

| 文件 | 内容 |
|------|------|
| `full-run-20260921-summary.json` | 本轮汇总：42 条记录、状态分布、覆盖章节、时间窗、APK md5、崩溃数 |
| `full-run-20260921-records.csv` | 逐条记录：序号、匹配节范围、状态、F1、严格 WER、译文来源 |
| `full-run-20260921-translations.csv` | 译文来源与 `edition_id` 分布 |

口径与读法见 [真机验收记录](../device-verification.md)；**该轮验收矩阵未补齐**，
不要把这些数据当作「已验收」。

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
