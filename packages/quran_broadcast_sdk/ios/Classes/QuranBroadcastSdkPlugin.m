#import "QuranBroadcastSdkPlugin.h"
#import "QuranOrtBridge.h"
#import <UIKit/UIKit.h>

static NSString *const kOrtChannel = @"quran_offline/ort";
static NSString *const kScreenChannel = @"quran_offline/screen";

@implementation QuranBroadcastSdkPlugin {
  FlutterMethodChannel *_ortChannel;
  FlutterMethodChannel *_screenChannel;
  dispatch_queue_t _workQueue;
  BOOL _detached;
  BOOL _managesIdleTimer;
  BOOL _previousIdleTimerDisabled;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _workQueue = dispatch_queue_create("com.llvision.quran_broadcast_sdk.ort", DISPATCH_QUEUE_SERIAL);
  }
  return self;
}

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  QuranBroadcastSdkPlugin *instance = [[QuranBroadcastSdkPlugin alloc] init];
  instance->_ortChannel = [FlutterMethodChannel
      methodChannelWithName:kOrtChannel binaryMessenger:[registrar messenger]];
  [instance->_ortChannel setMethodCallHandler:^(FlutterMethodCall *call, FlutterResult result) {
    [instance handleMethodCall:call result:result];
  }];

  instance->_screenChannel = [FlutterMethodChannel
      methodChannelWithName:kScreenChannel binaryMessenger:[registrar messenger]];
  [instance->_screenChannel setMethodCallHandler:^(FlutterMethodCall *call, FlutterResult result) {
    [instance handleScreenCall:call result:result];
  }];
  [registrar publish:instance];
}

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
  QuranOrtBridge *bridge = [QuranOrtBridge sharedInstance];
  if ([call.method isEqualToString:@"acceptanceLog"]) {
    if (![call.arguments isKindOfClass:[NSString class]]) {
      result([FlutterError errorWithCode:@"QURAN_BAD_INPUT" message:@"日志格式无效" details:nil]);
      return;
    }
    NSLog(@"[QuranDemo] %@", call.arguments);
    result(nil);
  } else if ([call.method isEqualToString:@"loadModel"]) {
    NSDictionary *arguments = [call.arguments isKindOfClass:[NSDictionary class]] ? call.arguments : nil;
    NSString *assetPath = arguments[@"path"];
    if (![assetPath isKindOfClass:[NSString class]] || assetPath.length == 0) {
      result([FlutterError errorWithCode:@"QURAN_BAD_INPUT" message:@"模型路径为空" details:nil]);
      return;
    }
    dispatch_async(_workQueue, ^{
      if ([self isDetached]) return;
      NSError *error = nil;
      BOOL loaded = [bridge loadModelWithAssetKey:assetPath error:&error];
      dispatch_async(dispatch_get_main_queue(), ^{
        if ([self isDetached]) return;
        if (loaded) result(@YES);
        else result([FlutterError errorWithCode:@"QURAN_LOAD_FAILED"
                                         message:error.localizedDescription ?: @"模型加载失败"
                                         details:nil]);
      });
    });
  } else if ([call.method isEqualToString:@"run"]) {
    NSDictionary *arguments = [call.arguments isKindOfClass:[NSDictionary class]] ? call.arguments : nil;
    FlutterStandardTypedData *typed = arguments[@"samples"];
    if (![typed isKindOfClass:[FlutterStandardTypedData class]] || typed.data.length == 0) {
      result([FlutterError errorWithCode:@"QURAN_BAD_INPUT" message:@"音频数据为空" details:nil]);
      return;
    }
    NSData *samples = typed.data;
    dispatch_async(_workQueue, ^{
      if ([self isDetached]) return;
      NSError *error = nil;
      NSDictionary *payload = nil;
      @try {
        payload = [bridge runWithSamples:(const float *)samples.bytes
                                   count:samples.length / sizeof(float)
                                   error:&error];
      } @catch (NSException *exception) {
        error = [NSError errorWithDomain:@"QuranOrtBridge"
                                    code:-3
                                userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: @"推理失败"}];
      }
      dispatch_async(dispatch_get_main_queue(), ^{
        if ([self isDetached]) return;
        if (payload != nil) result(payload);
        else result([FlutterError errorWithCode:@"QURAN_RUN_FAILED"
                                         message:error.localizedDescription ?: @"推理失败"
                                         details:nil]);
      });
    });
  } else if ([call.method isEqualToString:@"dispose"]) {
    dispatch_async(_workQueue, ^{
      if ([self isDetached]) return;
      [bridge dispose];
      dispatch_async(dispatch_get_main_queue(), ^{
        if (![self isDetached]) result(nil);
      });
    });
  } else {
    result(FlutterMethodNotImplemented);
  }
}

- (void)handleScreenCall:(FlutterMethodCall *)call result:(FlutterResult)result {
  if (![call.method isEqualToString:@"setKeepScreenOn"]) {
    result(FlutterMethodNotImplemented);
    return;
  }
  NSDictionary *arguments = [call.arguments isKindOfClass:[NSDictionary class]] ? call.arguments : nil;
  NSNumber *enabled = arguments[@"enabled"];
  if (![enabled isKindOfClass:[NSNumber class]]) {
    result([FlutterError errorWithCode:@"QURAN_BAD_INPUT" message:@"参数缺失" details:nil]);
    return;
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    if ([self isDetached]) return;
    if (!self->_managesIdleTimer) {
      self->_previousIdleTimerDisabled = UIApplication.sharedApplication.idleTimerDisabled;
      self->_managesIdleTimer = YES;
    }
    if (enabled.boolValue) {
      UIApplication.sharedApplication.idleTimerDisabled = YES;
    } else {
      [self restoreIdleTimer];
    }
    result(nil);
  });
}

- (void)detachFromEngineForRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  [self markDetached];
  [_ortChannel setMethodCallHandler:nil];
  [_screenChannel setMethodCallHandler:nil];
  _ortChannel = nil;
  _screenChannel = nil;

  // This queue also serializes run/load/dispose. Waiting here prevents an already
  // accepted run from racing a later native dispose, while no new handler can enqueue work.
  dispatch_sync(_workQueue, ^{
    [[QuranOrtBridge sharedInstance] dispose];
  });

  if ([NSThread isMainThread]) [self restoreIdleTimer];
  else dispatch_sync(dispatch_get_main_queue(), ^{ [self restoreIdleTimer]; });
}

- (BOOL)isDetached {
  @synchronized (self) {
    return _detached;
  }
}

- (void)markDetached {
  @synchronized (self) {
    _detached = YES;
  }
}

- (void)restoreIdleTimer {
  if (_managesIdleTimer) {
    UIApplication.sharedApplication.idleTimerDisabled = _previousIdleTimerDisabled;
    _managesIdleTimer = NO;
  }
}

@end
