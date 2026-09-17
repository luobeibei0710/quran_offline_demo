# Android 真机联调备忘

参考设备：Redmi 24117RK2CC / Android 16（API 36）/ arm64-v8a。

## 构建与安装

```bash
# 只出 arm64 产物（debug 包约 300 MB：130 MB 模型 + ONNX Runtime 库 + 测试样本）
flutter build apk --debug --target-platform android-arm64
adb install -r build/app/outputs/flutter-apk/app-debug.apk

# 抓端侧日志
adb logcat -d | grep -E "QuranDemo|QuranOrtBridge"
```

## 系统限制（小米 HyperOS 实测）

以下调试手段会被系统拒绝，不必尝试：`pm clear`、`pm grant`、`input tap`（应用无
`INJECT_EVENTS` 权限）。替代手段：

| 手段 | 说明 |
|------|------|
| `--dart-define=quran_auto_start=true` | 内置样本验证结束后自动开麦，用于「播放已知音频 → 手机收音」的无人值守验证 |
| `--dart-define=quran_auto_stop_seconds=160` | 到点自动停止识别并输出一行 `比对预览` |
| 日志 `麦克风 RMS=x.xxxx` | 麦克风回调每 20 块输出一次；RMS 恒为 0 通常是「仅本次允许」授权已过期，或系统麦克风隐私开关关闭 |

## 抓音质量与阈值校准

比对结果的**上限由抓音质量决定**：转写稿只包含 VAD 判定为「有语音」的窗口。实测用 Mac 外放
（系统音量 50 / 85）+ 手机收音时，手机端 RMS 仅 0.003~0.026（接近 0.012~0.035 的底噪），
多数窗口被 VAD 跳过，159 s 音频只转写出 33 词、F1 0.051。

因此联调时先看 `麦克风 RMS`：正常朗读或贴近外放时，峰值应明显高于
`speechRmsThreshold=0.03`。

## 原文覆盖（换比对语料免重新构建）

```bash
adb push 原文.txt /data/local/tmp/reference_text.txt
adb shell run-as com.llvision.quran_offline_demo \
  cp /data/local/tmp/reference_text.txt files/reference_text.txt
```

`run-as` 仅对 debug 包有效；推送后回到比对页点右上角刷新即可生效。
