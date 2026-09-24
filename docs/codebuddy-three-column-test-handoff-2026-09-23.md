# CodeBuddy 交接：三栏实时同步后续测试与开发

## 1. 接手基线

| 项目 | 当前事实 |
| --- | --- |
| 仓库 | 当前 Git 仓库根目录（以下记作 `<repo_root>`） |
| 工作分支 | `codex/live-three-column-sync`；本说明所依据的功能与证据基线为 `7729646`，此前功能提交 `2f6d15a`；接手时仍须核对实际 HEAD，分支尚未推送 |
| 实际安装 | Redmi `24117RK2CC`，Android 16；ADB 地址仅本地留存。安装过 `app-debug.apk`，包名 `com.llvision.quran_offline_demo`，版本 `1.0.0`（versionCode 1） |
| 播放源 | `resources/broadcast_quran/full_recitation/012.mp3`（Alafasy，第 12 章，Git 忽略的本地资源）；SHA-256 `39e46d11d48bc9753dfec1c852f9b885ab1b963060b0039add71702e78b104b3` |
| 验证边界 | 本分支完成 219 项自动测试、`flutter analyze --no-pub`、Android Debug APK 构建；新版 Android 仅完成第 12 章约 452 秒局部外放拾音试播；iOS 广播完整链路未验收 |

先读 [实时同步方案](live-three-column-sync.md)、[本轮 Android 实测](evidence/live-three-column-android-2026-09-23.md)、[既有真机验收](device-verification.md) 和 [匹配口径](matching.md)。原始应用事件日志仅在本地留存。这些文件区分了旧版 33 分钟验收数据与本分支的局部实测，不得混算。

## 2. 已完成，勿重复造链路

| 功能 | 代码入口 | 已验证到哪一步 |
| --- | --- | --- |
| 有界实时预览 | `BroadcastSessionController._requestPreview` / `_processPreview`，`BroadcastTranscriber.transcribePreview` | 有新音频时最短约 1 秒尝试刷新；最近最多 12 秒只做一次模型前向；转写和经文候选来自同一份证据。终稿 `_processFinal` 仍复核完整片段。自动测试与 Android 局部试播已覆盖。 |
| 三栏同源与迟到结果隔离 | `BroadcastPreview`、`BroadcastHomePage`、`recordPreviewRendered` | UI 的三栏读取同一预览快照或同一终稿；预览带会话、片段、音频范围、修订与候选代数。候选变化时清掉旧译文；A→B、强切 overlap、停止/关闭竞态已有控制器测试。尚缺真实 UI 帧级自动断言和人工逐帧错配验收。 |
| 译文来源 | `TranslationCoordinator.translatePreview` / `runJob`、`PreviewTranslation` | 校订译本标 `curatedEdition`；无译本时才按标准原文机翻 `machineCanonical`；未匹配终稿按实际转写机翻 `machineAsr`。未匹配预览不翻译波动转写。来源和并发有单测；本轮 15 条校订译本、1 条 `machineAsr`。 |
| 调度与资源生命周期 | `BroadcastSessionController._pumpWork` / `shutdown`、`TranslationCoordinator.waitForIdle`、`BroadcastServices.dispose` | 终稿优先、预览请求合并；关闭时等待推理、译文与缓存写入。自动回归覆盖；本轮没有预览异常、队列超载或崩溃。 |

必须保持三种文本彼此独立：转写是模型实际输出，匹配经文是语料库标准原文，译文须标明校订/机翻来源。预览只能称候选，不能以低延迟为由修改终稿数据库事实或把机翻伪装成经文权威译本。

## 3. 未解决点与优先级

