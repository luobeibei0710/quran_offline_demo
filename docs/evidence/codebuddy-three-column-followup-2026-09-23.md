# CodeBuddy 续办：三栏同步第二轮验证（2026-09-23）

本文件记录接手 [`codebuddy-three-column-test-handoff-2026-09-23.md`](../codebuddy-three-column-test-handoff-2026-09-23.md)
之后完成的第二轮工作。上一轮（同日 452 秒局部试播）的证据仍在
[`live-three-column-android-2026-09-23.md`](live-three-column-android-2026-09-23.md)，
**不得与本轮混算**：本轮没有取得新的有效真机录音。

一句话结论：

> **P0 第 6 段丢词的责任被限定在输入侧**（外放拾音或设备音频链路）。数字音源走同一条
> 终稿路径时，30 秒窗口稳定识别 20–28 词并命中 `12:8-9`，而该段在真机上只有 12 词。
> **T4（Android ≥30 分钟连续、iOS 真机）本轮未能完成**：无人值守环境下设备已休眠，
> MIUI 拒绝输入注入（`INJECT_EVENTS`），因此无法唤醒屏幕、无法点击、也无法在设备自身触发播放。

## 1. T0 基线（改动之前）

| 项目 | 结果 |
| --- | --- |
| HEAD | `1447837 docs(broadcast): hand off three-column validation to CodeBuddy` |
| 分支 | `codex/live-three-column-sync`（相对 `origin/main` ahead 3，未推送） |
| 工具链 | Flutter 3.41.8 / Dart 3.11.5（user-branch） |
| 设备 | Redmi `24117RK2CC`（`zorn`，Android 16）；ADB 地址仅本地留存 |
| `flutter analyze --no-pub` | No issues found |
| `flutter test --no-pub` | 219 项全部通过 |
| `flutter build apk --debug --no-pub` | `build/app/outputs/flutter-apk/app-debug.apk` |
| 音源哈希 | `012.mp3` SHA-256 与交接文档一致（`39e46d11…04b3`） |

改动之后重跑：`analyze` No issues found，`flutter test --no-pub` **227 项**通过；
带诊断开关的 Debug APK 亦构建安装成功。

## 2. P0 第 6 段：数字音源把嫌疑排除了一半

复现脚本：`tool/diagnose_final_vs_preview_test.dart`。它用**同一个** ORT122 模型
（`assets/quran_offline/fastconformer_full_mixed_ort122.onnx`，主机 `host_ort_server.py`）
对同一份 `012.mp3`（解码为 16 kHz 单声道）在相邻 30 秒窗口上跑三条路径：

| 路径 | 做法 | 对应代码 |
| --- | --- | --- |
| 终稿 | 按声学停顿切子窗 → 逐窗前向 → `lookaheadSeconds` 延迟提交尾词 | `BroadcastTranscriber.transcribe` |
| 预览 | 最近 12 秒整窗一次前向 | `BroadcastTranscriber.transcribePreview` |
| 整窗单次 | 30 秒一次前向（去掉分段与尾词延迟，只保留更长的输入） | `transcribePreview(finalSamples)` |

结果（明细 JSON：[`digital-final-vs-preview-2026-09-23.json`](digital-final-vs-preview-2026-09-23.json)）：

| 起点 | 终稿：词数 / 子窗 / 匹配 | 预览 12 s：词数 / 匹配 | 整窗单次 30 s：词数 / 匹配 |
| ---: | --- | --- | --- |
| 145 s | 20 / 3 / `12:8-9` partial | 4 / `12:7-8` candidate | 20 / `12:8-9` partial |
| 155 s | 28 / 3 / `12:8-9` partial | 9 / `12:8` partial | 22 / `12:8-9` partial |
| 165 s | 23 / 3 / `12:8-9` partial | 6 / `12:8-9` candidate | 19 / `12:8-9` partial |
| 175 s | 25 / 3 / `12:9-10` partial | 7 / `12:9` candidate | 21 / `12:9-10` partial |
| 185 s | 21 / 2 / `12:9-10` partial | 6 / `12:9` candidate | 21 / `12:10` confirmed |
| 195 s | 23 / 2 / `12:10-11` partial | 10 / `12:10` partial | 23 / `12:10-11` partial |

