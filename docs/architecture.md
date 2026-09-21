# 架构与数据流

本文描述应用的运行结构：依赖如何组装、音频如何流动、数据落在哪里。
算法口径与阈值不在本文展开，见 [经文匹配与指标](matching.md)。

## 1. 全局分层

```
┌─────────────────────────── UI 层（Flutter Widget） ───────────────────────────┐
│ broadcast/ui/   三栏首页 · 历史列表 · 记录详情                                │
│ quran_offline/  quran_offline_demo_page.dart（开发诊断）                       │
└───────────────────────────────────┬──────────────────────────────────────────┘
                                    │ 只读状态 + 发命令（ChangeNotifier）
┌───────────────────────────────────▼──────────────────────────────────────────┐
│ 应用层  broadcast/application/                                                │
│   会话控制器 · 断句状态机 · 片段转写器 · 匹配服务 · 翻译协调器                  │
└───────────────────────────────────┬──────────────────────────────────────────┘
                                    │ 只依赖抽象接口
┌───────────────────────────────────▼──────────────────────────────────────────┐
│ 数据 / 领域层  broadcast/data/ · domain/ · translation/                       │
│   SQLite 仓储 · 全经语料库 · 译本目录 · 翻译引擎适配器                          │
└───────────────────────────────────┬──────────────────────────────────────────┘
                                    │ 纯 Dart 算法（Android / iOS 共用）
┌───────────────────────────────────▼──────────────────────────────────────────┐
│ 算法层  lib/quran_offline/                                                    │
│   CTC 解码 · 前向后向打分 · 召回精排 · 词级对齐 · WER · WAV 解码 · 归一化        │
└───────────────────────────────────┬──────────────────────────────────────────┘
                                    │ MethodChannel `quran_offline/ort`
┌───────────────────────────────────▼──────────────────────────────────────────┐
│ 原生层  QuranOrtBridge（Java / ObjC）→ ONNX Runtime 1.22.0                     │
└──────────────────────────────────────────────────────────────────────────────┘
```

**唯一的平台差异**是最后一步的推理桥。桥只做张量翻译：

- 输入：`audio_signal`（float32 `[1, N]`）+ `length`（int64 `[1]`）；
- 输出：`log_probs`（`[1, T, 1025]` 展平）、`timeSteps`、`vocabSize`；
- 模型首次调用时从 assets 复制到应用私有目录缓存，后续复用以固定文件名加载。

桥是**单实例 + 串行**的：Android 侧 `QuranOrtBridge` 用单线程 executor 加 `synchronized`，
iOS 侧用 `dispatch_once` 单例加 `@synchronized(self)`。这不是实现偷懒，
而是应用层本身就按「单模型串行」调度（见 §4），桥的串行只是把这条约束落实到原生侧。

## 2. 依赖组装

所有依赖在 `BroadcastServices.bootstrap()` 里创建一次，由应用级单实例持有；
**页面不得直接操作 ORT、下载模型或执行 SQL**。

```
BroadcastQuranLibrary.load()          全经语料库（唯一语料来源）
   ↓
BroadcastDatabase.open()              SQLite（应用支持目录）
   ↓
RecordRepository.recoverInterruptedJobs()   把上次被中断的翻译任务重新排队
   ↓
PlatformOrtRunner.loadModel(...)      ASR 模型（复用旧 Demo 的模型资产）
   ↓
BroadcastTranscriber / QuranMatchService / BroadcastTranslationCatalog /
JsonVerseTranslationRepository / TranslationCoordinator
   ↓
BroadcastSessionController            会话 + 音频源 + 目标语言（读设置表，默认中文）
   ↓
session.refreshHistory()              载入历史计数与最近 10 条
```

启动失败（例如模型缺失）时引导页给出重试入口，并允许直接进入开发诊断，
不把失败状态隐藏掉。

| 复用（允许） | 不复用（强制隔离） |
|--------------|--------------------|
| ASR 模型 `fastconformer_full_mixed_ort122.onnx` | 旧经文库 `assets/quran_offline/quran.json` |
| 词表 `vocab.json` | 旧 span 表 `quran_ctc_tokens.json` |
| `quran_offline/` 下的纯 Dart 算法（解码、打分、对齐、指标、WAV 解码） | 旧语料的任何运行时索引 |