| 优先级 | 问题与现有证据 | CodeBuddy 下一步 |
| --- | --- | --- |
| P0 | 第 12 章第 6 段终稿未匹配，处于 `12:6–7` 和 `12:9–10` 之间；手机 ASR 丢词严重。相同 `012.mp3` 的 150–180 秒数字音频使用同款 ORT122 模型在主机可读出 `12:8` 开头；两路起点没有采样级对齐。 | 先采集或重放**同一输入**的设备侧 PCM，与数字音源对齐，拆分外放拾音、分段和模型误差。不得仅凭这一条调低匹配阈值或用标准经文反填 ASR。 |
| P0 | `[BroadcastLatency]` 已测“最新 PCM 块进入→转写/候选 UI 帧”P50/P95 `647/972 ms`（n=384）和“稳定候选→显示译文”`21/28 ms`（n=151）；尚未测语音内容进入麦克风到**正确译文**可见的完整分布。第二项只统计成功显示的候选，两个数不能相加当总时延。 | 增加可关联的音频区间、预览修订、候选代数、译文来源和 UI 帧事件；从同一录音及标注计算完整时延、等待或被取消的比例，报告 P50/P95、冷/热路径与样本数。 |
| P1 | 短窗口预览出现跨章候选，尤其开头的太斯米和多章共享短语；“同一节引用连续两轮”只能说明稳定，不能保证正确，可能把错误章节的译文显示出来。最终有范围的 15 条都在第 12 章，但 16 条中有 6 条仍为 `candidate`，1 条 `unmatched`。 | 人工标注预览音频窗与正确节范围，统计候选到终稿的范围重叠、跨章误提示、候选抖动和错配译文；评估章首歧义等待、可靠终稿后的软连续性，保持合法跳章可恢复。先用证据评估，再改全局阈值。 |
| P1 | 新版只播放约 452 秒，未完成 30 分钟连续运行、全章多场景和 iOS 麦克风→匹配→翻译验收。旧版 Android 33 分钟结果不能代替新版。 | 在 Android 目标设备做连续 ≥30 分钟测试；iOS 必须真机，不以模拟器或设备切片构建代替。分别留存原始日志、设备/版本、音源哈希、匹配记录与异常统计。 |
| P2 | 当前预览链路有控制器/翻译单测，但没有直接验证首页三张卡片文本、版本与等待态在同一 UI 帧中的 widget 测试。 | 增加少量有意义的 widget 回归：同 frame、A→B→A 迟到译文、未匹配不显示旧经文、终稿替换及来源标签。 |

## 4. 建议实施阶段与文件范围

1. **T0 复现基线**：记录 `git status --short --branch`、提交号、Flutter 版本、设备列表；运行 `flutter analyze --no-pub`、`flutter test --no-pub`、`flutter build apk --debug --no-pub`。先留结果，再修改。不要重置现有分支、清数据库或重装音源。
2. **T1 同音频定位第 6 段**：从本地 `012.mp3` 提取 12:8–9 周边固定窗口；在仅 Debug 生效且显式启动的诊断路径中，记录麦克风 PCM 的采样区间/单调时间、强切边界和模型输入。首选 `packages/quran_broadcast_sdk/lib/broadcast/application/microphone_source.dart` 的 `MicrophoneCaptureSource.start`，在 `pcm16ToFloat32` 前保存插件实际交付的 PCM16；也可在 `BroadcastSessionController._onChunk` 保存送入分段器的 Float32。用记录已有的 `startSample/endSample` 精确裁出第 6 段。原始音频存应用私有或本地临时目录并限额，不自动上传，也不在未核验授权前加入 Git。用相同 PCM 对照主机和设备 ASR，保存文本、节号与时间对齐表。
3. **T2 端到端指标**：在 `broadcast_session_controller.dart`、`translation_coordinator.dart`、`broadcast_home_page.dart` 的现有版本/帧标识上补齐结构化事件；保持单调时钟和音频采样索引。单测验证事件关联、候选取消和迟到事件不混算。区分“转写/候选首帧”“候选稳定后译文”“首个正确译文”三个口径，不能把后两个相加当完整时延。
4. **T3 准确性与 UI 回归**：优先在 `test/broadcast_match_test.dart`、`test/broadcast_session_test.dart`、`test/broadcast_translation_test.dart` 补案例，新增首页 widget 测试；如需改 `quran_match_service.dart` 或 UI 候选策略，先用标注集展示收益和误报代价。保持 `BroadcastPreview` 身份字段、译文来源枚举与最终记录语义不变。
5. **T4 真机复验**：Android 长时播放和 iOS 广播全链路分开跑。采集 P50/P95、节范围、错配、崩溃/ANR、过载、内存与冷/热语言包状态。更新 `docs/evidence/`、`docs/live-three-column-sync.md`、`docs/device-verification.md` 和 README；没有执行的验收显式标“未验证”。

