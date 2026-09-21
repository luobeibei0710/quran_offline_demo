# iOS 真机离线验收报告（2026-09-20）

## 当前结论

真机离线验收通过。iPhone 17 Pro 上内置样本命中 **5/5**，三段连续离线语料 **3/3** 通过；F1、Precision、Recall、严格 WER、参考/识别词数及分段数与 Android 基准全部相同。当前结论限于这三段现有离线语料，不代表任意诵读、麦克风输入或全经泛化。

证据：[机器可读指标](offline-ios-20260920.json)、[完整设备控制台日志](offline-ios-20260920-console.txt)。17:47:17.568 收到 `OFFLINE_COMPLETE passed=3 total=3`，随后主动结束采集（日志末尾 signal 2）；完成前未出现 `OFFLINE_FAILED` 或进程崩溃。

## 已实际完成

- 设备：iPhone 17 Pro（iPhone18,1），iOS 26.6；有线连接，`pairingState: paired`、`developerModeStatus: enabled`、`ddiServicesAvailable: true`。
- Xcode 26.6；执行 `xcrun devicectl manage pair --device C224425C-AB0E-5F20-A5EC-72ED329B5A4A --timeout 30` 成功。
- 执行 `flutter build ios --debug --no-codesign --dart-define=quran_headless_corpus=true` 成功，Xcode 构建耗时 84.7 秒，产物 `build/ios/iphoneos/Runner.app`。日志：`/tmp/quran-ios-build-20260920.log`。
- 已核对新包 `Frameworks/App.framework/flutter_assets` 中的模型、manifest 与全部三段 WAV，逐个 SHA-256 与工作区源资产相同。
- 两端原生桥均使用 ONNX Runtime 1.22.0；当前模型输入 float32 `[1,N]` 和 int64 `[1]`，输出 `log_probs`，共用同一 Dart 转录和评分逻辑。

| 打包资产 | SHA-256 |
|---|---|
| fastconformer_full_mixed_ort122.onnx | `2d35a41040d4132f7d2c43fb457d539ac65a058d00fd7114ed317927212d716c` |
| corpus/manifest.json | `43b8521fd898a587c2b9c6d37d7e02fde0465fd1d8b94760153e7650a2ac8cd3` |
| corpus_036_001_005.wav | `1ab6c5047f1e7fb45e4efa095df951121c09df1038d92414404e0cd2022b5edb` |
| corpus_055_001_013.wav | `5e3c52978aceac0bc3765c1f61f4fab1a289257ecd724be2468510ee10fe1ec1` |
| corpus_067_001_011.wav | `6c1ee70f1b380b99e985613c8b48202d718693384c83cb30454a40a999a23a15` |

## 已解决的签名与采集问题

首次检查没有有效签名身份，Xcode 账号无法获取团队。用户准备证书后，钥匙串已出现有效 Apple Development 身份，无需重复导入 P12。带签名 debug 构建成功（39.7 秒），安装及 `codesign --verify --deep --strict` 均通过。日志：`/tmp/quran-ios-signing-20260920.log`。

`flutter run` 卡在 Xcode 调试器附加，因此改用 release + devicectl 控制台。首次 release 构建提示默认产物路径不存在，实际完整签名产物在 `build/ios/Release-iphoneos/Runner.app`，校验后安装成功。最终验收构建耗时 31.1 秒，Flutter 默认产物路径也已恢复。构建日志：`/tmp/quran-ios-release-build-20260920.log`。

首次启动被设备安全策略拒绝；用户在手机上信任开发者后已正常启动。已核实描述文件包含当前 iPhone、应用标识及签名证书匹配，描述文件有效至 2026-09-27 09:31:35 UTC，过期后需重新签名安装。

release 下 Dart `debugPrint` 在本机 `devicectl --console` 中不可见，原生 `NSLog` 可见。因此仅在 `quran_headless_corpus=true` 且 iOS 时，通过 MethodChannel `acceptanceLog` 转发测试日志。改动位于 `quran_offline_demo_page.dart::_log` 与 `AppDelegate.swift::registerQuranOrtChannel`，未改变转录算法或评分。`flutter analyze --no-pub` 无问题；新构建及真机完整执行验证了日志通道。普通构建不会发送这些验收日志。

## 实测指标

本次设备解锁、应用前台执行。Android 为 debug，iOS 为 release；比较识别指标，不将耗时作为跨平台性能门槛。下表三项容错指标在每条语料中数值相同，且两端差值均为 0。

| 语料 | Android / iOS F1、Precision、Recall | Android / iOS 严格 WER | 参考/识别词数 | 分段 | iOS 耗时 |
|---|---:|---:|---:|---:|---:|
| 036:1–5 | 0.958333 | 0.166667 | 12/12 | 5 | 0.568 s |
| 055:1–13 | 0.976744 | 0.139535 | 43/43 | 13 | 1.740 s |
| 067:1–11 | 0.967213 | 0.163934 | 122/122 | 16 | 3.268 s |

三项容错指标均超过 0.95，高于自动门槛 0.9。严格 WER 仍为约 14%–17%，不能宣称严格逐词准确率达到 95%。原生会话加载 242 ms，经文库与模型合计 359 ms，均为单次观测，非性能基准。

两端模型缓存均按固定文件名复用。本次从 iPhone 应用沙盒导出实际缓存模型，SHA-256 与上表一致，排除了陈旧模型影响。代码工作区仍有未提交改动，基线 commit 与本次源码指纹已记录到 JSON；Android 历史 JSON 未记录源码指纹，因此仅确认本轮指标和资产一致，不声称二进制或源码快照完全相同。

## 复现

以下命令本次均实际执行成功，设备标识需按实际连接调整：

```bash
flutter build ios --release --dart-define=quran_headless_corpus=true
xcrun devicectl device install app --device C224425C-AB0E-5F20-A5EC-72ED329B5A4A build/ios/Release-iphoneos/Runner.app
xcrun devicectl device process launch --device C224425C-AB0E-5F20-A5EC-72ED329B5A4A --terminate-existing --console com.llvision.quranOfflineDemo
```

需保持手机解锁、应用前台，采集到 COMPLETE 后再结束。验收结束后已执行 `flutter build ios --release`（不带测试开关），重新安装并于 17:50:40 成功启动普通版本。麦克风实采、实时定位、长时间稳定性和未见过的诵读者仍未在本轮验证。

相关资料：[Android 原始指标](offline-android-20260920.json)、[算法改进报告](offline-accuracy-20260920.md)、[iOS 支持说明](ios.md)。
