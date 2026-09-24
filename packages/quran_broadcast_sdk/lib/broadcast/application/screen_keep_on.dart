/// 屏幕常亮开关：真机连续收音期间阻止系统息屏。
///
/// 为什么需要它：Android 9 起后台应用无法访问麦克风（audioserver 对后台 UID 返回
/// 静音），而系统息屏会把前台应用切到后台。连续 30 分钟以上的外放收音验证因此
/// 必须在识别期间保持屏幕点亮。
///
/// iOS 用 `isIdleTimerDisabled` 实现同一语义（锁屏会把应用挂起、收音随之中断），
/// Android 用 `FLAG_KEEP_SCREEN_ON`。其它平台（如桌面）未实现该通道，调用方必须容忍
/// `MissingPluginException`；本文件统一吞掉平台异常，不把「某平台不支持」变成崩溃。
/// 会话控制器在成功开麦后启用，停止和释放时关闭。
library;

import 'package:flutter/services.dart';

/// 屏幕常亮开关。
class ScreenKeepOn {
  const ScreenKeepOn._();

  /// 与 Android/iOS 插件约定的通道名。
  static const String channelName = 'quran_offline/screen';

  static const MethodChannel _channel = MethodChannel(channelName);

  /// 设置识别期间是否保持屏幕常亮。
  ///
  /// @param enabled true 阻止息屏；false 恢复系统默认
  static Future<void> setEnabled(bool enabled) async {
    try {
      await _channel.invokeMethod<void>('setKeepScreenOn', {
        'enabled': enabled,
      });
    } on MissingPluginException {
      // 该平台未实现（如桌面）：保持屏幕策略交由系统，不影响收音逻辑。
    } on PlatformException catch (error) {
      // 通道存在但原生侧失败：同样不能影响识别链路。
      assert(() {
        // ignore: avoid_print
        print('[Broadcast] 屏幕常亮设置失败：${error.code}');
        return true;
      }());
    }
  }
}
