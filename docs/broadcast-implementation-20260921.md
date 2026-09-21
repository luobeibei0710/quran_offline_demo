# 广播识别与离线翻译：实施交付记录（2026-09-21）

本文按 [实施方案](broadcast-transcription-translation-plan-20260920.md) 的 P0–P8
记录**实际写进代码的内容、可复现的验证证据，以及明确没有验证的部分**。

状态速览：

| 项 | 状态 |
|---|---|
| 独立三章新库（41 节）接入并隔离旧库 | 已完成，有自动化证据 |
| CTC token 表生成工具 + 口径偏差量化 | 已完成，偏差如实记录 |
| 数据模型 / SQLite / 迁移 / 幂等 / 重启恢复 | 已完成，12 项测试 |
| 匹配与指标（含太斯米歧义修复） | 已完成，9 项测试 |
| 会话控制器（断句 / 终稿 / 停止 drain） | 已完成，9 项测试 |
| 翻译来源策略 / 缓存 / 重试 / 迟到防护 | 已完成，9 项测试 |
| 页面（首页三栏 / 历史 / 详情 / 诊断） | 已完成，未做真机截图 |
| Android 构建 | 已通过（含 sqflite + ML Kit 原生依赖） |
| iOS 构建 | 已通过（pod 解析 + Xcode 编译） |
| **广播真机收音 → 翻译 全链路验收** | **未做** |
| **新库匹配阈值真实音频标定** | **未做** |

## 1. 新库：独立资源与强制隔离

### 1.1 资源与来源

原文来自 Tanzil 官方下载（Uthmani 1.1），独立提取第 1、67、112 章共 41 节：

| 文件 | 说明 |
|---|---|
| `assets/broadcast_quran/tanzil_1_1/verses_001_067_112.json` | 41 节，`sourceText` 逐字保留上游文本 |
| `assets/broadcast_quran/tanzil_1_1/verse_ctc_tokens.json` | 本仓库生成的 CTC token 表（41 节 / 146 跨度） |
| `assets/broadcast_quran/tanzil_1_1/manifest.json` | corpusId、版本、上游 SHA-256、许可、口径与偏差 |
| `assets/broadcast_quran/tanzil_1_1/NOTICE.txt` | Tanzil 版权区块 |

单独复用（**允许**）的模型侧资源只有 `assets/quran_offline/vocab.json` 与
`assets/quran_offline/fastconformer_full_mixed_ort122.onnx`。

### 1.2 隔离是有自动化证据的，不是口头承诺

`test/broadcast_corpus_test.dart` 用一个记录所有资产请求的 bundle 加载新库，断言
**没有任何请求命中 `quran.json` 或 `quran_ctc_tokens.json`**，并断言匹配器只在
41 节内检索、其他章返回 null。这比「代码里没写」强，因为它在改动时会失败。

### 1.3 CTC token 表：口径偏差必须说清楚

旧库的 `quran_ctc_tokens.json` 由上游 unigram 模型生成，**其 token 分数未公开**，
因此无法逐 token 复现。本仓库用确定性分词（最少 token 数，同级取更长片段）
从同一词表重新生成：

```bash
python3 tools/broadcast_quran/generate_verse_tokens.py --verify-legacy
# strategy=min-token: single 1296/6236 exact, span 590/18024 exact
```

即**单节逐 token 完全一致率约 21%**。生成的序列 round-trip 全部正确（解码回原文
逐字相同），但**排序分数的绝对值口径与旧库不同**，所以：

- 新库的跨度惩罚与可信度阈值必须用真实广播音频重新标定；
- 代码中这些常数已标注为「待标定起点」，未宣称为已验收值。

## 2. 数据模型与持久化

SQLite（`sqflite`），schemaVersion 1，库文件位于应用支持目录（非缓存目录），
异常不自动清库。表：`recognition_sessions`、`utterance_records`、`record_matches`、
`record_metrics`、`record_translations`、`translation_jobs`、`translation_cache`、`settings`。

关键约束与实测：

