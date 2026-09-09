#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>

// Unsupported MonitorPanel selectors. Their signatures were inspected using
// DisplayRuntimeProbe on macOS 27.0 (26A5416b). These declarations add no methods.
@interface NSObject (XDRPresetResearch)
+ (id)sharedMgr;
- (NSArray *)displays;
- (int)displayID;
- (NSString *)displayName;
- (id)activePreset;
- (NSArray *)presets;
- (NSUInteger)presetIndex;
- (NSString *)presetName;
- (NSDictionary *)presetDictionary;
@end

static NSDictionary *presetInfo(id preset) {
    if (!preset) return @{};
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    if ([preset respondsToSelector:@selector(presetIndex)]) result[@"index"] = @([preset presetIndex]);
    if ([preset respondsToSelector:@selector(presetName)]) result[@"name"] = [preset presetName] ?: @"";
    if ([preset respondsToSelector:@selector(presetDictionary)]) {
        NSDictionary *dictionary = [preset presetDictionary];
        NSMutableDictionary *parameters = [NSMutableDictionary dictionary];
        for (NSString *key in dictionary) {
            NSString *lower = key.lowercaseString;
            if ([lower containsString:@"luminance"] || [lower containsString:@"brightness"] ||
                [lower containsString:@"gamma"] || [lower containsString:@"hdr"] ||
                [lower containsString:@"reference"] || [lower containsString:@"disable"] ||
                [lower containsString:@"valid"]) {
                id value = dictionary[key];
                if ([value isKindOfClass:NSNumber.class] || [value isKindOfClass:NSString.class]) parameters[key] = value;
            }
        }
        result[@"parameters"] = parameters;
    }
    return result;
}

int main(void) {
    @autoreleasepool {
        @try {
            void *handle = dlopen("/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel", RTLD_LAZY | RTLD_LOCAL);
            Class managerClass = NSClassFromString(@"MPDisplayMgr");
            if (!handle || ![managerClass respondsToSelector:@selector(sharedMgr)]) return 2;
            id manager = [managerClass sharedMgr];
            if (![manager respondsToSelector:@selector(displays)]) return 2;
            NSMutableArray *result = [NSMutableArray array];
            for (id display in [manager displays]) {
                if (![display respondsToSelector:@selector(activePreset)] || ![display respondsToSelector:@selector(presets)]) continue;
                NSMutableArray *presets = [NSMutableArray array];
                for (id preset in [display presets]) [presets addObject:presetInfo(preset)];
                [result addObject:@{
                    @"sessionDisplayID": @([display displayID]),
                    @"name": [display displayName] ?: @"",
                    @"activePreset": presetInfo([display activePreset]),
                    @"presets": presets,
                }];
            }
            NSError *error;
            NSData *data = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:&error];
            if (!data) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 2; }
            fwrite(data.bytes, 1, data.length, stdout);
            puts("");
            // Leave the framework loaded until process exit: its singleton may
            // own asynchronous notifications and should not outlive its code.
        } @catch (NSException *exception) {
            fprintf(stderr, "Preset inspection failed: %s\n", exception.name.UTF8String);
            return 2;
        }
    }
    return 0;
}
