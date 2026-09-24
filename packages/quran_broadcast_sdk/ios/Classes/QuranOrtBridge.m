#import "QuranOrtBridge.h"
#import <Flutter/Flutter.h>
#import <onnxruntime_objc/onnxruntime.h>
#import <CommonCrypto/CommonDigest.h>

static const NSUInteger kCopyBufferSize = 1 << 16;

@implementation QuranOrtBridge {
  ORTEnv *_env;
  ORTSession *_session;
  NSString *_audioInputName;
  NSString *_lengthInputName;
}

+ (instancetype)sharedInstance {
  static QuranOrtBridge *instance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{ instance = [[QuranOrtBridge alloc] init]; });
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
    if (_session != nil) return YES;
    NSString *modelPath = [self ensureModelFileWithAssetKey:assetKey error:error];
    if (modelPath == nil) return NO;
    _env = [[ORTEnv alloc] initWithLoggingLevel:ORTLoggingLevelWarning error:error];
    if (_env == nil) return NO;
    ORTSessionOptions *options = [[ORTSessionOptions alloc] initWithError:error];
    if (options == nil) return NO;
    NSUInteger cores = [NSProcessInfo processInfo].processorCount;
    [options setIntraOpNumThreads:(cores > 2 ? cores / 2 : 2) error:error];
    _session = [[ORTSession alloc] initWithEnv:_env modelPath:modelPath sessionOptions:options error:error];
    return _session != nil;
  }
}

- (nullable NSDictionary<NSString *, id> *)runWithSamples:(const float *)samples
                                                    count:(NSUInteger)count
                                                    error:(NSError **)error {
  @synchronized(self) {
    if (_session == nil) {
      if (error != NULL) *error = [NSError errorWithDomain:@"QuranOrtBridge"
                                                       code:-1
                                                   userInfo:@{NSLocalizedDescriptionKey: @"模型尚未加载"}];
      return nil;
    }
    NSMutableData *audioData = [NSMutableData dataWithBytes:samples length:count * sizeof(float)];
    ORTValue *audioValue = [[ORTValue alloc] initWithTensorData:audioData
                                                     elementType:ORTTensorElementDataTypeFloat
                                                           shape:@[@1, @(count)] error:error];
    if (audioValue == nil) return nil;
    int64_t length = (int64_t)count;
    NSMutableData *lengthData = [NSMutableData dataWithBytes:&length length:sizeof(int64_t)];
    ORTValue *lengthValue = [[ORTValue alloc] initWithTensorData:lengthData
                                                      elementType:ORTTensorElementDataTypeInt64
                                                            shape:@[@1] error:error];
    if (lengthValue == nil) return nil;
    NSDictionary<NSString *, ORTValue *> *outputs = [_session
        runWithInputs:@{_audioInputName: audioValue, _lengthInputName: lengthValue}
        outputNames:[NSSet setWithObject:@"log_probs"] runOptions:nil error:error];
    ORTValue *logProbs = outputs[@"log_probs"];
    if (logProbs == nil) return nil;
    ORTTensorTypeAndShapeInfo *shapeInfo = [logProbs tensorTypeAndShapeInfoWithError:error];
    if (shapeInfo == nil || shapeInfo.shape.count < 3) return nil;
    NSMutableData *raw = [logProbs tensorDataWithError:error];
    if (raw == nil) return nil;
    NSInteger timeSteps = shapeInfo.shape[1].integerValue;
    NSInteger vocabSize = shapeInfo.shape[2].integerValue;
    return @{
      @"logprobs": [FlutterStandardTypedData typedDataWithFloat32:raw],
      @"timeSteps": @(timeSteps),
      @"vocabSize": @(vocabSize),
    };
  }
}

- (void)dispose {
  @synchronized(self) {
    _session = nil;
    _env = nil;
  }
}

