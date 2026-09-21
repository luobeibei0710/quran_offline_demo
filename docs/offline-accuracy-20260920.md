# 离线语料准确度修复与验收（2026-09-20）

本轮目标由用户明确为：先把现有三条离线语料验证做到优秀。`reshape` 指
`arabic_reshaper` 的阿拉伯表现形式字符转换，不是架构重构。

## 验收结果与口径

主机 ORT 1.22 与 Redmi Android 16 真机、真实录音、真实 Dart 识别代码：三条语料的 **F1、容错准确率、覆盖率均超过 0.95**。
转写直接来自模型，不使用经文库替换解码内容，不把期望章节传入识别器。

| 语料 | 参考/转写词数 | F1 | 容错准确率 | 覆盖率 | 严格 WER | 自动分段 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 36:1–5 | 12 / 12 | 0.9583 | 0.9583 | 0.9583 | 0.1667 | 5 |
| 55:1–13 | 43 / 43 | 0.9767 | 0.9767 | 0.9767 | 0.1395 | 13 |
| 67:1–11 | 122 / 122 | 0.9672 | 0.9672 | 0.9672 | 0.1639 | 16 |

原始模型转写、每段音频起止时间、模型/音频 SHA256 见
[机器可读报告](offline-accuracy-20260920.json)。主机时间包含推理缓存，不能用于宣称端侧性能提升。
真机三段处理约 0.9/2.6/4.9 秒（不含模型加载），指标与主机一致，见
[Android 验收记录](offline-android-20260920.json)。

**指标边界：**沿用页面已有 `WordAlignment`：词相似度 ≥0.8 计一致、0.5–0.8 计半分。
因此上述结果不是严格逐字准确率。新增严格 WER 不使用模糊半分，数值越低越好；当前约 14%–16%，
包括奥斯曼体/现代阿拉伯书写差异及真实解码错误。没有采用删除长音字母的“辅音骨架”规则抬高分数。

这是三个既有回归录音的验收，不等于全经文、不同诵读者、噪声麦克风或实时跟踪已经达标。
没有使用未参与调试的留出集，不能据此报告泛化准确率。

## 为什么之前一直低于 0.9

1. **旧输出不是实际转写。** `CorpusRunner.run` 将短滑窗稳定命中的章节查回标准经文并全局去重。
   短句歧义会混入错误章节；同时查回原文会隐藏被匹配章节内部的 ASR 错词。
2. **窗口切断长音。** 同一 28 秒音频，0.75 秒触发的短滑窗反复产生半词、错误续写；整段推理得到完整句。
   增大固定窗口仍不够：30 秒任意切窗时 55:1–13 的 F1 只有 0.8313。
3. **裁窗上限反了。** `_advanceWindow` 注释是“最多裁 60%”，旧实现却为 `max(keep, window*0.4)`。
   实测回归用例 3 秒窗应最多裁 1.8 秒，旧代码裁 2.4 秒。已改成 `min(keep, window*0.6)`。
4. **参考答案事后择优。** 原页面在“完整经文/去太斯米”中选最高 F1。
   新版本由 manifest 的 `includesBismillah` 在识别前固定；当前三段不含该前缀，故参考词数是 12/43/122，
   不再是旧报告的 16/47/126。**新旧表不能直接当作同口径算法增益相减。**

旧流式链路的真实主机回放复现了 36:1–5 的旧 F1=0.7442。
只修裁窗和时间戳拼接没有让短滑窗达标，因此没有把这条路径宣称为已修复的实时方案。

## 最终实现

- `OfflineTranscriber.audioSegmentBounds`：20 ms 帧 RMS，阈值为 `max(1e-5, 中位数×0.4)`；
  低能量持续至少 0.35 秒时在中点切分。最短片段 2 秒，避免生成小于 1 秒的尾片。
  切点来自音频，不来自章节标签；67:1–11 被分为 16 段而非强行按 11 节分段。
- `OfflineTranscriber.segmentBounds`：无足够停顿的长片段使用最多 30 秒窗口、8 秒重叠。
  自然停顿处结算完整段；重叠部分通过 CTC 帧时间戳合并。
- `TimedTranscript.update`：重叠音频按时间去重，真实不同时刻的重复词保留；可修订尾部暂不提交半词。
- `CorpusVerifyPage`：默认“离线校核”，主指标是实际 ASR；关闭开关可进入旧流式章节诊断。
  离线结果不伪造章节命中率。界面同时显示严格 WER。
