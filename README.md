# 古兰经离线识别 Demo

[![CI](https://github.com/luobeibei0710/quran_offline_demo/actions/workflows/ci.yml/badge.svg)](https://github.com/luobeibei0710/quran_offline_demo/actions/workflows/ci.yml)

端侧**全离线**的古兰经诵读识别验证工程：麦克风采集 → ONNX 声学模型推理 → CTC 解码 → 经文约束匹配 → 界面展示。

验证通过后再移植回主工程（courier-mobile）。

## 技术方案（路线 B）

```
麦克风 16 kHz PCM16 → float32
   ↓
ONNX Runtime（原生：Android AAR / iOS onnxruntime-objc）—— 只做张量翻译
   ↓  log_probs [1, T, 1025]
纯 Dart 算法层（Android / iOS 共用）
   ├─ 贪心 CTC 解码（TextCtcDecoder）
   ├─ 文本召回（首词倒排 + 编辑相似度）
   └─ CTC 约束精排（前向后向对数似然）→ surah:ayah
   ↓
本地经文库取标准经文 → 界面展示
```

设计要点：**算法层用纯 Dart 实现，两端共享**；平台差异只存在于「调 ORT 推理」这一层，因此不引入两套业务逻辑。

## 模型与数据

来源 [yazinsai/tilawa](https://github.com/yazinsai/tilawa) v0.2.0（SDK MIT；模型 CC-BY-4.0，基座 `nvidia/stt_ar_fastconformer_hybrid_large_pcd_v1.0`）。

| 文件 | 体积 | 说明 |
|------|------|------|
| `fastconformer_full_mixed.onnx` | 88 MB | FastConformer，int4 MatMul + int8 Conv 混合量化 |
| `quran_ctc_tokens.json` | 12 MB | span 表，键 `surah:ayahStart:ayahEnd`，值为该跨度 token 序列 |
| `quran.json` | 3 MB | 6236 节经文（`text_uthmani` 带音标 / `text_clean` 归一化） |
| `vocab.json` | 21 KB | 1025 个 token，最大 id 为 blank |

模型资产体积较大，未纳入版本库，执行下载脚本获取：

```bash
bash tools/quran_offline/download_assets.sh   # 含 sha256 校验
```

## 运行

```bash
flutter pub get
flutter run                   # 需要真机（麦克风）
```

使用步骤：点击「加载模型」（首次会复制 88 MB 模型到应用私有目录）→「开始识别」→ 诵读 → 界面实时显示章节、标准经文、识别原文、候选与置信度。

## 测试与 CI

```bash
flutter analyze   # 静态分析
flutter test      # 45 个用例
```

测试**不依赖** `assets/quran_offline/` 下的真实资产：用例通过 `FakeAssetBundle` 注入最小化的
内存资产、通过 `ScriptedOrtRunner` 注入合成声学证据，覆盖归一化、贪心 CTC 解码、
CTC 前向后向精排、资产解析与「解码 → 召回 → 精排」全链路，因此 clone 后无需下载
99 MB 模型即可跑通（真机麦克风与模型推理仍需 `flutter run` 验证）。

CI 定义见 `.github/workflows/ci.yml`，两个 Job：

| Job | 内容 |
|-----|------|
| 静态分析 + 单元测试 | `flutter analyze` → `flutter test --coverage`，上传 `lcov.info` |
| 构建 Android APK | 缓存/下载模型资产 → `flutter build apk --debug`，上传 APK 产物 |

## 已完成验证（Python 基准）

| 项 | 结果 |
|----|------|
| 模型可用性 | 6.03 s 音频（1:1）→ 解码 `بسم الله الرحمن الرحيم`，完全正确 |
| 推理耗时 | 0.116 s（Mac CPU，6 s 音频） |
| 召回 + 精排 | 冠军 1:1，acoustic=0.074，与次优差距 1.18（区分度极大） |

复现脚本：`tools/quran_offline/poc_transcribe.py`（单次推理 + 贪心解码）、`poc_match.py`（召回 + CTC 精排）。
首次使用需自建 venv：`python3.12 -m venv tools/quran_offline/.venv && tools/quran_offline/.venv/bin/pip install onnxruntime numpy`。

> 注意：Python 侧需 ORT ≥ 1.30 才能加载含 `ConvInteger` 的模型；ORT 1.19 会报 `NOT_IMPLEMENTED`。

## 目录结构

```
lib/
├── main.dart
└── quran_offline/
    ├── quran_text.dart              阿拉伯语归一化与相似度
    ├── ctc_decoder.dart             贪心 CTC 解码
    ├── ctc_scorer.dart              前向后向对数似然 + 稳定前缀
    ├── quran_assets.dart            经文库 / 词表 / span 表加载
    ├── quran_matcher.dart           召回 + 精排 + 置信度
    ├── ort_runner.dart              推理桥接口（平台通道）
    ├── quran_recognizer.dart        一次性识别 + 流式会话
    └── quran_offline_demo_page.dart Demo 界面
android/app/src/main/java/.../QuranOrtBridge.java   ONNX Runtime 桥
android/app/src/main/kotlin/.../MainActivity.kt     通道注册
ios/Runner/QuranOrtBridge.{h,m}                     ONNX Runtime 桥
ios/Runner/AppDelegate.swift                        通道注册
test/                                               单元测试与页面冒烟测试
test/support/quran_test_fixtures.dart               内存资产包与脚本化推理桥
tools/quran_offline/                                资产下载与 Python 验证脚本
.github/workflows/ci.yml                            静态分析 + 测试 + APK 构建
```

## 已知限制

- **模型体积**：APK 因 88 MB 模型显著增大（当前构建约 +90 MB）。
- **算子支持**：Android 侧使用 `onnxruntime-android:1.22.0`，需实机确认其支持模型的 `ConvInteger` 算子（Mac 上 ORT 1.30 已验证支持）。
- **首次加载**：模型复制到私有目录约需数秒；后续启动复用缓存。
- **流式为工程化简版**：滑窗重复识别 + 稳定锁定；尚未移植 Tilawa `tracker.ts` 的词级对齐与推进策略。
- **iOS**：桥与 Podfile 已就绪（`pod 'onnxruntime-objc'`），尚未在 Xcode 侧构建验证。
