# Android 真机联调备忘

参考设备：Redmi 24117RK2CC / Android 16（API 36）/ arm64-v8a。

> **入口已变化（2026-09-21）**：应用启动后进入的是**广播识别首页**
> （`lib/broadcast/`，独立三章新库 + ML Kit 翻译 + SQLite 历史），它**不执行**内置样本
> 自测。本文下面的验收清单针对旧 Demo，请点首页右上角的**扳手图标**进入「开发诊断」后执行。
> 广播功能自身的验收与未验收项见
> [实施交付记录](broadcast-implementation-20260921.md)。

## 构建与安装

```bash
# 只出 arm64 产物（debug 包约 300 MB：130 MB 模型 + ONNX Runtime 库 + 测试样本）
flutter build apk --debug --target-platform android-arm64
adb install -r --no-streaming build/app/outputs/flutter-apk/app-debug.apk

# 抓端侧日志
adb logcat -d | grep -E "QuranDemo|QuranOrtBridge"
```

## 验收清单（真机）

```bash
flutter build apk --debug --target-platform android-arm64
adb install -r --no-streaming build/app/outputs/flutter-apk/app-debug.apk
adb logcat -c && adb shell am start -n com.llvision.quran_offline_demo/.MainActivity
adb logcat -d | grep -E "QuranDemo|QuranOrtBridge"
```

| # | 操作 | 期望 |
|---|------|------|
| 1 | 启动应用 → 点右上角**扳手图标**进入「开发诊断」 | 经文库 → 模型加载完成，自动跑内置样本自测，末尾 `内置样本验证完成：命中 5/5`（产品首页不再跑自测） |
| 2 | 点「开始识别」后保持安静约 30 s | 不产生识别事件（VAD 门控），日志只有周期性的 `麦克风 RMS=...` |
| 3 | 正常朗读任意一节 | 章节栏实时给出 `surah:ayah`，主区渲染对应经文，置信度/声学分/词进度随之更新 |
| 4 | 连续朗读多节（音源贴近手机） | 日志出现 `稳定 X:Y` 与 `已确认 X:Y（累计 N 节，窗口前移 M.Ms）`，章节不回跳 |
| 5 | 点「停止识别」 | 日志输出一行 `比对预览 …`；AppBar 比对图标可进入「左原文 / 右转写」对照页 |
| 6 | 故意用远场小声朗读 | 采集 6 s 后日志出现「收音偏弱」提示；比对页在覆盖率 < 0.35 时显示提示条 |
| 7 | 右上角「语料验证」→ 保持「离线校核」Switch 打开 → 点一条内置语料 | 日志显示固定参考、声学分段与离线实际转写，跑完自动进入比对页；比对页显示 F1/P/R 与严格 WER。主机与 Android 三段均已 ≥0.9 |
| 8 | 保持「离线校核」打开 → 右上角「全部跑一遍」 | 预期日志出现 `F1/准确率/覆盖率均≥0.9：3/3 条（离线实际转写）`；相同引擎的真机无界面验收已输出 `OFFLINE_COMPLETE passed=3 total=3` |
| 9 | 关闭「离线校核」→ 点一条语料 | 进入旧流式章节重建诊断，列表显示稳定/已确认事件、章节命中与诊断 F1；该口径只回归章节匹配和窗口推进 |

日志关键字：`内置样本验证完成`、`麦克风 RMS`、`已确认`、`比对预览`、`收音偏弱`、`QuranOrtBridge`、
`QuranCorpus`（默认离线校核：`开始离线校核` / `固定参考` / `离线实际转写` / `严格WER` /
`语料验证完成`；关闭 Switch 后的旧流式诊断仍会出现 `开始灌音` / `稳定` / `已确认`）。

无人值守跑默认离线校核时，编译命令必须显式带自动语料开关：

```bash
flutter build apk --debug --target-platform android-arm64 --dart-define=quran_auto_corpus=true
adb install -r --no-streaming build/app/outputs/flutter-apk/app-debug.apk
adb logcat -c && adb shell am start -n com.llvision.quran_offline_demo/.MainActivity
adb logcat -d | grep -E "QuranCorpus"
```

