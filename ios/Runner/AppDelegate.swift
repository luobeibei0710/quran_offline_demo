import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    registerQuranOrtChannel(registry: engineBridge.pluginRegistry)
  }

  /// 注册古兰经离线识别的推理通道（与 Android 侧同名 `quran_offline/ort`）。
  ///
  /// 模型加载与推理在后台队列执行，避免阻塞主线程；结果统一回投到主线程。
  ///
  /// - Parameter registry: Flutter 插件注册表，用于获取二进制信使。
  private func registerQuranOrtChannel(registry: FlutterPluginRegistry) {
    guard let registrar = registry.registrar(forPlugin: "QuranOrtBridge") else { return }
    let channel = FlutterMethodChannel(
      name: "quran_offline/ort",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      let bridge = QuranOrtBridge.sharedInstance()
      switch call.method {
      case "loadModel":
        guard let args = call.arguments as? [String: Any],
              let assetPath = args["path"] as? String, !assetPath.isEmpty else {
          result(FlutterError(code: "QURAN_BAD_INPUT", message: "模型路径为空", details: nil))
          return
        }
        DispatchQueue.global(qos: .userInitiated).async {
          var error: NSError?
          let ok = bridge.loadModel(withAssetKey: assetPath, error: &error)
          DispatchQueue.main.async {
            if ok {
              result(true)
            } else {
              result(FlutterError(
                code: "QURAN_LOAD_FAILED",
                message: error?.localizedDescription ?? "模型加载失败",
                details: nil
              ))
            }
          }
        }

      case "run":
        guard let args = call.arguments as? [String: Any],
              let typed = args["samples"] as? FlutterStandardTypedData,
              !typed.data.isEmpty else {
          result(FlutterError(code: "QURAN_BAD_INPUT", message: "音频数据为空", details: nil))
          return
        }
        let samples = typed.data
        DispatchQueue.global(qos: .userInitiated).async {
          var error: NSError?
          let count = samples.count / MemoryLayout<Float>.size
          let payload: [String: Any]? = samples.withUnsafeBytes { pointer -> [String: Any]? in
            guard let base = pointer.bindMemory(to: Float.self).baseAddress else { return nil }
            return bridge.run(withSamples: base, count: count, error: &error)
          }
          DispatchQueue.main.async {
            if let payload = payload {
              result(payload)
            } else {
              result(FlutterError(
                code: "QURAN_RUN_FAILED",
                message: error?.localizedDescription ?? "推理失败",
                details: nil
              ))
            }
          }
        }

      case "dispose":
        bridge.dispose()
        result(nil)

      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