隔离由测试保证：`test/broadcast_corpus_test.dart` 用一个记录全部资产请求的 bundle
加载广播语料库，断言期间**没有任何请求命中旧库文件**。

## 3. 音频数据流

```
MicrophoneCaptureSource（record 插件，pcm16bits / 16000 Hz / 单声道）
   ↓ Float32List chunk
UtteranceSegmenter.addChunk
   ├─ 未结束时返回 null（继续累积）
   ├─ 静音 ≥ 1.2 s 且片段 ≥ 0.8 s → takeOnSilence()
   └─ 片段 ≥ 30 s                  → takeOnMaxDuration()（保留 1 s 重叠）
   ↓ BroadcastFragment（音频 + 起止采样点 + 边界原因）
BroadcastSessionController
   ├─ 终稿队列（上限 3，超载丢最旧并计数）
   └─ 预览节流（每 1 s 一次，可被终稿抢占）
   ↓
BroadcastTranscriber.transcribe
   ├─ OfflineTranscriber 按声学暂停切段（保 ASR 准确度）
   ├─ 逐段 runner.run → TextCtcDecoder.decode
   └─ matchEvidence：单段时复用该段证据；多段时对整段音频再跑一次前向
   ↓
QuranMatchService.match → BroadcastMatchOutcome
   ↓
RecordRepository.save（同事务写记录 + 匹配 + 指标 + 翻译任务）
   ↓
TranslationCoordinator.drain（后台处理任务，不阻塞界面）
```

`matchEvidence` 的那次额外前向是**必要的**：转写按声学暂停把长片段切成 3–10 s 的子窗
（为了 ASR 更准），而 CTC 打分要求候选满足 `token 数 × 2 + 1 ≤ 帧数`，
逐子窗做匹配会让跨多节的正确候选因帧数不足被判「不可行」而直接跳过。
因此匹配改用整段音频的原生证据，这次推理不服务转写，只为给匹配提供足够帧数。

## 4. 会话状态与并发约束

会话状态：`idle → starting → running → finishing → idle`。

| 约束 | 取值 / 行为 |
|------|-------------|
| 单模型串行 | 预览与终稿共享同一个推理桥，互相排斥 |
| 终稿优先 | 队列里有终稿时先处理终稿，预览让路 |
| 终稿队列上限 | 3 条；超载丢弃最旧的一条并计数提示，不无限积压 |
| 停止幂等 | 先停采样 → 等在途推理结束 → `segmenter.flush()` → drain → 打印本次保存条数 |
| 语言切换 | 仅在空闲允许；识别中禁用并给出提示，避免一句话中途混语言 |
| 目标语言冻结 | 记录创建时写入 `target_language`，后续切换不影响历史记录 |
| 预览译文 | 候选连续两次一致才触发翻译，结果进内存 memo 与 `translation_cache`，不写记录行 |
| 内存边界 | 音频缓冲与推理队列都有界，不累积整场录音 |

## 5. 数据模型

SQLite，库文件 `broadcast_quran.db` 位于**应用支持目录**（非缓存目录），
`schemaVersion = 1`，异常不自动清库。

| 表 | 职责 | 关键约束 |
|----|------|----------|
| `recognition_sessions` | 一次收音会话 | 起止时间、目标语言、模型/配置版本 |
| `utterance_records` | 一条最终片段（三类文本 + 状态 + 时间） | 业务去重键 `UNIQUE(session_id, utterance_id, revision)`；`display_sequence` 唯一且由独立计数器分配 |
| `record_matches` | 匹配到的节范围（可多条） | 主键 `(record_id, ordinal)`，随记录级联删除 |
| `record_metrics` | 比对指标与逐词对齐快照 | 主键 `(record_id, revision)`；无可信参考时为 null |
| `record_translations` | 每个目标语言一条译文 | `UNIQUE(record_id, revision, target_language, provider)`，保存来源与输入范围 |
| `translation_jobs` | 待办翻译任务 | `state`（pending/running/done/failed）+ `attempt_count` |
| `translation_cache` | 输入哈希 → 译文 | 命中时更新 `last_used_at` |
| `settings` | 键值设置 | 目标语言偏好、展示序号计数器 |

行为约定：