内置语料原文由 `manifest.json` 的 `includesBismillah` 在推理前固定，不会根据预测结果选择较高 F1
版本。当前主机真实音频回放的三条 F1/P/R 分别为 0.958333、0.976744、0.967213；严格 WER 分别为
0.166667、0.139535、0.163934。两组指标口径不同；Android 真机已复现相同结果，处理约 0.9/2.6/4.9 秒（不含加载）。完整证据与边界见
[offline-accuracy-20260920.md](offline-accuracy-20260920.md)。

## 系统限制（小米 HyperOS 实测）

如果设备息屏使页面自动化停住，可用 `--dart-define=quran_headless_corpus=true` 构建同一离线引擎的
无界面验收入口，查看 `OFFLINE_RESULT` 与 `OFFLINE_COMPLETE`。本轮已真机完成 3/3；
具体命令与结果见 [offline-accuracy-20260920.md](offline-accuracy-20260920.md)。普通交付包不带此开关。

以下调试手段会被系统拒绝，不必尝试：`pm clear`、`pm grant`、`input tap`（应用无
`INJECT_EVENTS` 权限）。替代手段：

| 手段 | 说明 |
|------|------|
| `--dart-define=quran_auto_start=true` | 内置样本验证结束后自动开麦，用于「播放已知音频 → 手机收音」的无人值守验证 |
| `--dart-define=quran_auto_stop_seconds=160` | 到点自动停止识别并输出一行 `比对预览` |
| `--dart-define=quran_auto_corpus=true` | 加载完成后自动进入语料页并跑默认离线校核；构建后用 `adb install -r --no-streaming` 安装大包 |
| 日志 `麦克风 RMS=x.xxxx` | 麦克风回调每 20 块输出一次；RMS 恒为 0 通常是「仅本次允许」授权已过期，或系统麦克风隐私开关关闭 |

## 抓音质量与阈值校准

本节只针对主界面的**麦克风实时链路**；默认语料离线校核直接读取 WAV，不经过麦克风与这套实时 VAD。
实时比对结果的**上限由抓音质量决定**：转写稿只包含 VAD 判定为「有语音」的窗口。实测用 Mac 外放
（系统音量 50 / 85）+ 手机收音时，手机端 RMS 仅 0.003~0.026（接近 0.012~0.035 的底噪），
多数窗口被 VAD 跳过，159 s 音频只转写出 33 词、F1 0.051。

为此语音门控已改为**三层判据**（不再依赖固定的 0.03 下限）：

| 判据 | 默认值 | 含义 |
|------|--------|------|
| 音频内信噪比 | `speechSnrRatio=2.5` | 峰值（20 ms 帧能量 90 分位）≥ 最近 2 s 中位数 × 2.5 |
| 会话级本底倍数 | `speechQuietFloorRatio=2.0` | 峰值 ≥ 会话内「最安静窗口本底」× 2.0 |
| 极低电平兜底 | `speechRmsThreshold=0.004` | 排除纯数值噪声 |

判据与绝对电平解耦后，远场 / 低音量收音也能过门；稳态噪声仍被前两项拒绝（实测底噪
峰值/中位数 ≈ 1.1）。

App 侧还加了两道自检：采集 2 s 无电平 → 提示检查权限；采集 6 s 峰值低于 `0.02` → 提示
「收音偏弱，请靠近音源或提高音量」。联调时先看日志里的 `麦克风 RMS` 与这两条提示。
比对页在转写覆盖率低于 0.35 时也会标注「指标仅供参考」。

## 原文覆盖（换比对语料免重新构建）

```bash
adb push 原文.txt /data/local/tmp/reference_text.txt
adb shell run-as com.llvision.quran_offline_demo \
  cp /data/local/tmp/reference_text.txt files/reference_text.txt
```

`run-as` 仅对 debug 包有效；推送后回到比对页点右上角刷新即可生效。
