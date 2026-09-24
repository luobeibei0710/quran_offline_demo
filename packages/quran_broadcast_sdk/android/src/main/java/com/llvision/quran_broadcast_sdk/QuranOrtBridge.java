package com.llvision.quran_broadcast_sdk;

import android.content.Context;
import android.content.res.AssetManager;
import android.util.Log;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.nio.FloatBuffer;
import java.nio.LongBuffer;
import java.nio.charset.StandardCharsets;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.Files;
import java.nio.file.StandardCopyOption;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import ai.onnxruntime.OnnxTensor;
import ai.onnxruntime.OrtEnvironment;
import ai.onnxruntime.OrtSession;

/** ONNX Runtime bridge for the SDK's 16 kHz PCM acoustic model. */
public final class QuranOrtBridge {
    private static final String TAG = "QuranOrtBridge";
    private static final int COPY_BUFFER_SIZE = 1 << 16;
    private static QuranOrtBridge instance;

    private OrtEnvironment environment;
    private OrtSession session;
    private String audioInputName = "audio_signal";
    private String lengthInputName = "length";

    private QuranOrtBridge() {}

    public static synchronized QuranOrtBridge get() {
        if (instance == null) instance = new QuranOrtBridge();
        return instance;
    }

    public synchronized void load(Context context, String assetKey) throws Exception {
        if (session != null) return;
        File modelFile = ensureModelFile(context, assetKey);
        environment = OrtEnvironment.getEnvironment();
        try (OrtSession.SessionOptions options = new OrtSession.SessionOptions()) {
            int threads = Math.max(2, Runtime.getRuntime().availableProcessors() / 2);
            options.setIntraOpNumThreads(threads);
            options.setInterOpNumThreads(1);
            session = environment.createSession(modelFile.getAbsolutePath(), options);
        }
        for (String name : session.getInputNames()) {
            if (name.contains("audio")) audioInputName = name;
            else if (name.contains("length")) lengthInputName = name;
        }
        List<String> outputs = new ArrayList<>(session.getOutputNames());
        Log.i(TAG, "model loaded, inputs=" + session.getInputNames() + ", outputs=" + outputs);
    }

    public synchronized Map<String, Object> run(float[] samples) throws Exception {
        if (session == null) throw new IllegalStateException("模型尚未加载，请先调用 load()");
        long[] audioShape = new long[]{1, samples.length};
        long[] lengthShape = new long[]{1};
        try (OnnxTensor audioTensor = OnnxTensor.createTensor(environment, FloatBuffer.wrap(samples), audioShape);
             OnnxTensor lengthTensor = OnnxTensor.createTensor(
                     environment, LongBuffer.wrap(new long[]{samples.length}), lengthShape)) {
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
        } catch (Exception error) {
            Log.w(TAG, "dispose failed", error);
        }
    }

    private File ensureModelFile(Context context, String assetKey) throws Exception {
        String key = assetKey;
        try {
            key = io.flutter.FlutterInjector.instance().flutterLoader().getLookupKeyForAsset(assetKey);
        } catch (Throwable error) {
            Log.w(TAG, "getLookupKeyForAsset failed, using supplied key", error);
        }
        AssetManager assets = context.getAssets();
        File cacheDir = context.getFilesDir();
        File target = new File(cacheDir, "quran_ort_" + sha256OfBytes(assetKey.getBytes(StandardCharsets.UTF_8)) + ".onnx");

        String assetDigest;
        try (InputStream input = assets.open(key)) {
            assetDigest = sha256(input);
        }
        if (target.isFile() && target.length() > 0 && assetDigest.equals(sha256(target))) {
            return target;
        }

        File temporary = File.createTempFile(target.getName() + ".", ".tmp", cacheDir);
        try {
            try (InputStream input = assets.open(key); FileOutputStream output = new FileOutputStream(temporary)) {
                byte[] buffer = new byte[COPY_BUFFER_SIZE];
                int read;
                while ((read = input.read(buffer)) > 0) output.write(buffer, 0, read);
                output.getFD().sync();
            }
            if (!assetDigest.equals(sha256(temporary))) {
                throw new IllegalStateException("复制后的模型摘要与打包资产不一致");
            }
            replaceAtomically(temporary, target);
        } catch (Exception error) {
            if (temporary.exists() && !temporary.delete()) {
                Log.w(TAG, "failed to remove incomplete model cache: " + temporary);
            }
            throw error;
        }
        return target;
    }

    private static void replaceAtomically(File temporary, File target) throws Exception {
        try {
            Files.move(
                    temporary.toPath(),
                    target.toPath(),
                    StandardCopyOption.ATOMIC_MOVE,
                    StandardCopyOption.REPLACE_EXISTING);
        } catch (AtomicMoveNotSupportedException unsupported) {
            // Files are in the same private directory. Keep the old cache until the complete
            // temporary file exists; this fallback only serves filesystems without ATOMIC_MOVE.
            Files.move(temporary.toPath(), target.toPath(), StandardCopyOption.REPLACE_EXISTING);
        }
    }

    private static String sha256(File file) throws Exception {
        try (InputStream input = Files.newInputStream(file.toPath())) {
            return sha256(input);
        }
    }

    private static String sha256(InputStream input) throws Exception {
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        byte[] buffer = new byte[COPY_BUFFER_SIZE];
        int read;
        while ((read = input.read(buffer)) > 0) digest.update(buffer, 0, read);
        return sha256(digest.digest());
    }

    private static String sha256(byte[] bytes) {
        StringBuilder hex = new StringBuilder(bytes.length * 2);
        for (byte value : bytes) hex.append(String.format("%02x", value & 0xff));
        return hex.toString();
    }

    private static String sha256OfBytes(byte[] bytes) throws Exception {
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        return sha256(digest.digest(bytes));
    }
}
