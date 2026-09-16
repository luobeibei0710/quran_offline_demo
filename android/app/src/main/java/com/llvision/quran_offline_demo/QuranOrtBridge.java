package com.llvision.quran_offline_demo;

import android.content.Context;
import android.content.res.AssetManager;
import android.util.Log;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.nio.FloatBuffer;
import java.nio.LongBuffer;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import ai.onnxruntime.OnnxTensor;
import ai.onnxruntime.OrtEnvironment;
import ai.onnxruntime.OrtSession;

/**
 * 古兰经离线识别的 ONNX Runtime 桥（Android）。
 *
 * <p>在原生侧加载 Tilawa 声学模型（FastConformer，int4/int8 混合量化），执行一次
 * 前向推理并把逐帧 log 概率回传 Flutter。CTC 解码、经文约束匹配、流式跟踪等算法
 * 全部在 Dart 侧实现，本类只做「模型 → 张量」的翻译。
 *
 * <p>约定：
 * <ul>
 *   <li>输入：16 kHz 单声道 float32 PCM（张量 {@code audio_signal} + 长度张量 {@code length}）</li>
 *   <li>输出：{@code log_probs}，形状 {@code [1, frames, vocab]}，按行主序展平回传</li>
 *   <li>模型首次使用时从 Flutter assets 复制到应用私有目录（约 88 MB，仅一次）</li>
 * </ul>
 */
public final class QuranOrtBridge {

    private static final String TAG = "QuranOrtBridge";

    /** 复制模型时的缓冲区大小。 */
    private static final int COPY_BUFFER_SIZE = 1 << 16;

    /** 模型在私有目录下的文件名（ORT 1.22 兼容版，含版本后缀以便缓存失效）。 */
    private static final String MODEL_FILE_NAME = "fastconformer_full_mixed_ort122.onnx";

    private static QuranOrtBridge instance;

    private OrtEnvironment environment;
    private OrtSession session;

    private String audioInputName = "audio_signal";
    private String lengthInputName = "length";

    private QuranOrtBridge() {
    }

    /**
     * 获取单例。
     *
     * @return 桥实例
     */
    public static synchronized QuranOrtBridge get() {
        if (instance == null) {
            instance = new QuranOrtBridge();
        }
        return instance;
    }

    /**
     * 加载模型（幂等）。模型文件不存在时先从 assets 复制。
     *
     * @param context  应用上下文
     * @param assetKey Flutter 资产路径，例如 {@code assets/quran_offline/fastconformer_full_mixed.onnx}
     * @throws Exception 复制失败或 ORT 加载失败
     */
    public synchronized void load(Context context, String assetKey) throws Exception {
        Log.i(TAG, "load() enter, assetKey=" + assetKey + ", cached=" + (session != null));
        if (session != null) {
            return;
        }
        File modelFile = ensureModelFile(context, assetKey);
        Log.i(TAG, "model file ready: " + modelFile.length() + " bytes");
        long startAt = System.currentTimeMillis();
        environment = OrtEnvironment.getEnvironment();
        Log.i(TAG, "OrtEnvironment ready (" + (System.currentTimeMillis() - startAt) + "ms)");
        OrtSession.SessionOptions options = new OrtSession.SessionOptions();
        // 推理是 CPU 密集型：留出一半核心给界面，避免主线程卡顿
        int cores = Runtime.getRuntime().availableProcessors();
        int threads = Math.max(2, cores / 2);
        options.setIntraOpNumThreads(threads);
        options.setInterOpNumThreads(1);
        Log.i(TAG, "creating session (threads=" + threads + ")...");
        session = environment.createSession(modelFile.getAbsolutePath(), options);

        for (String name : session.getInputNames()) {
            if (name.contains("audio")) {
                audioInputName = name;
            } else if (name.contains("length")) {
                lengthInputName = name;
            }
        }
        List<String> outputs = new ArrayList<>(session.getOutputNames());
        Log.i(TAG, "model loaded in " + (System.currentTimeMillis() - startAt) + "ms, inputs="
                + session.getInputNames() + ", outputs=" + outputs + ", threads=" + threads);
    }

