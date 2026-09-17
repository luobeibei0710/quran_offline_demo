#import "QuranOrtBridge.h"

#import <Flutter/Flutter.h>
#import <onnxruntime.h>

/** 复制模型时的缓冲区大小。 */
static const size_t kCopyBufferSize = 1 << 16;

/** 模型在沙盒中的缓存文件名（ORT 1.22 兼容版）。 */
static NSString *const kModelFileName = @"fastconformer_full_mixed_ort122.onnx";

@implementation QuranOrtBridge {
  ORTEnv *_env;
  ORTSession *_session;
  NSString *_audioInputName;
  NSString *_lengthInputName;
}

+ (instancetype)sharedInstance {
  static QuranOrtBridge *instance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    instance = [[QuranOrtBridge alloc] init];
  });
  return instance;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _audioInputName = @"audio_signal";
    _lengthInputName = @"length";
  }
  return self;
}

- (BOOL)loadModelWithAssetKey:(NSString *)assetKey error:(NSError **)error {
  @synchronized(self) {
    if (_session != nil) {
      return YES;
    }

    NSString *modelPath = [self ensureModelFileWithAssetKey:assetKey error:error];
    if (modelPath == nil) {
      return NO;
    }

    NSDate *startAt = [NSDate date];
    _env = [[ORTEnv alloc] initWithLoggingLevel:ORTLoggingLevelWarning error:error];
    if (_env == nil) {
      return NO;
    }

    ORTSessionOptions *options = [[ORTSessionOptions alloc] initWithError:error];
    if (options == nil) {
      return NO;
    }
    NSUInteger cores = [NSProcessInfo processInfo].processorCount;
    [options setIntraOpNumThreads:(cores > 2 ? cores / 2 : 2) error:error];

    _session = [[ORTSession alloc] initWithEnv:_env modelPath:modelPath sessionOptions:options error:error];
    if (_session == nil) {
      return NO;
    }

    NSLog(@"[QuranOrtBridge] model loaded in %.0f ms, path=%@",
          [[NSDate date] timeIntervalSinceDate:startAt] * 1000.0, modelPath);
    return YES;
  }
}

- (nullable NSDictionary<NSString *, id> *)runWithSamples:(const float *)samples
                                                    count:(NSUInteger)count
                                                    error:(NSError **)error {
  @synchronized(self) {
    if (_session == nil) {
      if (error != NULL) {
        *error = [NSError errorWithDomain:@"QuranOrtBridge"
                                     code:-1
                                 userInfo:@{NSLocalizedDescriptionKey: @"模型尚未加载"}];
      }
      return nil;
    }

    NSMutableData *audioData = [NSMutableData dataWithBytes:samples length:count * sizeof(float)];
    ORTValue *audioValue = [[ORTValue alloc] initWithTensorData:audioData
                                                   elementType:ORTTensorElementDataTypeFloat
                                                         shape:@[ @1, @(count) ]
                                                         error:error];
    if (audioValue == nil) {
      return nil;
    }

    int64_t length = (int64_t)count;
    NSMutableData *lengthData = [NSMutableData dataWithBytes:&length length:sizeof(int64_t)];
    ORTValue *lengthValue = [[ORTValue alloc] initWithTensorData:lengthData
                                                     elementType:ORTTensorElementDataTypeInt64
                                                           shape:@[ @1 ]
                                                           error:error];
    if (lengthValue == nil) {
      return nil;
    }

    NSDictionary<NSString *, ORTValue *> *inputs = @{
      _audioInputName : audioValue,
      _lengthInputName : lengthValue,
    };
    // ORT ObjC 1.22 的 run 需要显式 runOptions（不需要时传 nil）
    NSDictionary<NSString *, ORTValue *> *outputs =
        [_session runWithInputs:inputs
                    outputNames:[NSSet setWithObject:@"log_probs"]
                     runOptions:nil
                          error:error];
    ORTValue *logProbs = outputs[@"log_probs"];
    if (logProbs == nil) {
      return nil;
    }

    // ORTValue 上没有 shapeWithError:，形状信息经 ORTTensorTypeAndShapeInfo 取得
    ORTTensorTypeAndShapeInfo *shapeInfo = [logProbs tensorTypeAndShapeInfoWithError:error];
    if (shapeInfo == nil) {
      return nil;
    }
    NSArray<NSNumber *> *shape = shapeInfo.shape;
    if (shape.count < 3) {
      return nil;
    }
    NSInteger timeSteps = shape[1].integerValue;
    NSInteger vocabSize = shape[2].integerValue;

    NSMutableData *raw = [logProbs tensorDataWithError:error];
    if (raw == nil) {
      return nil;
    }
    float *flat = (float *)raw.mutableBytes;

    NSMutableData *result = [NSMutableData dataWithLength:(NSUInteger)(timeSteps * vocabSize) * sizeof(float)];
    float *dst = (float *)result.mutableBytes;
    for (NSInteger t = 0; t < timeSteps; t++) {
      memcpy(dst + t * vocabSize, flat + t * vocabSize, (size_t)vocabSize * sizeof(float));
    }

    return @{
      @"logprobs" : [FlutterStandardTypedData typedDataWithFloat32:result],
      @"timeSteps" : @(timeSteps),
      @"vocabSize" : @(vocabSize),
    };
  }
}

- (void)dispose {
  @synchronized(self) {
    _session = nil;
    _env = nil;
  }
}

#pragma mark - Private

/**
 * 确保模型文件存在于沙盒缓存目录，返回其绝对路径。
 *
 * @param assetKey Flutter 资产路径
 * @param error    失败时返回错误详情
 * @return 模型文件路径；失败返回 nil
 */
- (nullable NSString *)ensureModelFileWithAssetKey:(NSString *)assetKey error:(NSError **)error {
  NSString *cacheDir = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
  NSString *target = [cacheDir stringByAppendingPathComponent:kModelFileName];

  NSFileManager *fileManager = [NSFileManager defaultManager];
  if ([fileManager fileExistsAtPath:target]) {
    return target;
  }

  NSString *key = [FlutterDartProject lookupKeyForAsset:assetKey];
  NSString *source = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:key];
  if (![fileManager fileExistsAtPath:source]) {
    if (error != NULL) {
      *error = [NSError errorWithDomain:@"QuranOrtBridge"
                                   code:-2
                               userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"模型资产不存在: %@", source]}];
    }
    return nil;
  }

  return [fileManager copyItemAtPath:source toPath:target error:error] ? target : nil;
}

@end
