# iOS 平台说明

iOS 与 Android 共用同一套 Dart 算法层，平台差异只在「调 ONNX Runtime 推理」这一层：
`ios/Runner/QuranOrtBridge.{h,m}` + `ios/Runner/AppDelegate.swift`
（通道 `quran_offline/ort`，方法名与参数和 Android 侧一致）。

## 1. 原生桥

| 项 | 实现 |
|----|------|
| 实例 | `+ sharedInstance`（`dispatch_once` 单例） |
| 串行 | `@synchronized(self)` |
| 方法 | `loadModel(withAssetKey:)` / `run(withSamples:count:)` / `dispose` |
| 模型缓存 | `NSCachesDirectory` 下的 `fastconformer_full_mixed_ort122.onnx` |
| 线程数 | `intraOpNumThreads = cores > 2 ? cores / 2 : 2` |
| 输出 | `logprobs`（`FlutterStandardTypedData` float32）/ `timeSteps` / `vocabSize` |
| 通道方法 | `loadModel` / `run` / `dispose`，另有 iOS 专有的 `acceptanceLog`（见 §5） |

## 2. 必须的两项配置

- **`Info.plist` 声明 `NSMicrophoneUsageDescription`**：否则 iOS 访问麦克风会直接终止进程。
  Android 侧无此要求，容易漏。
- **部署目标 iOS 15.5**：`onnxruntime-objc` 1.22.0 只要求 15.1，
  取 15.5 是因为广播功能的 `google_mlkit_translation` 0.14.0 原生 podspec 声明
  `platform :ios, '15.5'`。`Podfile` 的 `platform` 与 Xcode 的
  `IPHONEOS_DEPLOYMENT_TARGET`（3 处）需保持一致。

