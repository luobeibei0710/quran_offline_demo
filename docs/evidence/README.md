# 验收证据（机器可读）

本目录存放可复现的验收原始数据。人读的说明见
[离线语料准确度](../offline-accuracy.md) 与 [真机验收记录](../device-verification.md)。

| 文件 | 内容 | 对应环境 |
|------|------|----------|
| `offline-accuracy-host.json` | 三段内置语料的逐段起止时间、原始模型转写文本、参考词数、指标 | 主机 ORT 1.22（`host_ort_server.py`） |
| `offline-accuracy-android.json` | 三段语料的 F1 / P / R / 严格 WER / 词数 / 分段数 / 耗时 | Redmi 24117RK2CC / Android 16 / arm64 |
| `offline-accuracy-ios.json` | 同上，另含源码指纹、模型 SHA-256、与 Android 的逐项差值 | iPhone 17 Pro / iOS 26.6 |
| `offline-accuracy-ios-console.txt` | iOS 真机控制台原始日志（含 `OFFLINE_COMPLETE passed=3 total=3`） | iPhone 17 Pro / iOS 26.6 |

## 口径提醒

- 这些文件里的 `f1` / `precision` / `recall` 是**容错口径**（近似词计半分），
  `strictWer` 是精确词口径，两者不可互相换算；
- `seconds` 字段是**单次观测**，不是性能基准；
  主机侧的耗时包含推理缓存命中，不能用于宣称端侧性能；
- Android 为 debug 包、iOS 为 release 包，耗时不可跨平台比较。

## 新增证据的约定

1. 文件名用「主题-环境」的稳定命名，**不要把日期写进文件名**；
2. 同类数据保持同一结构，便于脚本比较；
3. 只有真实跑出来的数据才放进来，未验证的维度在
   [真机验收记录](../device-verification.md) 里显式标注「待补充」。