| 规则 | 实测 |
|---|---|
| 业务去重键 `(sessionId, utteranceId, revision)` | 同一片段反复回调只更新一条记录 |
| 展示序号独立计数器 | 删除记录后不回填空洞（1,2,3 → 删 2 → 新建仍是 3(新) 不回收旧号） |
| 三类文本 + 指标 + 任务同事务写入 | 事务失败不会只落一半 |
| 无可信参考时指标为 null | 界面显示「不可用」而不是 0 分 |
| 迟到译文防护 | `revision` 或 `targetLanguage` 不符时拒绝写入；记录已删则丢弃 |
| 级联删除 | 删记录同时清理匹配、指标、译文与任务 |
| 重启恢复 | 残留 `running` 任务重置为 `pending`，记录保留，重试不建新历史 |

## 3. 匹配与指标：修掉一个真实的算法缺陷

新库只有 3 章 41 节，太斯米在 `1:1`、`67:1`、`112:1` 都出现，冲突概率远高于旧库。
实测发现：

> 音频 `بسم الله الرحمن الرحيم قل هو الله احد`（112:1）会被判成 **`1:1`（纯太斯米）**。

原因是 CTC 按帧归一化只衡量「候选能否解释音频」，不衡量「音频能否被候选解释」：
短候选只用高概率位置参与平均，因而占优。

修复：在 CTC 精排后增加**候选二次裁决** —— 先按「转写被候选解释的比例」(precision)
分带，同带内再比 CTC 排序分；可信度 = 0.7×解释比例 + 0.3×候选差距。这同时满足需求中
「相同开头、太斯米、极短节要允许歧义状态」的要求。

其他已实现的判定均有测试：

- 只识别到太斯米 → 拒识（不确认章节）；
- 库外内容 → 拒识，保留真实转写，不返回「最相似经文」；
- 纯噪声 → 不建伪句；
- 半节 → `partialVerse`，不补全未听到内容；
- 跨节连读 → 保留多个引用，不只显示首节；
- 逐词对照存为 JSON 快照，详情页离线复现，不重新计算。

## 4. 实时会话

- 断句：静音约 1.2 秒、最短 0.8 秒、最长 30 秒，超长强制切分保留 1 秒重叠；
- 噪声判据不用固定绝对值也不假设远场信号强：本底**不高于绝对下限起步**、
  只向下跟随、向上每轮 ×1.02 —— 起步若取首块音频，实测会让整场录音 0 片段；
- 单模型串行：预览与终稿互斥，终稿优先；终稿队列上限 3，超载丢弃预览并计数提示；
- 停止幂等：先停采样 → 等在途推理 → 处理剩余片段 → 落库 → 更新状态；
- 目标语言仅在空闲时可切换，运行中禁止（避免一句中途混语言）。

## 5. 翻译

- 引擎固定 ML Kit（`google_mlkit_translation` 0.14.0，原生 MLKitTranslate 8.0.0）；
  未引入 Hy-MT2 / llama.cpp。
- 来源策略 `editionPreferredWithMachineFallback` 已按三段实现并有测试：
  `curatedEdition` / `machineCanonical` / `machineAsr`。
- **当前没有可分发的中英校订译本**，`NoCuratedEditionRepository` 恒返回 null，
  全部走机器翻译并带来源标记；接口与来源标签保留，拿到授权数据即可接入，不伪造译本。
- 标准原文输入按上游原样切片（保留音标与词序），不使用为模糊匹配折叠字符的
  `QuranText.normalize` 输出；半节只翻译已确认词范围，标记 `confirmedRange`。
- 缓存键 = 输入哈希 + corpusId + corpusVersion + 目标语言 + 提供方 + 引擎代号 + 预处理版本；
  实测相同输入命中缓存不重复调用引擎。
- 缺包明确失败（`modelMissing`）且任务保留待重试，**不降级到云服务**。

## 6. 页面

- 首页：三卡（识别转写 / 匹配经文 / 目标译文）+ 目标语言 + 资源状态 + 底部开始/停止；
  阿拉伯卡局部 RTL，不运行 `arabic_reshaper`；长文本可滚动、可选择复制。
