#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

// The entire unsupported macOS interface is confined to NativePanel.m.
@interface XDRNativePanel : NSObject
- (instancetype)init NS_UNAVAILABLE;
+ (nullable instancetype)openPanelAndReturnError:(NSError **)error;
- (nullable instancetype)initWithError:(NSError **)error;
- (nullable NSDictionary<NSString *, id> *)readState;
- (nullable NSDictionary<NSString *, id> *)readBrightnessState;
- (BOOL)selectPreset:(NSUInteger)index error:(NSError **)error;
- (BOOL)setBrightness:(float)value error:(NSError **)error;
- (BOOL)writeMetrics:(NSDictionary<NSString *, NSNumber *> *)values error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
