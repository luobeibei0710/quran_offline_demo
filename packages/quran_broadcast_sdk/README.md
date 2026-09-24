# Quran Broadcast SDK（Flutter）

本地麦克风收音、ONNX 离线转写、全经匹配、带来源标记的译文和 SQLite 历史记录，封装为 Android/iOS Flutter 插件。Dart 算法与全经语料、词表、62 种语言译本随包提供；**124.6 MB 的 ORT 1.22 兼容模型由宿主应用提供**。旧 Demo 的语料校核页面与测试音频不属于 SDK。

## 集成

当前以本地 path 包交付。消费工程在 `pubspec.yaml` 增加：

```yaml
dependencies:
  flutter:
    sdk: flutter
  quran_broadcast_sdk:
    path: ../quran_offline_demo/packages/quran_broadcast_sdk

flutter:
  assets:
    - assets/models/fastconformer_full_mixed_ort122.onnx
```

上面的路径假设消费工程与本仓库是同级目录，请按实际目录调整。模型需从 Tilawa v0.2.0 原版转换为 ORT 1.22 兼容版；本仓库已有下载与转换命令：

```bash
cd ../quran_offline_demo
bash tools/quran_offline/download_assets.sh
tools/quran_offline/.venv/bin/python tools/quran_offline/convert_for_ort122.py
shasum -a 256 assets/quran_offline/fastconformer_full_mixed_ort122.onnx
```

仓库当前验证过的兼容模型 SHA-256 为 `2d35a41040d4132f7d2c43fb457d539ac65a058d00fd7114ed317927212d716c`。将生成的文件复制到消费工程的 `assets/models/`，并核对哈希；**不要使用未经转换的 `fastconformer_full_mixed.onnx`**。模型和内置语料测试音频不在 Git 中。
若宿主忘记声明模型 asset，`initialize` 会先抛 `MissingModelAssetException`，不会打开数据库或原生推理资源。

Android 宿主需 `minSdk >= 26`、JDK 17，并安装 Android SDK Platform 36（插件 `compileSdk 36`）。插件声明 `RECORD_AUDIO` 并自动注册 `quran_offline/ort` 与 `quran_offline/screen` 通道，宿主无需添加 `MainActivity` 通道代码或 ONNX AAR。iOS 宿主需部署目标 **15.5**，在 `Info.plist` 添加 `NSMicrophoneUsageDescription`。SDK 使用 `record` 插件请求权限，无需 `permission_handler` 编译宏。ORT 1.22.0 由插件 podspec 提供，宿主不应重复添加。配置可参考仓库演示应用的 `ios/Runner/Info.plist`；旧 Demo 自身仍使用 `permission_handler`。

```dart
import 'package:flutter/material.dart';
import 'package:quran_broadcast_sdk/quran_broadcast_sdk.dart';

class QuranPage extends StatefulWidget {
  const QuranPage({super.key});

  @override
  State<QuranPage> createState() => _QuranPageState();
}

class _QuranPageState extends State<QuranPage> {
  QuranBroadcastSdk? sdk;
  Object? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final ready = await QuranBroadcastSdk.initialize(
        modelAssetKey: 'assets/models/fastconformer_full_mixed_ort122.onnx',
      );
      if (!mounted) {
        await ready.dispose();
        return;
      }
      setState(() => sdk = ready);
    } catch (e) {
      if (mounted) setState(() => error = e);
    }
  }

  @override
  void dispose() {
    sdk?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => switch ((sdk, error)) {
    (final ready?, _) => ready.homePage(),
    (_, final failure?) => Center(child: Text('SDK 初始化失败：$failure')),
    _ => const Center(child: CircularProgressIndicator()),
  };
}
```

宿主也可使用 `sdk.session`（`ChangeNotifier`）绘制自己的界面，读取 `status`、`draftText`、`preview`、`recentRecords` 与 `statusMessage`；通过 `sdk.start()` / `sdk.stop()` 控制麦克风，通过 `sdk.records()` 分页读取历史。切换语言调用 `sdk.setTargetLanguage(...)`，识别中会返回 `false`。机器翻译语言包只在宿主显式调用 `sdk.prepareTranslation(allowDownload: true)` 时允许下载；匹配经文优先使用包内权威译本，未匹配内容仅能标为机器翻译来源。

## 生命周期与数据

- SDK 在同一 Dart 运行环境内只允许一个活动实例；重复或并发调用 `initialize()` 会抛出 `StateError`。页面销毁时调用 `dispose()`，完成后才可再次初始化。`stop()` 会冲刷最后一句。成功开麦期间 SDK 会保持屏幕点亮，停止或释放后恢复系统设置。多个 FlutterEngine 应由宿主协调为单个活动识别会话。
- 记录保存在应用私有目录的 `broadcast_quran.db`；迁移保留原数据库名与表结构，不会自动上传。
- `quran_dump_pcm` 与 `quran_latency_trace` 是编译期开关，仅用于受控诊断。PCM 转储默认关闭，可能包含原始麦克风内容。
- 包内全经与 62 译本约 134 MB，Flutter 会把声明的包资产打入应用；模型约 125 MB，体积预算需由宿主承担。
- 模型缓存每次初始化会校验打包模型与缓存文件摘要，热启动仍需读取约两份模型数据；启动耗时需在目标设备上测量。
- 使用经文和译文时须展示原始来源及译本署名，许可正文见包内 `assets/broadcast_quran/full/NOTICE.txt` 与 `assets/broadcast_quran/full/translations/index.json`（仓库位置为 `packages/quran_broadcast_sdk/assets/...`）。不得把机器译文显示为人工校订译本。

## 验证

在仓库根目录运行 `flutter pub get`、`flutter analyze`、`flutter test`。消费工程另行运行 `flutter build apk --debug` 与 `flutter build ios --debug --no-codesign`，再分别在 Android/iOS 真机验证授权、模型首次加载、开麦、停止后末句落库、重启历史与译本署名。模拟器或单测不能代替真机音频链路验收。

2026-09-24 本地验证：仓库全量 231 项 Flutter 测试通过；独立临时消费工程仅通过 path 依赖和上述模型资产接入，`flutter analyze`、Android arm64 debug APK、iOS `--no-codesign` 构建通过。APK 合并 Manifest 含 `RECORD_AUDIO`，SDK 词表、全经 manifest 和宿主模型均已打包。独立消费 App 已在 Android 真机安装并进入广播首页，日志确认 ONNX 模型加载成功；此次没有执行开麦、实际音频推理、历史恢复及 iOS 真机验收。
