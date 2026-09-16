package com.llvision.quran_offline_demo

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * 古兰经离线识别 Demo 的 Android 入口。
 *
 * 注册 `quran_offline/ort` 通道，把 Dart 侧的推理请求转给 [QuranOrtBridge]。
 * 模型加载与推理都在单线程池执行，避免阻塞主线程；结果统一回投到主线程。
 */
class MainActivity : FlutterActivity() {

    companion object {
        /** 与 Dart 侧 `PlatformOrtRunner.channelName` 保持一致。 */
        private const val CHANNEL_NAME = "quran_offline/ort"
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val worker: ExecutorService = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
            .setMethodCallHandler { call, result -> handleOrtCall(call, result) }
    }

    /**
     * 处理推理桥调用。
     *
     * @param call   方法调用（loadModel / run / dispose）
     * @param result 结果回调
     */
    private fun handleOrtCall(call: MethodCall, result: MethodChannel.Result) {
        val bridge = QuranOrtBridge.get()
        when (call.method) {
            "loadModel" -> {
                val assetPath = call.argument<String>("path")
                if (assetPath.isNullOrEmpty()) {
                    result.error("QURAN_BAD_INPUT", "模型路径为空", null)
                    return
                }
                worker.execute {
                    try {
                        bridge.load(applicationContext, assetPath)
                        mainHandler.post { result.success(true) }
                    } catch (e: Exception) {
                        mainHandler.post { result.error("QURAN_LOAD_FAILED", e.message, null) }
                    }
                }
            }

            "run" -> {
                val samples = call.argument<FloatArray>("samples")
                if (samples == null || samples.isEmpty()) {
                    result.error("QURAN_BAD_INPUT", "音频数据为空", null)
                    return
                }
                worker.execute {
                    try {
                        val payload = bridge.run(samples)
                        mainHandler.post { result.success(payload) }
                    } catch (e: Exception) {
                        mainHandler.post { result.error("QURAN_RUN_FAILED", e.message, null) }
                    }
                }
            }

            "dispose" -> {
                bridge.dispose()
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    override fun onDestroy() {
        worker.shutdown()
        super.onDestroy()
    }
}
