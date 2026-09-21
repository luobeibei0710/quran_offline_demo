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
      case "acceptanceLog":
        guard let message = call.arguments as? String else {
          result(FlutterError(code: "QURAN_BAD_INPUT", message: "日志格式无效", details: nil))
          return
        }
        NSLog("[QuranDemo] %@", message)
        result(nil)

      case "loadModel":
        guard let args = call.arguments as? [String: Any],
              let assetPath = args["path"] as? String, !assetPath.isEmpty else {
          result(FlutterError(code: "QURAN_BAD_INPUT", message: "模型路径为空", details: nil))
          return
        }
        DispatchQueue.global(qos: .userInitiated).async {
          // ObjC 侧带 NSError** 的方法在 Swift 中被导入为 throws，失败直接抛错
          do {
            try bridge.loadModel(withAssetKey: assetPath)
            DispatchQueue.main.async { result(true) }
          } catch {
            let message = error.localizedDescription
            DispatchQueue.main.async {
              result(FlutterError(code: "QURAN_LOAD_FAILED", message: message, details: nil))
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
          // ObjC 侧 NSUInteger 在 Swift 中为 UInt
          let count = UInt(samples.count / MemoryLayout<Float>.size)
          var payload: [String: Any]?
          var failure: Error?
          samples.withUnsafeBytes { pointer in
            guard let base = pointer.bindMemory(to: Float.self).baseAddress else { return }
            do {
              payload = try bridge.run(withSamples: base, count: count)
            } catch {
              failure = error
            }
          }
          DispatchQueue.main.async {
            if let payload = payload {
              result(payload)
            } else {
              result(FlutterError(
                code: "QURAN_RUN_FAILED",
                message: failure?.localizedDescription ?? "推理失败",
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
