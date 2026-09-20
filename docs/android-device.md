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

## 验收清单（真机）

```bash
flutter build apk --debug --target-platform android-arm64
adb install -r build/app/outputs/flutter-apk/app-debug.apk
adb logcat -c && adb shell am start -n com.llvision.quran_offline_demo/.MainActivity
adb logcat -d | grep -E "QuranDemo|QuranOrtBridge"
```

| # | 操作 | 期望 |
|---|------|------|
| 1 | 启动应用（不用点按） | 经文库 → 模型加载完成，自动跑内置样本自测，末尾 `内置样本验证完成：命中 5/5` |
| 2 | 点「开始识别」后保持安静约 30 s | 不产生识别事件（VAD 门控），日志只有周期性的 `麦克风 RMS=...` |
| 3 | 正常朗读任意一节 | 章节栏实时给出 `surah:ayah`，主区渲染对应经文，置信度/声学分/词进度随之更新 |
| 4 | 连续朗读多节（音源贴近手机） | 日志出现 `稳定 X:Y` 与 `已确认 X:Y（累计 N 节，窗口前移 M.Ms）`，章节不回跳 |
| 5 | 点「停止识别」 | 日志输出一行 `比对预览 …`；AppBar 比对图标可进入「左原文 / 右转写」对照页 |
| 6 | 故意用远场小声朗读 | 采集 6 s 后日志出现「收音偏弱」提示；比对页在覆盖率 < 0.35 时显示提示条 |
| 7 | 右上角「语料验证」→ 点一条内置语料（如 `36:1-5`，28 s） | 列表显示进度与稳定/已确认事件，跑完自动进入比对页；返回后该条保留 `章节 n/m` 与 F1（预期覆盖率 1.000、F1 ≈0.74） |
| 8 | 语料验证页右上角「全部跑一遍」（约 8~12 分钟） | 日志出现 `语料验证完成：章节命中 25/29 节；整段全中 2/3 条`（长语料耗时主要花在推理，见 README「已知限制」） |

日志关键字：`内置样本验证完成`、`麦克风 RMS`、`已确认`、`比对预览`、`收音偏弱`、`QuranOrtBridge`、
`QuranCorpus`（语料验证：`开始灌音` / `转写拼接` / `原文采用变体` / `比对` / `语料验证完成`）。

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
