# 离线语料准确度验收

本文记录**不经麦克风**的端侧实际 ASR 准确度：把内置的多节连续诵读 WAV
直接喂给模型，按声学暂停切段、逐段做真实 CTC 解码，再与**推理前已冻结**的参考答案逐词比对。

这条路径的价值在于**把抓音质量与模型能力分开**：真机外放的收音质量会显著影响指标，
而这里测的是「给定同一段音频，模型与算法到底做到什么程度」。

麦克风实时链路与真机验收见 [真机验收记录](device-verification.md)；
匹配算法与指标口径见 [经文匹配与指标](matching.md)。

## 1. 结论

三段内置语料在**主机、Android 真机、iOS 真机**三条环境上得到完全一致的指标，
容错 F1 / 准确率 / 覆盖率均 ≥ 0.95，高于 0.90 的自动门禁：

| 语料 | 参考 / 转写词数 | F1 | 准确率 P | 覆盖率 R | 严格 WER | 自动分段数 |
|------|-----------------|----|----------|----------|----------|------------|
| `36:1-5` | 12 / 12 | 0.958333 | 0.958333 | 0.958333 | 0.166667 | 5 |
| `55:1-13` | 43 / 43 | 0.976744 | 0.976744 | 0.976744 | 0.139535 | 13 |
| `67:1-11` | 122 / 122 | 0.967213 | 0.967213 | 0.967213 | 0.163934 | 16 |

**指标边界（必须说清楚）**：

- F1 / P / R 沿用 `WordAlignment` 的**容错口径**，近似词计半分，
  因此**不是严格逐词准确率**；
- 严格 WER 另按精确词计算替换 / 缺失 / 多余，当前约 14%–17%，
  差异同时来自奥斯曼体与现代阿拉伯书写体的书写差异以及真实解码错误；
- 没有使用未参与调试的留出集，**不能据此报告泛化准确率**；
- 结论限于这三段既有回归录音，不代表任意诵读、任意诵读者、噪声麦克风或实时跟踪已达标。

## 2. 三环境对照

| 环境 | 设备 / 方式 | 单条处理耗时（不含模型加载） | 证据 |
|------|-------------|------------------------------|------|
| 主机 | macOS + ORT 1.22（`host_ort_server.py`，仅 `127.0.0.1`） | 命中推理缓存，不作为性能口径 | [offline-accuracy-host.json](evidence/offline-accuracy-host.json) |
| Android 真机 | Redmi 24117RK2CC / Android 16 / arm64-v8a，debug 包 + 无头验收入口 | 0.88 s / 2.65 s / 4.88 s | [offline-accuracy-android.json](evidence/offline-accuracy-android.json) |
| iOS 真机 | iPhone 17 Pro（iPhone18,1）/ iOS 26.6，release 包 + 无头验收入口 | 0.57 s / 1.74 s / 3.27 s | [offline-accuracy-ios.json](evidence/offline-accuracy-ios.json) / [控制台日志](evidence/offline-accuracy-ios-console.txt) |

关键一致性：

- 三段的 F1、P、R **两端差值均为 0**，参考词数、转写词数与自动分段数也相同；
- Android 内置单节样本 5/5，iOS 同为 5/5；
- iOS 与 Android 使用的模型运行时 SHA-256 相同
  （`2d35a410…d716c`），排除了陈旧模型缓存的影响；
- 两端原生桥均锁定 ONNX Runtime 1.22.0，共用同一份 Dart 转录与评分逻辑。

> Android 为 debug 包、iOS 为 release 包，耗时**不作为跨平台性能门槛**，
> 只比较识别指标。

## 3. 实现要点

### 3.1 分段

`OfflineTranscriber`：

- 用 20 ms 帧 RMS 找声学暂停；低能量阈值为 `max(1e-5, 中位 RMS × 0.4)`；
  连续低能量至少 **0.35 s** 时在暂停**中点**切分；
- 每段至少 2 s，末段至少 1 s，避免生成过短片段；
- 切点来自音频，**不来自章节标签**：`67:1-11` 被切成 16 段而不是强行按 11 节分段；
- 没有足够暂停且连续段超过 30 s 时，才使用 30 s 窗口、8 s 重叠的有界回退，
  并按 CTC 帧时间戳合并（`TimedTranscript.update`）。

### 3.2 参考答案冻结

参考答案在推理**之前**就固定，评测不会根据预测结果择优：

- 内置语料由 `corpus/manifest.json` 的 `includesBismillah` 声明音频是否含章首太斯米；
- 当前三段均不含该前缀，因此参考词数是 12 / 43 / 122；
- 不接收识别结果的任何回写，不存在「在含/不含太斯米版本里选较高 F1」的可能。

### 3.3 转写口径

默认离线校核的转写稿是**模型实际 CTC 输出**：暂停切段互不重叠，
超过 30 s 的无停顿段才用带时间戳的重叠窗口拼接。
转写器只接收音频、模型输出和词表，**不查询期望章节或参考原文**。

## 4. 复现

### 4.1 主机

```bash
# 1) 启动本机推理服务（只监听 localhost，模型与音频不上传）
tools/quran_offline/.venv122/bin/python tools/quran_offline/host_ort_server.py --port 18765

# 2) 另一个终端：任一录音的 F1/P/R < 0.9 即失败
QURAN_ORT_URL=http://127.0.0.1:18765 \
QURAN_BENCH_OUT=/tmp/quran-offline.json \
flutter test tool/offline_benchmark_test.dart --reporter expanded
```

需要先有内置语料 WAV：

