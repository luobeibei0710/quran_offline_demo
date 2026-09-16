/// 测试夹具：内存资产包、脚本化推理桥与合成声学证据。
///
/// 单元测试不依赖 `assets/quran_offline/` 下的真实资产（约 99 MB，需执行
/// `tools/quran_offline/download_assets.sh` 获取），而是用一组最小化的、
/// 结构完全一致的假数据驱动「解码 → 召回 → CTC 精排」全链路。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:quran_offline_demo/quran_offline/ctc_scorer.dart';
import 'package:quran_offline_demo/quran_offline/ort_runner.dart';
import 'package:quran_offline_demo/quran_offline/quran_assets.dart';

/// 内存资产包：直接以字符串形式提供资产内容。
///
/// 继承 [CachingAssetBundle] 以获得 `loadString`/`loadStructuredData` 的默认实现，
/// 只需覆写 [load]。
class FakeAssetBundle extends CachingAssetBundle {
  /// 构造内存资产包。
  ///
  /// @param files 资产键（如 `assets/quran_offline/vocab.json`）到文本内容的映射
  FakeAssetBundle(this.files);

  /// 资产键到文本内容的映射。
  final Map<String, String> files;

  /// 已加载次数统计（键为资产键），用于验证缓存行为。
  final Map<String, int> loadCounts = <String, int>{};

  @override
  Future<ByteData> load(String key) async {
    loadCounts[key] = (loadCounts[key] ?? 0) + 1;
    final content = files[key];
    if (content == null) {
      throw FlutterError('FakeAssetBundle 缺少资产：$key');
    }
    return ByteData.sublistView(Uint8List.fromList(utf8.encode(content)));
  }
}

/// 夹具使用的 token id 常量（与 [buildFixtureAssetFiles] 中的词表一致）。
class FixtureTokens {
  FixtureTokens._();

  /// 词 `بسم`（带词边界前缀）。
  static const int bism = 1;

  /// 词 `الله`。
  static const int allah = 2;

  /// 词 `الحمد`（带词边界前缀）。
  static const int alhamd = 3;

  /// blank token id（词表最大 id）。
  static const int blank = 5;

  /// 词表大小（含未使用的 0 号槽位）。
  static const int vocabSize = 6;
}

/// 构造夹具资产文件内容。
///
/// 结构、键名与真实资产完全一致，仅把 6236 节经文缩减为 2 节、
/// 把 span 表缩减为 3 条：
///
/// - `1:1` → `بسم الله`，token `[1, 2]`
/// - `1:2` → `الحمد لله`，token `[3]`
/// - `1:1:2`（1:1 与 1:2 连读）→ token `[1, 2, 3]`
///
/// @return 资产键到文本内容的映射
Map<String, String> buildFixtureAssetFiles() {
  final vocab = <String, String>{
    '0': '<unk>',
    '1': '\u2581بسم',
    '2': 'الله',
    '3': '\u2581الحمد',
    '4': 'لله',
    '5': '<blank>',
  };

  final verses = <Map<String, Object>>[
    {
      'surah': 1,
      'ayah': 1,
      'text_uthmani': 'بِسْمِ اللَّهِ',
      'text_clean': 'بسم الله',
      'surah_name': 'الفاتحة',
      'surah_name_en': 'Al-Fatihah',
    },
    {
      'surah': 1,
      'ayah': 2,
      'text_uthmani': 'الْحَمْدُ لِلَّهِ',
      'text_clean': 'الحمد لله',
      'surah_name': 'الفاتحة',
      'surah_name_en': 'Al-Fatihah',
    },
    {
      'surah': 2,
      'ayah': 1,
      'text_uthmani': 'الم',
      'text_clean': 'الم',
      'surah_name': 'البقرة',
      'surah_name_en': 'Al-Baqarah',
    },
  ];

  final spans = <String, List<int>>{
    '1:1:1': <int>[FixtureTokens.bism, FixtureTokens.allah],
    '1:1:2': <int>[FixtureTokens.bism, FixtureTokens.allah, FixtureTokens.alhamd],
    '1:2:2': <int>[FixtureTokens.alhamd],
  };

  return <String, String>{
    '${QuranAssets.assetDir}/vocab.json': jsonEncode(vocab),
    '${QuranAssets.assetDir}/quran.json': jsonEncode(verses),
    '${QuranAssets.assetDir}/quran_ctc_tokens.json': jsonEncode(spans),
  };
}

