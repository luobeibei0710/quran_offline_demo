# iOS 支持说明

iOS 与 Android 共用同一套 Dart 算法层，平台差异只在「调 ONNX Runtime 推理」这一层：
`ios/Runner/QuranOrtBridge.{h,m}` + `ios/Runner/AppDelegate.swift`（通道 `quran_offline/ort`，
方法名与参数和 Android 侧完全一致）。

**当前状态：模拟器与 iPhone 17 Pro 真机均已跑通模型推理；真机现有三段离线语料全部通过。**

2026-09-20 iPhone 17 Pro / iOS 26.6：内置样本 5/5；三段离线语料 F1/P/R 分别为 0.958333、0.976744、0.967213，严格 WER、词数与分段数也与 Android 相同。详见[真机验收报告](offline-ios-20260920.md)。

## 首次真正编译时修掉的问题

这套桥此前从未被 Xcode 编译过，首次编译暴露出 4 个隐藏缺陷，均已在代码里修掉：

| 问题 | 报错 | 处理 |
|------|------|------|
| `QuranOrtBridge.m` 未登记进 Xcode 工程（只存在于磁盘） | `Undefined symbol: _OBJC_CLASS_$_QuranOrtBridge` | 用 CocoaPods 自带的 `xcodeproj` 库把文件加入 Runner target 的 Compile Sources（**新增原生文件后务必确认在 Sources 阶段里**） |
| ObjC 的 `NSError**` 方法在 Swift 中被导入为 `throws` | `Extra argument 'error' in call` | 改为 `try bridge.loadModel(withAssetKey:)` / `try bridge.run(withSamples:count:)` |
| `NSUInteger` 在 Swift 中为 `UInt` | `Cannot convert value of type 'Int' to expected argument type 'UInt'` | 采样点数改为 `UInt(...)` |
| ORT ObjC 1.22 的 API 名与桥里的假设不一致 | `No visible @interface ... 'runWithInputs:outputNames:error:'` / `'shapeWithError:'` | `run` 补 `runOptions:nil`；形状改经 `tensorTypeAndShapeInfoWithError:` 读取 |

## 必须的两项配置

- **`Info.plist` 声明 `NSMicrophoneUsageDescription`**：否则 iOS 访问麦克风会直接终止进程
  （Android 无此要求，容易漏）。
- **部署目标 iOS 15.5**：`onnxruntime-objc` 1.22.0 只要求 15.1，取 15.5 是因为广播功能的
  `google_mlkit_translation` 0.14.0 原生 podspec 声明 `platform :ios, '15.5'`。Podfile 的
  `platform` 与 Xcode 的 `IPHONEOS_DEPLOYMENT_TARGET`（3 处）已同步；`onnxruntime-objc`
  显式锁 `1.22.0`，与 Android AAR 对齐（设备端数值差异会翻转 CTC 跨度判定，见 `README`
  的「已知限制」）。

## 新增依赖（广播功能）

```bash
export PATH="/usr/local/bin:$PATH" LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
cd ios && pod install
# Installing MLKitTranslate (8.0.0) … Installing onnxruntime-objc (1.22.0)
# Pod installation complete! 7 dependencies from the Podfile and 21 total pods installed.
```

实测 **`onnxruntime-objc 1.22.0` 与 `MLKitTranslate 8.0.0` / `MLKitCommon 14.0.0` 可以共存**，
`flutter build ios --debug --no-codesign` 通过（Xcode build 49.7 s）。

两点必须知道：

1. **iOS 模拟器不能跑广播功能**。ML Kit 的传递依赖（GoogleMLKit、MLKitTranslate、MLImage、
   MLKitVision、MLKitCommon）声明不支持 arm64 模拟器架构，构建时会明确警告
   「do not support arm64 architecture」。iOS 侧只能真机验证。
2. CocoaPods 需要 UTF-8 终端；否则会抛
   `Unicode Normalization not appropriate for ASCII-8BIT`（用 `LANG=en_US.UTF-8` 解决）。

## 常用命令

```bash
cd ios && pod install                          # 首次或 Podfile 变更后
flutter run -d <模拟器 UDID>                    # 模拟器（麦克风用宿主 Mac 的麦克风）
flutter run                                     # 真机（需 Xcode 签名配置）
flutter build ios --debug --no-codesign         # 只验证设备（arm64）切片能编译链接
```

> 模拟器报 `Unable to boot device because it cannot be located on disk`，说明 CoreSimulator 的
> `Devices` 目录缺失，用 `xcrun simctl create <名字> <机型> <运行时>` 新建一个即可。

## 未覆盖

- 物理 iPhone：签名安装、内置模型推理和三段离线语料已通过；麦克风实采、实时跟踪、系统性性能测试仍未覆盖；
- iOS 侧取不到模拟器麦克风授权（`simctl privacy grant microphone` 无效），因此
  「麦克风采集 → 流式识别 → 比对页」这条链路只在 Android 真机上验证过；
- 原文覆盖（`reference_text.dart` 的 `adb push` 路径）只接了 Android 私有目录，iOS 固定使用内置资产。
