# 三栏实时同步 iOS 真机实测（2026-09-23）

## 范围与来源

- 设备：iPhone 17 Pro（`iPhone18,1`），iOS 26.6 `23G71`；设备标识仅在本地保存。
- 应用：分支 `codex/live-three-column-sync` 的 Debug 构建，目标译文为**简体中文**；签名团队与描述文件信息仅在本地保存。
- 启动方式：`flutter run -d <UDID>`。`devicectl device process launch` 无法启动
  Debug 包（原生报 `Cannot create a FlutterEngine instance in debug mode without
  Flutter tooling or Xcode`，进程随即 `signal 11`）。
- Dart defines：`quran_auto_run_seconds=900`（依赖就绪自动开麦、到点自动停）、
  `quran_latency_trace=true`、`quran_dump_pcm=true`。
- 音源：手机近场外放的诵读音源。设备 PCM 转储覆盖 182.7 秒，rms 0.011–0.025、
  有声帧占比 53%–93%；从识别结果看是**第 78 章的连续诵读**，不是 Android 那份
  `012.mp3`（第 12 章），因此两端**不做逐节数值对比**。
- 原始应用事件日志保留在本地 `live-three-column-ios-2026-09-23.txt`，不进入公开仓库；其中只保留
  `[Broadcast]` 与 `[BroadcastLatency]` 行，不含音频 PCM。

## 本轮修掉的三个 iOS 阻塞点

| 问题 | 现象 | 处理 |
| --- | --- | --- |
| `Podfile` 未开 `PERMISSION_MICROPHONE=1` | `Permission.microphone.request()` 直接返回 denied 且**不弹系统授权框**，界面停在「未授予麦克风权限」，`start()` 返回 false | `post_install` 里只给 `permission_handler_apple` 目标加该宏并 `pod install` |
| 长测期间息屏 | iOS 锁屏会把应用挂起、收音随之中断 | `AppDelegate.swift` 新增 `quran_offline/screen` 通道，走 `UIApplication.shared.isIdleTimerDisabled` |
| ML Kit 语言包下载必失败 | `ar 语言包下载失败：Model manager deallocated during download` | 见下节 |

ML Kit 那条是 `62815c7` 遗留的**未修完**问题：那次只把崩溃降级成可恢复错误，下载
本身仍然失败。根因在插件侧——`google_mlkit_translation` 0.14.0 的
`GoogleMlKitTranslationPlugin.swift` 每次 `manageModel` 都 `GenericModelManager()`
新建并覆盖插件字段，旧实例立即被 ARC 释放；准备下载 `ar` 时后台翻译任务并发调用
`statusFor → isModelDownloaded`，把正在下载的 manager 挤掉。Dart 侧「把 ModelManager
改成长生命周期字段」**无效**，因为它只是 Dart 代理，管不到原生实例。

修复（`mlkit_translation_engine.dart`）：所有原生 manager 调用排到一条串行 Future
链上；下载期间 `_pendingBcp` 非空时 `statusFor` 直接返回 `downloading`，不再触碰原生。

## 结果与指标

| 项 | 数值 | 说明 |
| --- | ---: | --- |
| 终稿记录 | 267 | 跨 3 段会话（分别保存 101 / 64 / 11 条），含多次重启动 |
| 状态分布 | unmatched 221、candidate 30、partial 11、confirmed 5 | 46 条有经文范围 |
| 译文任务 | machineAsr 286、curatedEdition 57 | 命中校订译本 57 次，全部为 `chinese_makin` |
| 翻译失败 | **0** | 修复后再无 `modelMissing` |
| 预览帧 | 551 | `previewPublished` 事件 |
| 译文上屏 / 丢弃 | 38 / 25 | `translationPublished` / `translationDropped` |

时延（`[BroadcastLatency]` 与 `[BroadcastLatencyTrace]`，最近秩百分位）：

| 指标 | 样本数 | P50 | P90 | 最大值 | 计时范围 |
| --- | ---: | ---: | ---: | ---: | --- |
| 音频到预览帧 | 490 | 81 ms | 224 ms | 417 ms | 最新音频块进入控制器 → UI 帧回调 |
| 终稿处理到保存 | 246 | 68 ms | 168 ms | 584 ms | 终稿处理开始 → 记录落库 |

这两个数字**不是**用户听到声音到三栏全部出现的端到端时延（不含断句等待与译文
异步回填），也**不能**与 Android 那份直接对比：Android 的音源是第 12 章数字外放，
iOS 这份是近场外放的第 78 章，拾音条件与内容都不同。

## 连续识别的证据

有经文范围的 46 条中，第 78 章呈现连续推进：

```
78:14 → 78:15–16 → 部分 78:17–18 → 78:18 → 78:19 → 78:20 →
部分 78:21–23 → 部分 78:23–25 → 部分 78:27–30 → 78:30 → 78:31–34 → 78:36 → 78:37
```

其余为 `111:5`、`56:52`、`109:2`、`114:3`、`5:38`、`100:10`、`88:11` 等零散命中，
以及 221 条 unmatched（多为非诵读的环境声片段）。`114:3` 为 `confirmed /
completeVerses`，F1 0.750。

**结论**：iOS 真机广播链路（麦克风实采 → 断句 → 匹配 → 译文）**已跑通**，权威译本
（62 种内置译本）与 ML Kit 机器翻译两条译文来源在 iOS 上都验证可用，全程无崩溃、
无未分类异常。

## 仍未覆盖

- 与 Android **同一音源、同一拾音条件**下的逐节一致性对比（本次 iOS 是第 78 章）。
- ≥30 分钟连续稳定性：iOS 本次最长一段约 15 分钟窗口，且中间被多次重新启动打断。
- 62 种译本只验证了中文（`chinese_makin`）；其余语言的译本读取与 ML Kit 语言包
  下载未逐一验证。
