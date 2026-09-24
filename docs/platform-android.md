# Android 平台说明

Android 侧的推理桥与通道注册由 `quran_broadcast_sdk` 插件提供，消费应用无需修改 `MainActivity`。

| 文件 | 职责 |
|------|------|
| `packages/quran_broadcast_sdk/android/src/main/java/com/llvision/quran_broadcast_sdk/QuranOrtBridge.java` | 单例 ORT 桥（`synchronized`） |
| `packages/quran_broadcast_sdk/android/src/main/kotlin/com/llvision/quran_broadcast_sdk/QuranBroadcastSdkPlugin.kt` | 自动注册 `quran_offline/ort` 与 `quran_offline/screen` 通道，串行执行推理 |
| `packages/quran_broadcast_sdk/android/build.gradle` | 固定 ORT 1.22.0 与 Java/Kotlin 17 |

## 1. 构建配置

| 项 | 值 |
|----|-----|
| `applicationId` / `namespace` | `com.llvision.quran_offline_demo` |
| `minSdk` | 26 |
| 插件 `compileSdk` | 36（消费工程需安装 Android SDK Platform 36） |
| 宿主 `compileSdk` / `targetSdk` | 随宿主 Flutter 模板；本仓库使用 36 |
| NDK | `29.0.14206865`（显式指定，见下） |
| Java / Kotlin | 17 |
| 依赖 | 插件声明 `com.microsoft.onnxruntime:onnxruntime-android:1.22.0` |
| 权限 | `android.permission.RECORD_AUDIO`（唯一运行时权限） |

NDK 版本显式指定是因为它直接影响推理是否可用：**必须与离线基准验证过的版本一致**，
否则会出现推理阶段卡死之类的环境问题。改动前请先重跑
[离线语料准确度](offline-accuracy.md) 的三段门禁。

## 2. 构建与安装

```bash
# 只出 arm64 产物（debug 包体积大：模型 ~125 MB + token 表 ~43 MB + 译本 ~89 MB）
flutter build apk --debug --target-platform android-arm64
adb install -r --no-streaming build/app/outputs/flutter-apk/app-debug.apk

# 抓端侧日志
adb logcat -d | grep -E "QuranOrtBridge|\[Broadcast\]|QuranDemo|QuranCorpus"
```

多设备时用 `-s <SERIAL>` 指定目标设备（`adb devices` 查询）。
`--no-streaming` 在安装大包时可避免部分设备的中断问题。

## 3. 系统限制与替代手段

以下调试手段会被系统拒绝，不必尝试：

| 手段 | 现象 |
|------|------|
| `pm clear` | 拒绝 |
| `pm grant` | 拒绝 |
| `input tap` / `input keyevent`（含 26/126/224） | 拒绝（应用无 `INJECT_EVENTS` 权限） |
| `settings put global` / `system` / `secure` | 拒绝（无 `WRITE_SECURE_SETTINGS`） |
| `service call power …`（远程点亮屏幕） | 拒绝（无 `DEVICE_POWER`） |
| `cmd media_session dispatch play`（让系统播放器开播） | 可拉起 `com.miui.player`，但 `PlaybackState` 停在 `NONE(0)`，不会真正播放 |

因此**页面自动化点击在 Android 上不可用**，无人值守验证只能靠编译期开关。
此外，息屏会让应用退到后台，而 Android 9 起后台 UID 的麦克风被 `audioserver` 静音——
实测此时 `MicrophoneCaptureSource` 拿到的 PCM **RMS 与 peak 均为 0.0000**，
预览全部退化为未匹配。所以**超过几分钟的连续收音必须有人在设备旁保持亮屏**。

| 开关 | 默认 | 作用 |
|------|------|------|
| `--dart-define=quran_auto_start=true` | false | 开发诊断页内置样本验证结束后自动开麦，用于「播放已知音频 → 手机收音」 |
| `--dart-define=quran_auto_stop_seconds=160` | 0 | 到点自动停止识别并输出一行 `比对预览`（0 = 不停） |
| `--dart-define=quran_auto_corpus=true` | false | 加载完成后自动进入语料页并跑默认离线校核 |
| `--dart-define=quran_headless_corpus=true` | false | 无界面验收入口（不依赖渲染帧），打印 `OFFLINE_RESULT` / `OFFLINE_COMPLETE` |
| `--dart-define=quran_auto_run_seconds=2100` | 0 | 广播首页：依赖就绪后自动开麦，到点自动停止（仅 Debug 包），期间阻止息屏 |
| `--dart-define=quran_dump_pcm=true` | false | 把麦克风 PCM16 写入应用私有外部目录 `mic_<ts>.pcm`，上限 200 MB |
| `--dart-define=quran_latency_trace=true` | false | 输出 `[BroadcastLatencyTrace]` 结构化时延事件 |

普通交付包不带任何上述开关。