- `CorpusCatalog.fixedReference`：只使用语料标注固定原文，不接收预测结果。
  manifest 缺少 `includesBismillah` 时保守保留完整参考；自定义音频应提供真实 `.txt` 参考。

## 是否需要 arabic_reshaper

**当前 Flutter 显示不需要预先 reshape，也不能靠 reshape 修复声学错误。** 页面已有 RTL 设置，
正常使用逻辑阿拉伯字符交给文本渲染引擎处理。[Flutter TextDirection](https://api.flutter.dev/flutter/dart-ui/TextDirection.html)

实际扫描当前 `quran.json` 与 `vocab.json`，两者的 Arabic Presentation Forms-A/B 字符数均为 0。
不过外部旧式文本可能包含这些字符，因此 `QuranText.normalize` 现在先按 Unicode 官方兼容分解
将表现形式还原为逻辑字符，例如 `ﷲ`（U+FDF2）→ `الله`、lam-alef 连字→对应字母。
再执行原有去音标和字母变体归一化；不把正常输入正向转换为表现形式。

映射来自 Unicode 15.0.0，覆盖 731 个有标准分解的表现形式码点；无标准分解的装饰符不猜测展开。
依据：[Unicode normalization](https://www.unicode.org/reports/tr15/)、
[Arabic blocks](https://unicode.org/versions/Unicode17.0.0/core-spec/chapter-9/)。

## 复现与实际检查

以下命令均从仓库根目录执行。环境沿用已有 `tools/quran_offline/.venv122`，没有更换模型。

```bash
# 本轮实际通过：静态检查、142 项单元/页面测试
flutter analyze --no-pub
flutter test --reporter expanded

# 主机推理服务：只监听 localhost；模型与音频不上传
tools/quran_offline/.venv122/bin/python tools/quran_offline/host_ort_server.py --port 18765

# 另一个终端运行：任一录音 F1/P/R < 0.9 即失败
QURAN_ORT_URL=http://127.0.0.1:18765 QURAN_BENCH_OUT=/tmp/quran-offline-final.json flutter test tool/offline_benchmark_test.dart --reporter expanded

# 旧流式诊断，可用 QURAN_BENCH_ADVANCE=false 关闭推进做消融
QURAN_ORT_URL=http://127.0.0.1:18765 QURAN_BENCH_CASE=36:1-5 QURAN_BENCH_OUT=/tmp/quran-stream.json flutter test tool/stream_benchmark_test.dart

# 字形映射漂移检查（Python 3.12 内置 Unicode 15.0.0）
python3.12 tool/generate_arabic_forms.py --check

# 本轮已成功构建、安装；自动进入默认离线校核
flutter build apk --debug --target-platform android-arm64 --dart-define=quran_auto_corpus=true
adb install -r --no-streaming build/app/outputs/flutter-apk/app-debug.apk
```

已验证裁窗边界、自然停顿/增益等价、最长窗口与覆盖、全静音不推理、重叠去重且保留真实重复、
半词修订、固定参考、严格 WER 和表现形式归一化。

Android：APK 已安装，内置一次性样本仍 5/5，三段离线语料真实推理 3/3 达标。
首次 UI 自动验收遇到设备息屏，系统拒绝 ADB `KEYCODE_WAKEUP`（缺少 INJECT_EVENTS）。用户点亮设备后，
页面路径完成前两段（0.958/0.977），随后无界面联调入口完整验证三段，输出 `OFFLINE_COMPLETE passed=3 total=3`。
该入口直接调用与页面相同的 OfflineTranscriber，不依赖渲染帧；开启方法如下，本轮已实际构建和运行：

```bash
flutter build apk --debug --target-platform android-arm64 --dart-define=quran_headless_corpus=true
adb install -r --no-streaming build/app/outputs/flutter-apk/app-debug.apk
adb shell am force-stop com.llvision.quran_offline_demo
adb shell am start -n com.llvision.quran_offline_demo/.MainActivity
```

普通构建不带联调开关。后续已完成 iPhone 17 Pro 真机离线验证，三段指标与 Android 完全一致，见 [iOS 验收报告](offline-ios-20260920.md)。真人麦克风、本轮 CI 未运行。

## 后续范围

若下一步要求“严格逐字准确率也 ≥90%”，需分别解决可解释的书写体映射与剩余声学错误，
保留 raw ASR 与规范化经文两个独立输出。若要求实时任意位置定位，则需继续跨窗口位置跟踪、
歧义重定位和保留测试集；本轮离线校核不替代这些工作。