```bash
bash tools/quran_offline/download_corpus.sh
```

### 4.2 真机（无头验收入口）

页面路径依赖渲染帧，设备息屏或系统拒绝自动化注入时容易中断。
应用因此提供一个**不与 UI 耦合**的入口：它直接调用与页面相同的 `OfflineTranscriber`，
逐条打印 `OFFLINE_RESULT {json}`，末尾打印 `OFFLINE_COMPLETE passed=N total=M`。

```bash
# Android
flutter build apk --debug --target-platform android-arm64 --dart-define=quran_headless_corpus=true
adb install -r --no-streaming build/app/outputs/flutter-apk/app-debug.apk
adb logcat -c && adb shell am start -n com.llvision.quran_offline_demo/.MainActivity
adb logcat -d | grep -E "OFFLINE_RESULT|OFFLINE_COMPLETE"

# iOS（release；需保持设备解锁、应用前台）
flutter build ios --release --dart-define=quran_headless_corpus=true
xcrun devicectl device install app --device <UDID> build/ios/Release-iphoneos/Runner.app
xcrun devicectl device process launch --device <UDID> --terminate-existing --console com.llvision.quranOfflineDemo
```

`<UDID>` 需替换为实际设备标识，用 `xcrun devicectl list devices` 查询。

普通交付包不带该开关。iOS 侧 release 构建下 Dart `debugPrint` 在
`devicectl --console` 中不可见，因此仅在开关开启时把日志经 MethodChannel
`acceptanceLog` 转发为原生 `NSLog`——**该改动只影响日志转发，不改变转录算法或评分**。

### 4.3 页面路径

开发诊断页（首页右上角扳手图标）→「语料验证」→ 保持「离线校核」Switch 打开 → 点一条语料，
跑完自动进入比对页；右上角「全部跑一遍」批量校核，逐条要求容错 F1、准确率、覆盖率均 ≥ 0.9。
关闭 Switch 才进入旧流式章节重建诊断，见 [旧 Demo 与流式链路](legacy-demo.md)。

## 5. 分段与窗口行为（单测覆盖）

| 行为 | 验证点 |
|------|--------|
| 声学暂停分段 | 切点落在暂停中点、最短段与尾段下限 |
| 长段有界回退 | 30 s 窗口 / 8 s 重叠 / 按帧时间戳合并 |
| 全静音 | 不推理、不产生伪句 |
| 重叠去重 | 重叠音频按时间去重，**真实不同时刻的重复词保留** |
| 半词修订 | 可修订尾部不提交半词 |
| 固定参考 | 只使用语料标注的固定原文，不接收预测结果 |
| 严格 WER | 替换 / 缺失 / 多余分别统计，空参考边界 |

## 6. 相关说明

### 6.1 是否需要 arabic_reshaper

**不需要预先 reshape，也不能靠 reshape 修复声学错误。**

页面的阿拉伯文卡片使用 RTL 排版，正常逻辑阿拉伯字符交给文本渲染引擎处理
（参见 [Flutter TextDirection](https://api.flutter.dev/flutter/dart-ui/TextDirection.html)）。
实际扫描当前 `quran.json` 与 `vocab.json`，两者的 Arabic Presentation Forms-A/B 字符数均为 0。

但外部旧式文本可能包含这些字符，因此 `QuranText.normalize` 会先按 Unicode 官方兼容分解
把表现形式还原为逻辑字符（例如 `ﷲ`（U+FDF2）→ `الله`、lam-alef 连字 → 对应字母），
再执行去音标与字母变体归一化；**不把正常输入正向转换为表现形式**。

映射来自 Unicode 15.0.0，覆盖 731 个有标准分解的表现形式码点；
无标准分解的装饰符不猜测展开。漂移检查：

```bash
python3.12 tool/generate_arabic_forms.py --check
```

### 6.2 数据来源与哈希

| 资产 | SHA-256 |
|------|---------|
| `fastconformer_full_mixed_ort122.onnx` | `2d35a41040d4132f7d2c43fb457d539ac65a058d00fd7114ed317927212d716c` |
| `corpus/manifest.json` | `43b8521fd898a587c2b9c6d37d7e02fde0465fd1d8b94760153e7650a2ac8cd3` |
| `corpus_036_001_005.wav` | `1ab6c5047f1e7fb45e4efa095df951121c09df1038d92414404e0cd2022b5edb` |
| `corpus_055_001_013.wav` | `5e3c52978aceac0bc3765c1f61f4fab1a289257ecd724be2468510ee10fe1ec1` |
| `corpus_067_001_011.wav` | `6c1ee70f1b380b99e985613c8b48202d718693384c83cb30454a40a999a23a15` |

内置语料由 `tools/quran_offline/download_corpus.sh` 从 Quran.com CDN 取逐节诵读并拼接，
**不入版本库**；模型同样不入库，用 `download_assets.sh` 获取。

例外只有共享词表 `assets/quran_offline/vocab.json`（21 KB）：广播侧的单元测试加载语料库时
需要它，因此**随仓库分发**，保证干净 clone 下 `flutter test` 不依赖 103 MB 模型下载。

## 7. 后续范围

若下一步要求「严格逐字准确率也 ≥ 90%」，需分别解决可解释的书写体映射与剩余声学错误，
并保留 raw ASR 与规范化经文两个独立输出——不能靠放宽阈值或修改参考来抬分。

若要求实时任意位置定位，则需继续做跨窗口位置跟踪、歧义重定位，
并准备未参与调试的保留测试集；本页的离线校核不替代这些工作。