由此可以判定：

1. **终稿的分段与尾词提交逻辑不是丢词原因**。数字音源上 6/6 个窗口的终稿路径都产出
   20–28 词，并稳定命中 `12:8-9` ~ `12:10-11`，覆盖率 0.57–0.76；而设备侧的同一路径
   在第 6 段只剩 12 词。
2. **短预览窗口本来就只能给出低覆盖率候选**（4–10 词、多为 `candidate`）。这与第 6 段之前
   「12 秒预览反复给出 `12:8` 候选」的现象一致，属预期行为，不构成新增缺陷。
3. **12 秒预览与 30 秒终稿的词量相差约 3 倍**，说明「预览候选不准」是窗口长度的自然结果，
   不是匹配器或校订译本的问题。

限制（必须一并说明）：

- 这是**同一 MP3 的不同 30 秒窗口**，与设备会话**没有采样级对齐**，只能界定责任范围
  （链路正常 → 输入侧异常），不能断言具体物理原因（房间声学、扬声器失真、设备 `AudioSource`
  处理、AGC／降噪）。
- `record` 6.2.1 的 `AndroidRecordConfig` 默认 `autoGain / echoCancel / noiseSuppress` 均为
  `false`，但默认走 `AndroidAudioSource.defaultSource`（即 `MediaRecorder.AudioSource.MIC`）。
  `VOICE_RECOGNITION` 是否在远端拾音场景更稳**未经实测**，本轮不做改动。
- 结论只针对这一段，没有在第 6 段之外做全章对照。

## 3. 新加入的诊断能力（默认全部关闭）

| 能力 | 入口 | 开关 | 产出 |
| --- | --- | --- | --- |
| 麦克风 PCM 转储 | `MicrophoneCaptureSource`：在 `pcm16ToFloat32` **之前**写插件交付的原始 PCM16 | `--dart-define=quran_dump_pcm=true` | 应用私有外部目录 `mic_<ts>.pcm`（16 kHz／16 bit／单声道），上限 200 MB 后自动停止 |
| 结构化时延事件 | `BroadcastLatencyTrace` | `--dart-define=quran_latency_trace=true` | 每行一条 `[BroadcastLatencyTrace] kind=… epoch/rev/gen/utt/aStart/aEnd/aRecvUs/ref/status/src/atUs/note` |
| 终稿采样区间 | `[Broadcast]` 片段日志新增 `采样 <start>-<end>`，并随 `finalPublished` 记录 | 同左 | 可据此从 PCM 转储逐条裁出与终稿完全相同的音频 |
| 无人值守自动启停 | `main.dart` 的 `_maybeAutoRun`，仅 `kDebugMode` | `--dart-define=quran_auto_run_seconds=2100` | 依赖就绪后自动开始，到时走正常 `stop()` 保证末句落库 |
| 识别期间阻止息屏 | `quran_offline/screen` → `FLAG_KEEP_SCREEN_ON` | 由自动启停路径调用（iOS 未实现，调用方吞掉 `MissingPluginException`） | 避免息屏后应用退到后台而被系统静音收音 |

**默认构建（不带 dart-define）不写文件、不打新事件、不自动开始或停止收音**，
收音、终稿与 UI 行为均未改变。这一点由单测锁定
（见 `test/broadcast_session_test.dart` 的「默认不注入记录器，收音路径不产生任何事件」）。

### 3.1 为什么要加息屏开关

实测发现的设备侧真相（对后续任何长时验证都成立）：

- 设备息屏后应用被切到后台；Android 9 起后台 UID 的麦克风被 `audioserver` 静音，
  实际拿到的 PCM **RMS 与 peak 均为 0.0000**（见第 4 节），预览全部退化为未匹配。
- 本机 `screen_off_timeout` 为 `600000 ms`，且 `settings put global/system` 被拒
  （`Neither user 2000 nor current process has android.permission.WRITE_SECURE_SETTINGS`），
  无法远程改为常亮。