- 历史：稳定序号 `#000123`、分页 50、语言与状态筛选、删除二次确认。
- 详情：三类文本快照 + 指标 + 逐词比对 + 开发诊断折叠 + 重试与追加语言。
- 旧 Demo 保留为「开发诊断」入口（首页右上角），启动时**不再**自动跑内置样本自测。

## 7. 可复现的验证命令与结果

```bash
flutter analyze --no-pub
# No issues found!

flutter test
# 189 个用例全部通过（旧功能 142 + 广播新增 47）

python3 tools/broadcast_quran/generate_verse_tokens.py --verify-legacy
# strategy=min-token: single 1296/6236 exact, span 590/18024 exact

flutter build apk --debug --target-platform android-arm64
# ✓ Built build/app/outputs/flutter-apk/app-debug.apk（约 300 s）

export PATH="/usr/local/bin:$PATH" LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
(cd ios && pod install)
# Installing MLKitTranslate (8.0.0) … Installing onnxruntime-objc (1.22.0)
# Pod installation complete! 7 dependencies from the Podfile and 21 total pods installed.
flutter build ios --debug --no-codesign
# Xcode build done. 49.7 s → ✓ Built build/ios/iphoneos/Runner.app
```

`pod install` 结果证明 **onnxruntime-objc 1.22.0 与 MLKitTranslate 8.0.0 可以共存**，
这是 P1 最担心的原生冲突。

## 8. 未验收项与风险（必须如实对待）

1. **广播收音全链路完全未验收**。没有任何一条真实「外放 → 空气 → 麦克风」的
   端到端记录；当前所有匹配与翻译结论都来自合成声学证据与假引擎。实施方案 §11.3
   的验收矩阵（≥30 分钟、≥3 位诵读者、库外负样本、P95 延迟）一项都没跑。
2. **新库阈值未标定**。见 §1.3，token 表口径与上游不同，`BroadcastMatchConfig`
   的常数是起点值。用真实音频标定前，不能声称新库的拒识与确认行为已达验收标准。
3. **翻译质量未知**。ML Kit 未在真机运行过；阿→中经英语中转，中文效果必须单独评估，
   不能用英文结果推定。语言包需动态下载（不能随包分发），且**端侧翻译模型依赖
   Google Play 服务**，无 GMS 的设备上能否下载与运行尚未验证。首次缺包且断网时
   会明确提示「缺少离线语言包」。
4. **iOS 模拟器不可用**：ML Kit 的传递依赖（GoogleMLKit / MLKitTranslate / MLImage /
   MLKitVision / MLKitCommon）声明不支持 arm64 模拟器，构建时会给出明确警告。
   iOS 侧只能真机验证。
5. **iOS 部署版本从 15.1 提升到 15.5**（ML Kit podspec 要求）。`ios/Podfile` 与
   `project.pbxproj` 三处 `IPHONEOS_DEPLOYMENT_TARGET` 已同步；旧库功能未做真机回归。
6. **开端章与纯洁章音频未下载**。`resources/broadcast_quran/audio_candidates/` 只有
   王权章两份整章 MP3（已完整解码、未试听、内容未逐节对齐、再分发条件 pending）。
   因此没有任何真实音频可以驱动新库匹配回归。
7. **译本许可未闭环**。中英译者/版本未选定，`curatedEdition` 路径目前恒空。
8. 后台/锁屏收音、系统内部音频捕获、云同步均未实现（按需求属首期不含）。

## 9. 待决策

| 决策 | 当前处理 |
|---|---|
| 是否允许准备阶段联网下载 ML Kit 语言包 | 默认允许（`allowDownload: true`），运行期不降级云翻译 |
| 新库是否扩展到更多章 | 未扩；当前仅 3 章 41 节，其他章按未匹配处理 |
| 中文/英文校订译本版本 | 未选；未获授权前不打包、不伪造 |
| 广播验收设备与音频素材 | 待定；需要 ≥30 分钟真实外放录音与人工标注 |
