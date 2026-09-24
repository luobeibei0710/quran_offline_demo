/// 麦克风 PCM 转储：仅在显式开启时把插件交付的原始 PCM16 追加写入本地文件。
///
/// 用途：真机外放拾音出现丢词时，把「设备实际听到的音频」与数字音源放到同一
/// 个模型上对照，从而区分「外放拾音/链路问题」与「分段、匹配或模型问题」。
/// 控制器日志里的 `startSample` / `endSample` 与转储文件按采样序号一一对应，
/// 因此可以逐段精确裁出与某条终稿完全相同的音频。
///
/// 约束（诊断开关的边界）：
///
/// - **默认关闭**：只有 `BroadcastServices.bootstrap` 读到
///   `--dart-define=quran_dump_pcm=true` 时才创建；未开启时生产路径完全不执行
///   任何文件操作；
/// - **限额**：写入字节数达到 [maxBytes] 后停止写入并记录一次提示，不无限增长；
/// - **只写本地**：写应用私有外部目录（Android）或应用文档目录，不上传、不联网；
/// - **不改写音频**：写的是插件交付的原始字节，转储发生在 `pcm16ToFloat32`
///   之前，不影响后续任何推理输入。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// PCM 转储：把会话麦克风音频按采样顺序追加写入一个 .pcm 文件。
class AudioPcmDump {
  /// 构造转储。
  ///
  /// @param sampleRate 采样率（写入元数据用，不改变写入内容）
  /// @param maxBytes 写入上限；超过后停止写入
  AudioPcmDump({required this.sampleRate, this.maxBytes = 200 * 1024 * 1024});

  /// 采样率。
  final int sampleRate;

  /// 写入上限（字节）。
  final int maxBytes;

  RandomAccessFile? _file;
  int _written = 0;
  bool _stopped = false;
  String? _path;

  /// 转储文件路径；未成功打开时为 null。
  String? get path => _path;

  /// 是否已打开且仍在写入。
  bool get isActive => _file != null && !_stopped;

  /// 已写入字节数。
  int get writtenBytes => _written;

  /// 打开转储文件。
  ///
  /// 优先应用私有外部目录（可直接 `adb pull`），失败时退回应用文档目录
  /// （Debug 包可用 `run-as` 取出）。打开失败只记录日志，不影响收音。
  ///
  /// @return 是否成功打开
  Future<bool> open() async {
    if (_file != null || _stopped) return isActive;
    try {
      final directory = await _resolveDirectory();
      if (directory == null) return false;
      final file = File(
        '${directory.path}/mic_${DateTime.now().millisecondsSinceEpoch}.pcm',
      );
      _file = await file.open(mode: FileMode.writeOnlyAppend);
      _path = file.path;
      debugPrint(
        '[Broadcast] PCM 转储已开启：${file.path}（上限 ${maxBytes ~/ (1024 * 1024)} MB）',
      );
      return true;
    } catch (error) {
      debugPrint('[Broadcast] PCM 转储开启失败：$error');
      return false;
    }
  }

  /// 追加一段原始 PCM16 字节（小端）。
  ///
  /// @param bytes 插件交付的原始音频字节
  void write(Uint8List bytes) {
    final file = _file;
    if (file == null || _stopped || bytes.isEmpty) return;
    if (_written + bytes.length > maxBytes) {
      _stopped = true;
      debugPrint('[Broadcast] PCM 转储已达上限，停止写入（$_written 字节）');
      return;
    }
    try {
      file.writeFromSync(bytes);
      _written += bytes.length;
    } catch (error) {
      _stopped = true;
      debugPrint('[Broadcast] PCM 转储写入失败：$error');
    }
  }

  /// 关闭文件；幂等。
  Future<void> close() async {
    final file = _file;
    _file = null;
    if (file == null) return;
    try {
      await file.flush();
      await file.close();
      debugPrint('[Broadcast] PCM 转储已关闭：$_written 字节');
    } catch (error) {
      debugPrint('[Broadcast] PCM 转储关闭失败：$error');
    }
  }

  Future<Directory?> _resolveDirectory() async {
    try {
      final external = await getExternalStorageDirectory();
      if (external != null) {
        if (!await external.exists()) {
          await external.create(recursive: true);
        }
        return external;
      }
    } catch (_) {
      // 外部目录不可用时退回应用文档目录。
    }
    return getApplicationDocumentsDirectory();
  }
}