## 4. 本轮真机尝试与失败证据（T1／T4 未完成的原因）

| 步骤 | 命令 | 结果 |
| --- | --- | --- |
| 连接设备 | `adb connect "$ANDROID_ADB_HOST"` | 可连，但十余分钟后会掉线，需重连；地址由本地环境变量提供 |
| 前台状态 | `adb shell dumpsys window \| grep mCurrentFocus` | 焦点在 `NotificationShade`（通知面板），应用未 resumed |
| 屏幕状态 | `adb shell dumpsys power \| grep mWakefulness` | `mWakefulness=Asleep`（已休眠） |
| 输入注入 | `adb shell input keyevent 26/126/224` | `INJECT_EVENTS` 权限拒绝（与此前 MIUI 经验一致） |
| 远程唤醒 | `adb shell service call power 11/12 …` | `SecurityException: Neither user 2000 … has android.permission.DEVICE_POWER` |
| 修改息屏超时 | `adb shell settings put system screen_off_timeout …` | `WRITE_SECURE_SETTINGS` 拒绝 |
| 设备自身播放 | `am start -a VIEW -d file:///sdcard/Music/012.mp3` | `com.miui.player` 被拉起，但 `PlaybackState` 为 `NONE(0)`；`cmd media_session dispatch play` 无效 |
| 本机外放 → 设备拾音 | `osascript` 音量 65 + `afplay 012.mp3` | 设备侧 PCM 全程 RMS 0.0000／peak 0.0000，未拾到任何声音 |

**结论**：本轮「同一输入的设备侧 PCM 与数字音源对齐」在无人在场的情况下无法完成。
PCM 转储本身已验证可用（文件按 32 KB/s 正常增长、`adb pull` 成功），只是当次录到的是全零——
这反过来也印证了「息屏后被判定为后台、麦克风被静音」这一机制。

### 4.1 有人时的复跑步骤

先在本机设置 `ANDROID_ADB_HOST` 为实际 ADB 主机与端口（格式 `host:port`，不要写入仓库）。

```bash
# 1) 解锁并保持设备亮屏
adb connect "$ANDROID_ADB_HOST"

# 2) 构建带诊断的 Debug APK
flutter build apk --debug --no-pub \
  --dart-define=quran_dump_pcm=true \
  --dart-define=quran_latency_trace=true \
  --dart-define=quran_auto_run_seconds=2100
adb install -r build/app/outputs/flutter-apk/app-debug.apk

# 3) 采集日志并开始自动长测（2100 秒后自动停止并写库）
adb logcat -c
adb logcat -v time 'flutter:V' '*:E' > device_long_run.log &
adb shell am start -n com.llvision.quran_offline_demo/.MainActivity

# 4) 立刻在设备旁播放同一份 012.mp3（外放），至少 35 分钟

# 5) 取 PCM 与日志
adb pull /storage/emulated/0/Android/data/com.llvision.quran_offline_demo/files/ mic_dump/

# 6) 用 [Broadcast] 片段日志里的 `采样 <start>-<end>` 逐条裁出音频，做主机对照
QURAN_ORT_URL=http://127.0.0.1:18765 \
QURAN_DIAG_WAV=<裁出的 wav> \
QURAN_DIAG_WINDOWS=0 \
QURAN_DIAG_OUT=diag.json \
flutter test tool/diagnose_final_vs_preview_test.dart
```

## 5. T2 结构化时延埋点（已实现，尚未取到真机样本）

既有 `[BroadcastLatency]` 只有两个数，**不能相加**当作端到端时延。新增事件把链条补齐：

| 事件 | 触发点 | 关键字段 |
| --- | --- | --- |
| `previewPublished` | `_processPreview` 生成结果时 | `aStart/aEnd/aRecvUs/ref/status/rev/gen` |
| `previewFrame` | `recordPreviewRendered` 首次绘制该修订 | `rev/gen/atUs/note(with_translation / no_translation)` |
| `translationPublished` | `_publishPreviewTranslation` | `gen/src/ref` |
| `translationFrame` | 带译文的预览首次绘制 | `gen/src/atUs` |
| `translationDropped` | 候选被替换，且旧候选还有在途或已显示的译文 | `gen/note(pending / shown)` |
| `finalPublished` | 终稿落库后 | `aStart/aEnd/ref/status/note(boundary=…)` |