    /**
     * 执行一次前向推理。
     *
     * @param samples 16 kHz 单声道 float32 音频
     * @return 包含 logprobs（float[]）、timeSteps、vocabSize 的结果
     * @throws Exception 未加载模型或推理失败
     */
    public synchronized Map<String, Object> run(float[] samples) throws Exception {
        if (session == null) {
            throw new IllegalStateException("模型尚未加载，请先调用 load()");
        }
        long[] audioShape = new long[]{1, samples.length};
        long[] lengthShape = new long[]{1};

        try (OnnxTensor audioTensor =
                     OnnxTensor.createTensor(environment, FloatBuffer.wrap(samples), audioShape);
             OnnxTensor lengthTensor =
                     OnnxTensor.createTensor(environment, LongBuffer.wrap(new long[]{samples.length}), lengthShape)) {

            Map<String, OnnxTensor> inputs = new HashMap<>();
            inputs.put(audioInputName, audioTensor);
            inputs.put(lengthInputName, lengthTensor);

            try (OrtSession.Result result = session.run(inputs)) {
                Object raw = result.get(0).getValue();
                float[] flat;
                int timeSteps;
                int vocabSize;

                if (raw instanceof float[][][]) {
                    float[][][] data = (float[][][]) raw;
                    timeSteps = data[0].length;
                    vocabSize = timeSteps > 0 ? data[0][0].length : 0;
                    flat = new float[timeSteps * vocabSize];
                    for (int t = 0; t < timeSteps; t++) {
                        System.arraycopy(data[0][t], 0, flat, t * vocabSize, vocabSize);
                    }
                } else if (raw instanceof float[][]) {
                    float[][] data = (float[][]) raw;
                    timeSteps = data.length;
                    vocabSize = timeSteps > 0 ? data[0].length : 0;
                    flat = new float[timeSteps * vocabSize];
                    for (int t = 0; t < timeSteps; t++) {
                        System.arraycopy(data[t], 0, flat, t * vocabSize, vocabSize);
                    }
                } else {
                    throw new IllegalStateException("未预期的模型输出类型: " + raw.getClass());
                }

                Map<String, Object> payload = new HashMap<>();
                payload.put("logprobs", flat);
                payload.put("timeSteps", timeSteps);
                payload.put("vocabSize", vocabSize);
                return payload;
            }
        }
    }

    /**
     * 释放会话与运行环境。
     */
    public synchronized void dispose() {
        try {
            if (session != null) {
                session.close();
                session = null;
            }
            if (environment != null) {
                environment.close();
                environment = null;
            }
        } catch (Exception e) {
            Log.w(TAG, "dispose failed", e);
        }
    }

    /**
     * 确保模型文件存在于应用私有目录，返回该文件。
     *
     * @param context  应用上下文
     * @param assetKey Flutter 资产路径
     * @return 私有目录中的模型文件
     * @throws Exception 复制失败
     */
    private File ensureModelFile(Context context, String assetKey) throws Exception {
        File target = new File(context.getFilesDir(), MODEL_FILE_NAME);
        if (target.exists() && target.length() > 0) {
            Log.i(TAG, "reuse cached model: " + target.length() + " bytes");
            return target;
        }

        String key = assetKey;
        try {
            key = io.flutter.FlutterInjector.instance().flutterLoader().getLookupKeyForAsset(assetKey);
        } catch (Throwable t) {
            Log.w(TAG, "getLookupKeyForAsset failed, fallback to raw key: " + assetKey, t);
        }

        AssetManager assets = context.getAssets();
        long startAt = System.currentTimeMillis();
        try (InputStream input = assets.open(key);
             FileOutputStream output = new FileOutputStream(target)) {
            byte[] buffer = new byte[COPY_BUFFER_SIZE];
            int read;
            while ((read = input.read(buffer)) > 0) {
                output.write(buffer, 0, read);
            }
            output.flush();
        }
        Log.i(TAG, "model copied to " + target.getAbsolutePath() + " ("
                + target.length() + " bytes) in " + (System.currentTimeMillis() - startAt) + "ms");
        return target;
    }
}