> 若设备息屏导致页面自动化停住，用 `quran_headless_corpus=true` 的入口跑验收，
> 具体命令与结果见 [离线语料准确度 §4.2](offline-accuracy.md#42-真机无头验收入口)。

## 4. 日志关键字

| 关键字 | 出处 |
|--------|------|
| `QuranOrtBridge` | 原生推理桥（模型加载、推理异常） |
| `[Broadcast]` | 广播会话（断句、匹配、落库、翻译调度） |
| `内置样本验证完成` | 开发诊断页的内置样本自测（`命中 5/5`） |
| `麦克风 RMS` | 实时链路电平（回调每 20 块输出一次） |
| `收音偏弱` | 采集 6 s 峰值低于 `0.02` 时的自检提示 |
| `比对预览` | 停止识别后输出的一行比对摘要 |
| `OFFLINE_RESULT` / `OFFLINE_COMPLETE` | 无头验收入口 |
| `开始离线校核` / `固定参考` / `离线实际转写` / `严格WER` | 语料页默认离线校核 |
| `开始灌音` / `稳定` / `已确认` | 关闭「离线校核」Switch 后的旧流式诊断 |

`麦克风 RMS` 恒为 0 通常是两种情况：授权只选了「仅本次允许」且已过期，
或系统麦克风隐私开关被关闭。

## 5. 抓音质量与阈值校准（开发诊断的实时链路）

本节只针对**开发诊断页的麦克风实时链路**；广播首页使用自己的断句状态机，
离线校核与无头验收直接读 WAV，都不经过这套判据。

实时比对结果的上限由抓音质量决定：转写稿只包含判定为「有语音」的窗口。
实测用 Mac 外放（系统音量 50 / 85）+ 手机收音时，手机端 RMS 仅 0.003~0.026
（接近 0.012~0.035 的底噪），多数窗口被门控跳过，159 s 音频只转写出 33 词、F1 0.051。

为此语音门控已改为**三层判据**，与绝对电平解耦：

| 判据 | 默认值 | 含义 |
|------|--------|------|
| 音频内信噪比 | `speechSnrRatio = 2.5` | 峰值（20 ms 帧能量 90 分位）≥ 最近 2 s 中位数 × 2.5 |
| 会话级本底倍数 | `speechQuietFloorRatio = 2.0` | 峰值 ≥ 会话内「最安静窗口本底」× 2.0 |
| 极低电平兜底 | `speechRmsThreshold = 0.004` | 排除纯数值噪声 |

判据与绝对电平解耦后，远场 / 低音量收音也能过门；稳态噪声仍被前两项拒绝
（实测底噪峰值/中位数 ≈ 1.1）。

App 侧另有两道自检：采集 2 s 无电平 → 提示检查权限；采集 6 s 峰值低于 `0.02` →
提示「收音偏弱，请靠近音源或提高音量」。比对页在转写覆盖率低于 `0.35` 时标注「指标仅供参考」。
联调时先看日志里的 `麦克风 RMS` 与这两条提示。

## 6. 数据推送（换语料免重新构建）

### 6.1 自定义语料（16 kHz / 单声道 / 16-bit PCM WAV）

```bash
# 转码（macOS 自带 afconvert；Windows/Linux 用 ffmpeg 等效参数）
afconvert -f WAVE -d LEI16@16000 -c 1 我的朗读.mp3 corpus_audio.wav

adb push corpus_audio.wav /data/local/tmp/
adb shell run-as com.llvision.quran_offline_demo mkdir -p files/corpus
adb shell run-as com.llvision.quran_offline_demo cp /data/local/tmp/corpus_audio.wav files/corpus/

# 可选：同名 .txt 作为原文
adb push 我的朗读.txt /data/local/tmp/
adb shell run-as com.llvision.quran_offline_demo cp "/data/local/tmp/我的朗读.txt" files/corpus/corpus_audio.txt
```

回到语料页点右上角刷新即可看到「设备语料」；格式不符时列表会直接标出原因
（例如 `采样率=44100`）并给出转码命令。无 `.txt` 时按文件名 `corpus_SSS_AAA_BBB.wav`
的章节区间取经文库原文。

### 6.2 比对页原文（开发诊断）

```bash
adb push 原文.txt /data/local/tmp/reference_text.txt
adb shell run-as com.llvision.quran_offline_demo \
  cp /data/local/tmp/reference_text.txt files/reference_text.txt
```

`run-as` 仅对 debug 包有效；推送后回到比对页点右上角刷新即可生效。
未推送时使用内置资产 `assets/quran_reference/reference_text.txt`。

### 6.3 数据库快照

```bash
adb -s <SERIAL> exec-out run-as com.llvision.quran_offline_demo \
  cat files/broadcast_quran.db > /tmp/snap.db
```

查询语句见 [真机验收记录 §3.1](device-verification.md#31-数据库快照)。