设计要点（均有单测锁定）：

- 时间戳取自会话单调时钟 `Stopwatch`，与 `revision`、`candidateGeneration` 共同用于判断
  「迟到结果不得混算」（A→B→A 的旧译文必须丢弃）。
- `translationDropped` 记录在**候选真正被替换**的位置；若记在事后清理处，此时 `_preview`
  已是新候选，看不出曾有一份被顶替的译文——这正是仅按成功显示的候选统计会系统性低估时延的地方。
- 「语音进入麦克风 → 正确译文可见」的建议口径：起点取该译文所属候选首次出现时的 `aStart`，
  终点取对应的 `translationFrame.atUs`；「等待或被取消」比例为
  `translationDropped / (translationFrame + translationDropped)`。

本轮没有有效真机录音，因此 **P50/P95、冷／热路径与样本数留空**，不得用既有的
647/972 ms 与 21/28 ms 顶替。

## 6. T3 候选到终稿的对照（基于上一轮既有日志）

脚本：`tool/analyze_preview_evidence.py`，输入仅在本地留存的
`live-three-column-android-2026-09-23.txt`，
输出 [`preview-candidate-stats-2026-09-23.json`](preview-candidate-stats-2026-09-23.json)。
它按「记录 #N 已保存」把预览划分到所属片段，统计范围重叠、跨章误提示与抖动。

全局：

| 指标 | 值 |
| --- | --- |
| 预览次数 / 有候选次数 | 384 / 383 |
| 跨章候选预览 | **145（37.9%）** |
| 「连续两轮相同」的跨章候选（会触发错误章节译文） | **33 对（占相邻预览对 8.6%）** |
| 有终稿范围的片段 | 15 |
| 末次预览与终稿范围重叠 | **10 / 15（66.7%）** |
| 片段内平均重叠率 | 53.9%（区间 0 ~ 0.92） |

逐片段（节选，完整表见 JSON 的 `perUtterance`）：

| 记录 | 终稿摘要 | 终稿 | 预览数 | 不同候选 | 片段内重叠率 | 末次候选 |
| --- | --- | --- | --- | ---: | ---: | --- |
| 1 | `12:1 词 1–9` candidate | 12:1 | 28 | 14 | 0.111 | `12:2` |
| 5 | `12:6–7` candidate | 12:6-7 | 25 | 11 | 0.520 | `12:7` |
| **6** | **未匹配** unmatched | — | 25 | 8 | 0.000 | `41:1-2` |
| 7 | `12:9–10` partial | 12:9-10 | 25 | 10 | 0.680 | `12:10` |
| 11 | `12:15–17` candidate | 12:15-17 | 24 | 11 | 0.708 | `41:2` |
| 12 | `12:17–18` candidate | 12:17-18 | 26 | 8 | 0.654 | `56:15` |
| 15 | `12:21 词 1–17` candidate | 12:21 | 24 | 11 | 0.000 | `28:9` |
| 16 | `12:21 词 18–28` candidate | 12:21 | 9 | 7 | 0.000 | `12:6` |

读法与限制（不得过度解读）：

1. **这里用终稿当参考，而不是独立人工标注**。终稿自身有 6 条 `candidate`、1 条 `unmatched`，
   所以「不重叠」不等于「预览错了」，也可能是终稿不准；反过来「重叠」也不能证明预览合格。
   它回答的是**候选抖动与跨章误提示的规模**，替代不了人工标注样本。
2. **8.6% 的连续两轮跨章候选最值得警惕**：按当前策略，同一引用连续两轮即触发预览译文，
   于是错误章节的译文会被显示出来。上一轮「最终有范围的 15 条都在第 12 章」只说明终稿未被污染，
   不代表中间态是干净的。
3. 与交接文档提出的「标注样本内重叠率 ≥ 95%」口径不同（那条针对人工标注样本）。
   这里的 66.7% 是「末次预览 vs 终稿」的机器可算近似，**不能直接与 95% 比较**，
   它的用途是给后续人工标注排优先级：先标 #1、#6、#11、#12、#15、#16。