`onnxruntime-objc` 显式锁定 `1.22.0`，与 Android AAR 对齐：
两端数值差异会翻转 CTC 跨度判定（见 [README 已知限制](../README.md#已知限制)）。

## 3. 依赖与构建

```bash
export PATH="/usr/local/bin:$PATH" LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
cd ios && pod install
# Installing MLKitTranslate (8.0.0) … Installing onnxruntime-objc (1.22.0)
```

实测 **`onnxruntime-objc 1.22.0` 与 `MLKitTranslate 8.0.0` / `MLKitCommon 14.0.0` 可以共存**
（这是原生依赖链上最需要确认的一点）。

常用命令：

```bash
cd ios && pod install                          # 首次或 Podfile 变更后
flutter run -d <模拟器 UDID>                    # 模拟器（麦克风用宿主 Mac 的麦克风）
flutter run                                     # 真机（需 Xcode 签名配置）
flutter build ios --debug --no-codesign         # 只验证设备（arm64）切片能编译链接
```

两点注意：

1. **iOS 模拟器不能跑广播功能**。ML Kit 的传递依赖（GoogleMLKit、MLKitTranslate、
   MLImage、MLKitVision、MLKitCommon）声明不支持 arm64 模拟器架构，构建时会明确警告
   「do not support arm64 architecture」。**iOS 侧只能真机验证广播链路**；
   模拟器仍可跑旧 Demo 的离线路径。

   > 影响不止运行时：模拟器构建只能退化成 **x86_64 切片**（Apple Silicon 上的模拟器
   > 实际是 arm64，跑不了），在 Apple Silicon 机器上并不可靠。
   > 因此 **CI 验证 iOS 链接链路时构建的是设备切片**
   > （`flutter build ios --debug --no-codesign`，产物为 arm64），
   > 不构建模拟器版本。日常本地调试模拟器仍可用，但别把它当作广播功能的验证手段。
2. **CocoaPods 需要 UTF-8 终端环境**，否则会抛
   `Unicode Normalization not appropriate for ASCII-8BIT`（用 `LANG=en_US.UTF-8` 解决）。

## 4. 真机运行

```bash
# 查看设备
xcrun devicectl list devices

# 签名安装并启动（普通版本）
flutter build ios --release
xcrun devicectl device install app --device <UDID> build/ios/Release-iphoneos/Runner.app
xcrun devicectl device process launch --device <UDID> --terminate-existing \
  com.llvision.quranOfflineDemo
```

首次安装需要在设备上信任开发者证书；描述文件过期后需重新签名安装。

## 5. 无头验收入口与日志转发

**问题**：release 构建下 Dart `debugPrint` 在 `devicectl --console` 中不可见（原生 `NSLog` 可见），
而离线验收需要拿到逐条指标。

**处理**：仅在 `--dart-define=quran_headless_corpus=true` **且平台为 iOS** 时，
把验收日志经 MethodChannel `acceptanceLog` 转发为原生 `NSLog`。
该改动位于 `quran_offline_demo_page.dart` 的日志函数与
`AppDelegate.swift` 的通道注册里，**不改变转录算法或评分**，普通构建不会发送这些日志。

```bash
flutter build ios --release --dart-define=quran_headless_corpus=true
xcrun devicectl device install app --device <UDID> build/ios/Release-iphoneos/Runner.app
xcrun devicectl device process launch --device <UDID> --terminate-existing --console \
  com.llvision.quranOfflineDemo
```

需保持设备解锁、应用前台；采集到 `OFFLINE_COMPLETE passed=N total=M` 后再结束。
完整流程与已复现指标见 [离线语料准确度 §4.2](offline-accuracy.md#42-真机无头验收入口)。

## 6. 当前覆盖范围

| 能力 | 状态 |
|------|------|
| 设备切片编译链接（ObjC 桥 + ORT XCFramework + Pods + ML Kit） | 已通过，CI 覆盖（`--debug --no-codesign`，产物 arm64） |
| 真机签名安装与启动 | 已通过 |
| 真机内置样本自测 | 5/5 |
| 真机三段离线语料 | 3/3，指标与 Android 完全一致（差值 0） |
| **真机广播链路（麦克风实采 → 断句 → 匹配 → 翻译）** | **未通过**：已开始验证，进入广播页触发语言包下载时闪退，根因已修（`62815c7`）；完整链路见 [真机验收记录](device-verification.md) |
| 模拟器麦克风授权 | 不可用（`simctl privacy grant microphone` 无效） |
| 原文覆盖（`reference_text.dart` 的设备文件路径） | 只接了 Android 私有目录，iOS 固定使用内置资产 |

> **真机第一次跑广播链路暴露的缺陷（已修）**：进入广播页触发语言包下载时闪退。
> 根因是**下载过程中切换目标语言**，原生 `OnDeviceTranslatorModelManager` 被中途释放，
> 退出时抛 `PlatformException(cancelled, Model manager deallocated during download)`；
> 而这条路径上无人处理它——引擎层只把「返回 false」当失败、页面层只
> `catch TranslationException`，异常直接冒泡到 Dart VM。
> 修复（`62815c7`）：① 引擎层把 `PlatformException` 转成分类 `TranslationException`，
> 与「语言包缺失」走同一条可重试路径；② 页面层补通用兜底，准备失败只能是可恢复状态；
> ③ `ModelManager` 改为长生命周期字段。**Android 侧行为不变。**

## 7. 首次编译曾经暴露的问题（避免重复踩）

这套桥第一次被 Xcode 编译时暴露出 4 个隐藏缺陷，均已在代码里修掉，记录如下：

| 问题 | 报错 | 处理 |
|------|------|------|
| `QuranOrtBridge.m` 未登记进 Xcode 工程（只存在于磁盘） | `Undefined symbol: _OBJC_CLASS_$_QuranOrtBridge` | 用 CocoaPods 自带的 `xcodeproj` 库把文件加入 Runner target 的 Compile Sources（**新增原生文件后务必确认它在 Sources 阶段里**） |
| ObjC 的 `NSError**` 方法在 Swift 中被导入为 `throws` | `Extra argument 'error' in call` | 改为 `try bridge.loadModel(withAssetKey:)` / `try bridge.run(withSamples:count:)` |
| `NSUInteger` 在 Swift 中为 `UInt` | `Cannot convert value of type 'Int' to expected argument type 'UInt'` | 采样点数改为 `UInt(...)` |
| ORT ObjC 1.22 的 API 名与桥里的假设不一致 | `No visible @interface ... 'runWithInputs:outputNames:error:'` / `'shapeWithError:'` | `run` 补 `runOptions:nil`；形状改经 `tensorTypeAndShapeInfoWithError:` 读取 |

模拟器报 `Unable to boot device because it cannot be located on disk`，
说明 CoreSimulator 的 `Devices` 目录缺失，用 `xcrun simctl create <名字> <机型> <运行时>` 新建一个即可。
