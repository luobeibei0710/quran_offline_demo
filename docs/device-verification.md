# 真机验收记录

> ## ⏳ 状态：待补充
>
> 本文的结构、方法、命令与记录表已就位，**实测数据待本轮真机测试完成后回填**。
> 在记录补齐之前，广播链路**不得声称已验收**。

本文是广播链路（外放 → 空气 → 麦克风 → 断句 → 匹配 → 翻译 → 落库）唯一的验收记录载体。
不依赖麦克风的离线准确度另行记录在 [离线语料准确度](offline-accuracy.md)，
算法口径见 [经文匹配与指标](matching.md)。

## 1. 验收矩阵

| # | 维度 | 目标 | 状态 |
|---|------|------|------|
| 1 | 连续收听时长 | ≥ 30 分钟不间断，无崩溃、无内存失控 | 待补充 |
| 2 | 诵读者覆盖 | ≥ 3 位不同诵读者 | 待补充 |
| 3 | 章节覆盖 | 长章 / 短章（如纯洁章 22 s）/ 含重复节章（至仁主章 31 次）/ 极短节密集章（开端章） | 待补充 |
| 4 | 库外负样本 | 求护词、解说、非古兰经内容 → 必须未匹配，不得猜经文 | 待补充 |
| 5 | 定位正确性 | 匹配节号随音频**严格单调递增**，无跳跃、无回退 | 待补充 |
| 6 | 译文来源 | 命中经文时 `curatedEdition` 占比应接近 100% | 待补充 |
| 7 | 延迟 | 端到端（片段结束 → 落库）P95 | 待补充 |
| 8 | 拾音条件 | 距离 / 音量 / 底噪至少两档对照 | 待补充 |
| 9 | iOS 真机 | 本条链路在 iOS 上跑通（模拟器不可用，只能真机） | 待补充 |

## 2. 测试设置

### 2.1 设备

| 项 | 值 |
|---|---|
| 被测设备（Android） | 待补充 |
| 被测设备（iOS） | 待补充 |
| 音源设备 | 待补充 |
| 音频素材 | `resources/broadcast_quran/full_recitation/`（Alafasy 全经整章，114 章，约 1.7 GB，约 29.8 小时） |
| 被测包 | 待补充（记录版本号与 APK md5） |
| 播放方式 | 音源设备扬声器外放，被测设备麦克风拾音 |

> **硬约束：ASR 按正常语速训练，不能加速播放。**
> 加速会破坏识别，结果不代表真实场景。因此完整跑一遍全经需要约 30 小时，
> 验收应按 §1 的维度分段设计，而不是指望一次跑完。

### 2.2 每次测试前的基线

```bash
# 清空日志
adb -s <SERIAL> logcat -c

# 记录起始记录数（确认空库或记下起点）
adb -s <SERIAL> exec-out run-as com.llvision.quran_offline_demo \
  cat files/broadcast_quran.db > /tmp/snap-before.db
sqlite3 /tmp/snap-before.db "select count(*) from utterance_records;"
```

库位置：应用支持目录下的 `broadcast_quran.db`（非缓存目录，异常不会自动清库）。

## 3. 记录方式（可重复）

### 3.1 数据库快照

在测试过程中随时取快照，离线分析：

```bash
adb -s <SERIAL> exec-out run-as com.llvision.quran_offline_demo \
  cat files/broadcast_quran.db > /tmp/snap.db

# 记录总数
sqlite3 /tmp/snap.db "select count(*) from utterance_records;"
# 状态分布
sqlite3 /tmp/snap.db "select match_status, count(*) from utterance_records group by 1;"
# 覆盖到的章节（判断有无整章丢失）
sqlite3 /tmp/snap.db "select distinct surah from record_matches order by 1;"
# 译文来源分布
sqlite3 /tmp/snap.db "select source_kind, count(*) from record_translations group by 1;"
# 译文是否有 edition_id（区分人工译本与机翻）
sqlite3 /tmp/snap.db "select source_kind, count(*) filter (where edition_id is not null) from record_translations group by 1;"
# 质量分布：定位异常低的章节
sqlite3 /tmp/snap.db "select r.display_sequence, m.surah, m.ayah, mt.f1, mt.strict_wer
                      from utterance_records r
                      left join record_metrics mt on mt.record_id = r.id
                      left join record_matches m on m.record_id = r.id
                      order by mt.f1 asc limit 20;"
```

### 3.2 日志

```bash
adb -s <SERIAL> logcat -d | grep -E "QuranOrtBridge|\[Broadcast\]|BroadcastSession"
```

### 3.3 逐条记录（事件级）

对关键片段，逐条记录「音频位置 → 匹配节范围 → 状态 → 指标」：

| 序号 | 音频位置 / 时间 | 匹配节范围 | 状态 | 覆盖率 | 解释比例 | 置信 | F1 | 严格 WER | 译文来源 | 备注 |
|---|---|---|---|---|---|---|---|---|---|---|
| 待补充 | | | | | | | | | | |