4. 这只是**一台设备、一段第 12 章、约 452 秒**的样本，不做跨机泛化。

## 7. T3 首页三栏 widget 回归（新增 4 项）

`test/broadcast_three_column_widget_test.dart` 跑的是**真实的** `BroadcastHomePage`、
`BroadcastSessionController` 与仓储（只注入推理桥、音源、翻译引擎、匹配器与内存数据库，
不加载 ONNX 资产、不走平台通道）：

| 用例 | 断言要点 |
| --- | --- |
| 三栏在同一帧读取同一份预览版本 | 三栏引用的窗口修订号一致，且同帧内不存在更早或更新的修订号 |
| 候选切换后不显示上一候选的迟到译文 | A 的在途译文返回时候选已是 B：界面与新预览都没有 A 的译文，也不残留 A 的标准原文 |
| 未匹配预览不显示旧经文，也不翻译波动转写 | 译文栏停在「等待匹配经文」；不调用翻译引擎；界面没有任何标准原文 |
| 终稿到来后三栏切换为已确认记录与来源标签 | 预览清空、三栏转为已确认记录；界面同时出现译文文本与其来源标签 |

注：`testWidgets` 运行在 `FakeAsync` 区域，sqlite 与资产 IO 必须走 `tester.runAsync`
否则会挂起；文件内的 `_advance` 负责「泵帧 + 真实时钟」交替推进。

## 8. 未完成项（保持「未验证」，不得用旧数据顶替）

| 项 | 状态 | 阻塞原因 / 下一步 |
| --- | --- | --- |
| Android ≥30 分钟连续三栏测试 | **未验证** | 需要有人在设备旁：解锁保持亮屏、持续外放 ≥35 分钟；步骤见 4.1 |
| iOS 真机 | **未验证** | 测试机在局域网但 `device-not connected`（需开启开发者模式并用线缆配对）；本轮没有任何 iOS 运行时证据 |
| 端到端时延 P50/P95、等待／被取消比例 | **未测量** | 埋点已就绪，缺有效真机录音（同 4.1） |
| 标注样本上的候选重叠率（目标 ≥95%） | **未测量** | 需人工标注；可用第 6 节的排序作为起点 |
| 章首歧义等待、可靠终稿后的软连续性 | **未评估** | 同上，需先有可标注的完整录音 |

## 9. 代码改动清单

| 文件 | 改动 |
| --- | --- |
| `lib/broadcast/application/audio_pcm_dump.dart` | 新增：限额的本地 PCM 转储（默认不启用） |
| `lib/broadcast/application/broadcast_latency_trace.dart` | 新增：结构化时延事件模型与记录器（默认不启用） |
| `lib/broadcast/application/screen_keep_on.dart` | 新增：识别期间阻止息屏（仅 Android 有实现） |
| `lib/broadcast/application/microphone_source.dart` | 可选 `pcmDump`，在归一化前写原始 PCM16 |
| `lib/broadcast/application/broadcast_session_controller.dart` | 埋：`previewPublished / translationPublished / translationDropped / previewFrame / translationFrame / finalPublished`；片段日志增打采样区间 |
| `lib/broadcast/broadcast_services.dart` | 按 dart-define 装配转储与埋点；`bootstrap` 支持注入 `database / matcher / editions`，`engine` 类型放宽为 `OfflineTranslationEngine` |
| `lib/main.dart` | 仅 Debug 的无人值守自动启停 |
| `android/app/src/main/kotlin/.../MainActivity.kt` | 新增 `quran_offline/screen` 通道 |
| `tool/diagnose_final_vs_preview_test.dart` | 新增：数字音源上对照终稿／预览两条路径 |
| `tool/analyze_preview_evidence.py` | 新增：按既有日志统计候选重叠、跨章与抖动 |
| `test/broadcast_session_test.dart` | 新增 4 项时延埋点单测 |
| `test/broadcast_three_column_widget_test.dart` | 新增 4 项三栏 widget 回归 |
