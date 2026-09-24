#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface QuranOrtBridge : NSObject
+ (instancetype)sharedInstance;
- (BOOL)loadModelWithAssetKey:(NSString *)assetKey error:(NSError **)error;
- (nullable NSDictionary<NSString *, id> *)runWithSamples:(const float *)samples
                                                    count:(NSUInteger)count
                                                    error:(NSError **)error;
- (void)dispose;
@end

NS_ASSUME_NONNULL_END