/// 加载夹具资产。
///
/// @param bundle 可传入自定义资产包以复用；为空时新建一个
/// @return 加载完成的 [QuranAssets]
Future<QuranAssets> loadFixtureAssets({FakeAssetBundle? bundle}) {
  return QuranAssets.load(bundle: bundle ?? FakeAssetBundle(buildFixtureAssetFiles()));
}

/// 脚本化推理桥：忽略输入音频，始终返回预置的声学证据。
///
/// 用于在不依赖 ONNX Runtime 的前提下驱动识别链路。
class ScriptedOrtRunner implements OrtRunner {
  /// 构造脚本化推理桥。
  ///
  /// @param evidence 每次推理返回的固定声学证据
  ScriptedOrtRunner(this.evidence);

  /// 固定返回的声学证据。
  final AcousticEvidence evidence;

  /// 已加载的模型路径（记录最后一次调用，便于断言）。
  String? loadedModelPath;

  /// 推理调用次数。
  int runCount = 0;

  /// 是否已释放。
  bool disposed = false;

  @override
  Future<void> loadModel(String modelPath) async {
    loadedModelPath = modelPath;
  }

  @override
  Future<AcousticEvidence> run(Float32List samples) async {
    runCount++;
    return evidence;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

/// 针对目标 token 序列合成「强对齐」的声学证据。
///
/// 生成的状态序列为 `blank, id0, blank, id1, …, blank`，因此帧数恰为
/// `2 * target.length + 1`（CTC 可行性下界），并让每帧在对应状态上取峰值
/// log 概率、其余位置取极低值。这样：
///
/// - 贪心 CTC 解码恰好还原 [target]；
/// - [CtcScorer.scoreSequence] 对 [target] 给出接近 0 的平均负对数似然，
///   对其他序列给出显著更大的分数。
///
/// @param target 目标 token 序列
/// @param peakLogProb 峰值帧的 log 概率
/// @param otherLogProb 其余 token 的 log 概率
/// @return 合成的声学证据
AcousticEvidence buildAlignedEvidence(
  List<int> target, {
  double peakLogProb = -0.01,
  double otherLogProb = -12.0,
}) {
  final states = <int>[];
  for (final id in target) {
    states
      ..add(FixtureTokens.blank)
      ..add(id);
  }
  states.add(FixtureTokens.blank);

  final timeSteps = states.length;
  final vocabSize = FixtureTokens.vocabSize;
  final logprobs = Float32List(timeSteps * vocabSize)..fillRange(0, timeSteps * vocabSize, otherLogProb);
  for (var t = 0; t < timeSteps; t++) {
    logprobs[t * vocabSize + states[t]] = peakLogProb;
  }

  return AcousticEvidence(
    logprobs: logprobs,
    timeSteps: timeSteps,
    vocabSize: vocabSize,
    blankId: FixtureTokens.blank,
  );
}

/// 生成「类语音」测试音频：20 ms 帧中每 5 帧取一帧高幅，其余为本底低幅。
///
/// 用于驱动 [QuranStreamingSession] 的能量 VAD：峰值（0.2）显著高于中位数
/// （0.001），满足「峰值 ≥ max(中位数 × 信噪比, 绝对下限)」判据；
/// 同时整块 RMS 高于静音阈值，不会误判为静音。
///
/// @param seconds 时长（秒）
/// @return 16 kHz 单声道 float32 采样
Float32List buildSpeechLikeSamples(double seconds) {
  const frameLength = 320; // 20 ms @ 16 kHz
  final total = (seconds * 16000).round();
  final samples = Float32List(total);
  for (var i = 0; i < total; i++) {
    samples[i] = (i ~/ frameLength) % 5 == 0 ? 0.2 : 0.001;
  }
  return samples;
}

/// 构造供页面内置样本使用的假 WAV 字节（44 字节头 + 静音 PCM16 载荷）。
///
/// 页面只跳过 44 字节头后按 PCM16 解析、不校验头内容，
/// 因此无需构造真实的 WAV 结构。
///
/// @param seconds 音频时长（秒）
/// @return WAV 字节
Uint8List buildFakeWavBytes({double seconds = 0.1}) {
  final payloadLength = (seconds * 16000).round() * 2;
  return Uint8List(44 + payloadLength);
}