| 规则 | 表现 |
|------|------|
| 业务去重 | 同一片段反复回调只更新同一条记录，不产生多条历史 |
| 真实复读 | 同一节在不同时间被真实诵读，是不同的 `utterance_id`，生成不同记录 |
| 展示序号 | 删除记录后不回填空洞（删 #2 后新建仍是新号，不回收旧号） |
| 原子写入 | 三类文本 + 匹配 + 指标 + 任务同事务写入，失败不会只落一半 |
| 迟到译文防护 | `revision` 或 `target_language` 不符时拒绝写入；记录已删则丢弃结果 |
| 重启恢复 | 残留 `running` 任务重置为 `pending`，记录保留，重试不会新建历史 |
| 级联删除 | 删除记录同时清理匹配、指标、译文与任务（`translation_cache` 保留复用） |
| 无参考指标 | 界面显示「不可用」而不是 0 分，不伪造高分 |

## 6. 领域模型与状态枚举

`lib/broadcast/domain/utterance_record.dart` 集中定义：

| 类型 | 取值 | 含义 |
|------|------|------|
| `MatchStatus` | `confirmed` / `partial` / `candidate` / `unmatched` | 已确认 / 部分节 / 候选 / 未匹配；`isMatched` 只认前两者 |
| `RecordScope` | `completeVerses` / `partialVerse` / `mixed` / `unknown` | 片段覆盖的节是否完整 |
| `BoundaryReason` | `silence` / `maxDuration` / `stopped` / `unknown` | 片段结束原因 |
| `TranslationSourceKind` | `curatedEdition` / `machineCanonical` / `machineAsr` | 译文来源三路径 |
| `TranslationStatus` | `pending` / `running` / `done` / `failed` / `modelMissing` | 译文状态；`canRetry` 只认后两者 |
| `TranslationJobState` | `pending` / `running` / `done` / `failed` | 任务状态 |

`TargetLanguage` 是**类 + 注册表**而不是枚举：可选语言由译本目录决定，
**新增语言不必改代码**。数据库只存 `id`，读取时用注册表还原展示名，
并兼容早期落库的 `zh-Hans` / `en`。

## 7. 翻译裁决与缓存

来源判定（`TranslationCoordinator.resolveInputFor`）的判据是
**有没有匹配到节**，而不是匹配状态是否为 `confirmed`：

```
matches 为空？
  ├─ 是 → machineAsr        输入 = 实际 ASR 转写
  └─ 否 → 查该语言译本
            ├─ 命中（要求每一节都查到）→ curatedEdition      输入 = 标准原文
            └─ 未命中                   → machineCanonical    输入 = 标准原文
```

`inputScope` 随情形落库，界面据此说明译文的适用范围：

| 取值 | 界面文案 | 含义 |
|------|----------|------|
| `fullVerses` | 整节译文 | 片段恰好覆盖完整节 |
| `fullVerseContext` | 整节译文（上下文） | 片段只覆盖半节，展示整节译本作上下文，不冒充该片段精确译文 |
| `confirmedRange` | 仅已确认范围 | 半节机翻，只翻译已确认词范围 |
| `asr` | 输入为识别转写 | 未匹配，仅译转写文本 |

缓存键由「稳定哈希 + corpusId + corpusVersion + 目标语言 + 提供方 + 引擎代号 + 代数 +
预处理版本」组成，用 FNV-1a 64 位哈希；相同输入命中缓存不重复调用引擎。

失败分类：`modelMissing` / `offlineDownloadUnavailable` 判定为
`TranslationStatus.modelMissing`（语言包缺失，任务回到 `pending` 等待重试），
其余失败记为 `failed`。**任何时候都不降级到云翻译，也不生成假译文。**

## 8. 与旧 Demo 的关系

旧 Demo（`lib/quran_offline/`）不再是产品首页，但仍是**开发诊断入口**，
承载三类回归能力：

1. **实时跟读**：滑窗流式识别 + 稳定锁定 + 提词器；
2. **语料准确度校核**：不经麦克风，直接对 WAV 跑实际 ASR 并与固定原文比对；
3. **流式诊断**：按实时节奏灌音，观察章节匹配、稳定事件与窗口推进。

它使用**旧 6236 节经文库**（`assets/quran_offline/quran.json`），
与广播功能的全经库相互独立、互不读取。
两者的共享部分只有纯 Dart 算法与 ASR 模型资产。

详见 [旧 Demo 与流式链路](legacy-demo.md)。
