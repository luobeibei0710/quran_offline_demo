package com.llvision.quran_broadcast_sdk

import android.app.Activity
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.WindowManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** Native implementation of the ORT and keep-screen-on channels used by the SDK. */
class QuranBroadcastSdkPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware {
    companion object {
        private const val ORT_CHANNEL = "quran_offline/ort"
        private const val SCREEN_CHANNEL = "quran_offline/screen"
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val worker: ExecutorService = Executors.newSingleThreadExecutor()
    private val bridge = QuranOrtBridge.get()
    private val detached = AtomicBoolean(false)

    private lateinit var applicationContext: android.content.Context
    private var ortChannel: MethodChannel? = null
    private var screenChannel: MethodChannel? = null
    private var activity: Activity? = null
    private var screenFlagActivity: Activity? = null
    private var managesScreenFlag = false
    private var screenFlagWasSet = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        detached.set(false)
        applicationContext = binding.applicationContext
        ortChannel = MethodChannel(binding.binaryMessenger, ORT_CHANNEL).also {
            it.setMethodCallHandler(this)
        }
        screenChannel = MethodChannel(binding.binaryMessenger, SCREEN_CHANNEL).also {
            it.setMethodCallHandler { call, result -> handleScreenCall(call, result) }
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (detached.get()) return
        when (call.method) {
            "acceptanceLog" -> {
                val message = call.arguments as? String
                if (message == null) {
                    result.error("QURAN_BAD_INPUT", "日志格式无效", null)
                } else {
                    Log.i("QuranDemo", message)
                    result.success(null)
                }
            }

            "loadModel" -> {
                val assetPath = call.argument<String>("path")
                if (assetPath.isNullOrEmpty()) {
                    result.error("QURAN_BAD_INPUT", "模型路径为空", null)
                    return
                }
                worker.execute {
                    if (detached.get()) return@execute
                    try {
                        bridge.load(applicationContext, assetPath)
                        mainHandler.post {
                            if (!detached.get()) result.success(true)
                        }
                    } catch (error: Exception) {
                        mainHandler.post {
                            if (!detached.get()) result.error("QURAN_LOAD_FAILED", error.message, null)
                        }
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
                    if (detached.get()) return@execute
                    try {
                        val payload = bridge.run(samples)
                        mainHandler.post {
                            if (!detached.get()) result.success(payload)
                        }
                    } catch (error: Exception) {
                        mainHandler.post {
                            if (!detached.get()) result.error("QURAN_RUN_FAILED", error.message, null)
                        }
                    }
                }
            }

            "dispose" -> {
                worker.execute {
                    if (detached.get()) return@execute
                    bridge.dispose()
                    mainHandler.post {
                        if (!detached.get()) result.success(null)
                    }
                }
            }

            else -> result.notImplemented()
        }
    }

    private fun handleScreenCall(call: MethodCall, result: MethodChannel.Result) {
        if (detached.get()) return
        if (call.method != "setKeepScreenOn") {
            result.notImplemented()
            return
        }
        val enabled = call.argument<Boolean>("enabled")
        if (enabled == null) {
            result.error("QURAN_BAD_INPUT", "参数缺失", null)
            return
        }
        val currentActivity = activity
        if (currentActivity == null) {
            result.error("QURAN_ACTIVITY_UNAVAILABLE", "当前 Flutter 引擎未附着 Activity", null)
            return
        }
        mainHandler.post {
            if (detached.get()) return@post
            if (enabled) {
                if (managesScreenFlag && screenFlagActivity !== currentActivity) {
                    restoreScreenFlag()
                }
                if (!managesScreenFlag) {
                    screenFlagActivity = currentActivity
                    screenFlagWasSet = currentActivity.window.attributes.flags and
                        WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON != 0
                    managesScreenFlag = true
                }
                currentActivity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            } else {
                restoreScreenFlag()
            }
            result.success(null)
        }
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        restoreScreenFlag()
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivity() {
        restoreScreenFlag()
        activity = null
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        if (!detached.compareAndSet(false, true)) return
        ortChannel?.setMethodCallHandler(null)
        ortChannel = null
        screenChannel?.setMethodCallHandler(null)
        screenChannel = null
        if (Looper.myLooper() == Looper.getMainLooper()) {
            restoreScreenFlag()
        } else {
            mainHandler.post { restoreScreenFlag() }
        }
        // Existing load/run work is serialized on this executor. Queue disposal after it so a
        // running inference can finish without blocking the platform detach callback; all queued
        // work observes [detached] and drops its messenger callback before this cleanup runs.
        worker.execute {
            bridge.dispose()
            worker.shutdown()
        }
    }

    private fun restoreScreenFlag() {
        if (!managesScreenFlag) return
        val owner = screenFlagActivity
        if (owner != null) {
            if (screenFlagWasSet) {
                owner.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            } else {
                owner.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            }
        }
        managesScreenFlag = false
        screenFlagActivity = null
        screenFlagWasSet = false
    }
}