## 5. 验收与回滚

- **自动化门槛**：`flutter analyze --no-pub` 0 issue、全套 `flutter test --no-pub` 通过、Android Debug APK 构建通过；新增测试必须实际跑过。CI 的 Android 构建与 iOS 设备切片编译不算真机运行。
- **延迟门槛**：已有局部目标为“最新音频块→转写/候选 UI 帧”P95 ≤1.2 秒、稳定候选→热缓存校订译文 UI 帧 P95 ≤0.15 秒；下轮还需报告首个正确译文端到端 P50/P95，在明确起点和冷/热条件前不得宣称达标。
- **准确性门槛**：三栏跨版本错配 0 次；标注样本中的候选与最终经文范围重叠率建议目标 ≥95%，须先建立独立标注基线并明确样本定义，再判定是否达标。单列第 6 段、跨章短语、合法跳章与重复节。F1 是转写和所选参考经文的一致性，不能代替独立人工节号准确率。
- **稳定性门槛**：Android 连续 ≥30 分钟，目标终稿丢弃 0、错序 0、崩溃/ANR 0；iOS 同链路真机另出证据。软件合成测试只证明 T0，局部真机只证明对应时间窗。
- **回滚**：诊断 PCM 和指标埋点须可关闭，默认不改变收音/终稿路径。若候选策略降低准确率，只回退预览策略或调整 `previewWindowSeconds`；保留终稿完整转写、数据库记录、译文来源与历史。任何阈值或窗口改动都附前后标注集数据。

## 6. 可直接交给 CodeBuddy 的任务文本

```text
在当前仓库 `<repo_root>` 的 codex/live-three-column-sync 分支（功能与证据基线 7729646；接手时核对实际 HEAD）继续三栏实时同步的测试与必要修复。先读 docs/codebuddy-three-column-test-handoff-2026-09-23.md、docs/live-three-column-sync.md、docs/evidence/live-three-column-android-2026-09-23.md；同名 .txt 原始应用日志仅在本地留存。先核对 git 状态和实际代码，保留已有提交、未提交内容与 Git 忽略的 resources/broadcast_quran/full_recitation/012.mp3；不要从 main 重做已完成链路，不要清设备数据、推送或合并。

按 T0→T4 执行：先记录 analyze/test/APK 基线；用同一份 012.mp3 与设备侧可对齐 PCM 定位第 6 段 12:8–9 未匹配的原因；补音频区间到转写、候选、译文 UI 帧的结构化端到端测量；用人工标注样本检查跨章候选与稳定译文，补关键 controller/translation/widget 回归；最后分别做 Android ≥30 分钟和 iOS 真机广播链路复验。若设备或录音条件不可用，完成可独立进行的软件工作并把真机项标为未验证，不能以主机/模拟器结果替代。

保持实际 ASR、标准经文、译文三种文本独立；校订译本 curatedEdition、标准原文机翻 machineCanonical、未匹配转写机翻 machineAsr 的来源不得混淆。预览始终是候选，终稿保持完整片段复核和现有落库语义。对延迟、准确率与资源消耗做可对照的前后证据；不要只因第 6 段未匹配就调低全局匹配阈值。

交付时给出：修改文件与原因、复现命令及音源哈希、自动测试/构建的实际输出、Android/iOS 各自的真机证据路径、P50/P95 的起止定义与样本数、逐项达标/未达标/未验证结果、仍待解决项和可执行回滚。同步更新 docs/evidence、实时同步方案、真机验收记录与 README 的交叉引用；不得把旧版 33 分钟数据当作新版验收。
```
