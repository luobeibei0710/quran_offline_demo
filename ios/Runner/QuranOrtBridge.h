#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * 古兰经离线识别的 ONNX Runtime 桥（iOS）。
 *
 * 在原生侧加载 Tilawa 声学模型（FastConformer，int4/int8 混合量化），执行一次前向
 * 推理并把逐帧 log 概率回传 Flutter；CTC 解码与经文约束匹配在 Dart 侧完成。
 *
 * 输入输出约定与 Android 侧 `QuranOrtBridge.java` 完全一致：
 * - 输入：16 kHz 单声道 float32 PCM，张量 `audio_signal` + 长度张量 `length`
 * - 输出：`log_probs`，形状 `[1, frames, vocab]`，按行主序展平回传
 */
@interface QuranOrtBridge : NSObject

/**
 * 获取单例。
 *
 * @return 桥实例
 */
+ (instancetype)sharedInstance;

/**
 * 加载模型（幂等）。
 *
 * @param assetKey Flutter 资产路径，例如 assets/quran_offline/fastconformer_full_mixed.onnx
 * @param error    失败时返回错误详情
 * @return 成功返回 YES
 */
- (BOOL)loadModelWithAssetKey:(NSString *)assetKey error:(NSError **)error;

/**
 * 执行一次前向推理。
 *
 * @param samples 16 kHz 单声道 float32 音频首地址
 * @param count   采样点个数
 * @param error   失败时返回错误详情
 * @return 含 logprobs（FlutterStandardTypedData）、timeSteps、vocabSize 的字典；失败返回 nil
 */
- (nullable NSDictionary<NSString *, id> *)runWithSamples:(const float *)samples
                                                    count:(NSUInteger)count
                                                    error:(NSError **)error;

/**
 * 释放会话与环境。
 */
- (void)dispose;

@end

NS_ASSUME_NONNULL_END
