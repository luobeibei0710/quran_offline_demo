# 古兰经广播离线识别

Flutter 应用与可复用的 `quran_broadcast_sdk` 插件。应用通过麦克风采集诵读，在设备上运行 ONNX 识别、匹配经文，并显示带来源标记的译文与本地历史记录。Android 和 iOS 共用 Dart 算法层。

## SDK 集成

SDK 位于 [`packages/quran_broadcast_sdk/`](packages/quran_broadcast_sdk/)，可作为 Flutter `path` 依赖使用。插件包含平台推理桥、词表、经文及译本；宿主应用需自行提供兼容的 ONNX 模型，并配置麦克风权限。完整接入步骤和示例见 [SDK README](packages/quran_broadcast_sdk/README.md)。

- Android：`minSdk 26`，插件需要 Android SDK Platform 36。
- iOS：部署目标 15.5，并在 `Info.plist` 中声明 `NSMicrophoneUsageDescription`。
- 模型权重、录音、数据库和本地验收材料不纳入公开仓库。

在仓库根目录进行源码检查：

```bash
flutter pub get
flutter analyze
flutter test
```

## 数据与许可

包内经文采用 [Tanzil 原文](https://tanzil.net/docs/Text_License)，译本来自 [QuranEnc](https://quranenc.com/en/home/api)。使用时须遵守原文及译本的署名、版本和内容完整性要求；相应来源与许可信息随 SDK 资源提供。代码许可见 [LICENSE](LICENSE)。

本仓库只公开集成所需的源码、运行数据和 README。开发记录、AI 交接、验收证据及原始设备日志保留在本地。