- (nullable NSString *)ensureModelFileWithAssetKey:(NSString *)assetKey error:(NSError **)error {
  NSString *cacheDir = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
  NSFileManager *fileManager = [NSFileManager defaultManager];
  NSString *key = [FlutterDartProject lookupKeyForAsset:assetKey];
  NSString *source = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:key];
  if (![fileManager fileExistsAtPath:source]) {
    if (error != NULL) *error = [NSError errorWithDomain:@"QuranOrtBridge"
                                                     code:-2
                                                 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"模型资产不存在: %@", source]}];
    return nil;
  }

  NSString *assetDigest = [self sha256ForFileAtPath:source error:error];
  if (assetDigest == nil) return nil;
  NSString *keyDigest = [self sha256ForData:[assetKey dataUsingEncoding:NSUTF8StringEncoding]];
  NSString *target = [cacheDir stringByAppendingPathComponent:
      [NSString stringWithFormat:@"quran_ort_%@.onnx", keyDigest]];
  if ([fileManager fileExistsAtPath:target]) {
    NSString *cachedDigest = [self sha256ForFileAtPath:target error:nil];
    if (cachedDigest != nil && [assetDigest isEqualToString:cachedDigest]) return target;
  }

  NSString *temporary = [cacheDir stringByAppendingPathComponent:
      [NSString stringWithFormat:@".%@.%@.tmp", target.lastPathComponent, NSUUID.UUID.UUIDString]];
  NSError *copyError = nil;
  if (![fileManager copyItemAtPath:source toPath:temporary error:&copyError]) {
    if (error != NULL) *error = copyError;
    return nil;
  }

  BOOL installed = NO;
  NSError *installError = nil;
  @try {
    NSString *temporaryDigest = [self sha256ForFileAtPath:temporary error:&installError];
    if (temporaryDigest == nil || ![assetDigest isEqualToString:temporaryDigest]) {
      if (installError == nil) {
        installError = [NSError errorWithDomain:@"QuranOrtBridge"
                                           code:-3
                                       userInfo:@{NSLocalizedDescriptionKey: @"复制后的模型摘要与打包资产不一致"}];
      }
    } else if ([fileManager fileExistsAtPath:target]) {
      installed = [fileManager replaceItemAtURL:[NSURL fileURLWithPath:target]
                                  withItemAtURL:[NSURL fileURLWithPath:temporary]
                                 backupItemName:nil
                                        options:0
                               resultingItemURL:nil
                                          error:&installError];
    } else {
      installed = [fileManager moveItemAtPath:temporary toPath:target error:&installError];
    }
  } @finally {
    if ([fileManager fileExistsAtPath:temporary]) {
      [fileManager removeItemAtPath:temporary error:nil];
    }
  }
  if (!installed) {
    if (error != NULL) *error = installError;
    return nil;
  }
  return target;
}

- (nullable NSString *)sha256ForFileAtPath:(NSString *)path error:(NSError **)error {
  NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
  if (handle == nil) {
    if (error != NULL) *error = [NSError errorWithDomain:@"QuranOrtBridge"
                                                     code:-4
                                                 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"无法读取模型: %@", path]}];
    return nil;
  }
  CC_SHA256_CTX context;
  CC_SHA256_Init(&context);
  @try {
    while (true) {
      NSData *chunk = [handle readDataOfLength:kCopyBufferSize];
      if (chunk.length == 0) break;
      CC_SHA256_Update(&context, chunk.bytes, (CC_LONG)chunk.length);
    }
  } @catch (NSException *exception) {
    if (error != NULL) *error = [NSError errorWithDomain:@"QuranOrtBridge"
                                                     code:-5
                                                 userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: @"读取模型失败"}];
    [handle closeFile];
    return nil;
  }
  [handle closeFile];
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256_Final(digest, &context);
  NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
  for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index++) {
    [hex appendFormat:@"%02x", digest[index]];
  }
  return hex;
}

- (NSString *)sha256ForData:(NSData *)data {
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
  NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
  for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index++) {
    [hex appendFormat:@"%02x", digest[index]];
  }
  return hex;
}

@end