### 3.4 汇总（章节级）

| 维度 | 记录 |
|---|---|
| 覆盖章节数 / 应有章节数 | 待补充 |
| `confirmed` 占比 | 待补充 |
| `partial` 占比 | 待补充 |
| `candidate` 占比 | 待补充 |
| `unmatched` 占比 | 待补充 |
| 匹配节号是否严格递增（断裂点列表） | 待补充 |
| `curatedEdition` 译文占比 | 待补充 |
| 崩溃 / ANR 次数 | 待补充 |
| 数据库体积增长 | 待补充 |

### 3.5 性能

| 阶段 | P50 | P95 | 备注 |
|---|---|---|---|
| 模型加载 | 待补充 | — | 含首次解压 |
| 预览匹配（1 s 周期） | 待补充 | 待补充 | 应与片段长度相关 |
| 片段终稿（结束 → 落库） | 待补充 | 待补充 | 含转写 + 匹配 + 落库 |
| 译本查表 | 待补充 | 待补充 | 首次加载该语言后应命中内存 |
| 机器翻译（ML Kit） | 待补充 | 待补充 | 仅未匹配片段需要 |

## 4. 判据说明（怎么读结果）

| 判据 | 为什么用它 |
|------|------------|
| **节号严格单调递增** | 最强的定位证据：一旦错位区间就会立刻断裂，且不受 F1 波动影响 |
| 覆盖率 / 解释比例 | 判断片段被解释了多少、候选被听到多少；两者要一起看 |
| F1 / 严格 WER | 转写与候选原文的一致性；F1 是容错口径，WER 是精确口径，**不能互相换算** |
| 译文来源分布 | `curatedEdition` 说明查表路径生效；`machineAsr` 出现在未匹配片段上是设计内兜底 |
| `unmatched` 占比 | 过高说明拾音或断句有问题；但库外内容（求护词、解说）本就应当未匹配，需分开统计 |

**应当区分「拾音问题」与「算法问题」**：真机外放的收音质量会显著影响指标，
因此在归因之前，先用 [离线语料准确度](offline-accuracy.md) 的同一条链路确认算法侧没有退化。

## 5. 完成后的记录方式

1. 按 §3.3 / §3.4 / §3.5 的表格填入实测值；
2. 把机器可读证据（DB 快照、日志切片、指标 JSON）归档到 `docs/evidence/`；
3. 更新 [README 的真机验收记录章节](../README.md#真机验收记录) 的状态列；
4. 明确写出**没有验证的部分**，不要把「部分通过」写成「通过」。

---

## 附：既有对照记录

以下是**早期轮次**的真机观测，供本轮重测时对照。
当时的匹配库已切换为全经，但验收矩阵本身并未补齐，
因此**这些数字不构成当前验收结论**。

### 第 19 章（麦尔彦）连续诵读，10 条记录

| 序号 | 状态 | 范围 | 匹配节 | F1 | WER |
|---|---|---|---|---|---|
| 1 | unmatched | unknown | — | 0.278 | 3.000 |
| 2 | partial | mixed | 19:3–5 | 0.745 | 0.406 |
| 3 | partial | partialVerse | 19:5–7 | 0.630 | 0.667 |
| 4 | partial | mixed | 19:7–9 | 0.706 | 0.475 |
| 5 | candidate | mixed | 19:8–11 | 0.539 | 0.712 |
| 6 | partial | mixed | 19:12–14 | 0.850 | 0.526 |
| 7 | partial | mixed | 19:14–17 | 0.806 | 0.361 |
| 8 | partial | mixed | 19:17–19 | 0.708 | 0.393 |
| 9 | partial | mixed | 19:19–21 | 0.855 | 0.314 |
| 10 | candidate | partialVerse | 19:21 | 0.278 | 0.933 |

匹配节范围依次为 `19:3–5 → 19:5–7 → 19:7–9 → 19:8–11 → 19:12–14 → 19:14–17 →
19:17–19 → 19:19–21 → 19:21`，**严格随音频推进、无跳跃也无回退**，
这正是需要在本轮重测中复现的定位证据。

序号 1 未匹配符合预期：该段从求护词开始，开头是 `19:1`（`كهيعص`，单节 1 词）这类极短内容，
证据不足时不猜经文。

### 全经连续播放的首个快照

| 时间 | 记录数 | 已覆盖章节 | 状态分布 | 译文来源 |
|---|---|---|---|---|
| 起始 + 2 分钟 | 4 | 1, 2 | partial 2 / confirmed 1 / candidate 1 | `curatedEdition` 100% |

第 1 章观察到的行为：`1:6-7` 在音频推进过程中先是 `partial`，
念到节尾后升为 `1:7` `confirmed`（覆盖 0.94、置信 0.80）；
另出现过一次 `candidate`（解释比例 0.53 低于 0.60 门槛但覆盖率 0.94）——
这是设计内的保守行为：覆盖够但解释比例不足时不宣称确认，而是标候选。
