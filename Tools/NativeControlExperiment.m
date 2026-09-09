#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/IOKitLib.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <sys/sysctl.h>

// Research only. Private selectors and the driver key are not Apple API contracts.
@interface NSObject (XDRNativeExperiment)
+ (id)sharedMgr;
- (NSArray *)displays;
- (int)displayID;
- (id)activePreset;
- (NSArray *)presets;
- (NSUInteger)presetIndex;
- (BOOL)setActivePreset:(id)preset;
@end

static id readProperty(io_service_t service, NSString *key) {
    return CFBridgingRelease(IORegistryEntryCreateCFProperty(service, (__bridge CFStringRef)key, kCFAllocatorDefault, 0));
}
static void require(BOOL condition, NSString *message) {
    if (!condition) @throw [NSException exceptionWithName:@"XDRExperiment" reason:message userInfo:nil];
}
static void emit(NSDictionary *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:nil];
    fwrite(data.bytes, 1, data.length, stdout); puts(""); fflush(stdout);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        io_service_t panel = IO_OBJECT_NULL;
        @try {
            char model[128] = {0}; size_t size = sizeof(model);
            require(sysctlbyname("hw.model", model, &size, NULL, 0) == 0 && strcmp(model, "MacBookPro18,3") == 0, @"Unvalidated hardware model");
            require(NSProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27, @"Unvalidated OS version");
            uint32_t count = 0; CGDirectDisplayID ids[8];
            require(CGGetOnlineDisplayList(8, ids, &count) == kCGErrorSuccess && count == 1 && CGDisplayIsBuiltin(ids[0]) && !CGDisplayIsInMirrorSet(ids[0]), @"Exactly one unmirrored built-in display is required");
            io_iterator_t iterator = IO_OBJECT_NULL;
            require(IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleCLCD2"), &iterator) == KERN_SUCCESS, @"Panel services unavailable");
            io_service_t candidate; NSUInteger matches = 0;
            while ((candidate = IOIteratorNext(iterator))) {
                if ([readProperty(candidate, @"IOMFBSupports2DBL") boolValue] && [readProperty(candidate, @"DisplayWidth") intValue] == 3024 && [readProperty(candidate, @"DisplayHeight") intValue] == 1964) {
                    matches++; if (panel) IOObjectRelease(panel); panel = candidate;
                } else IOObjectRelease(candidate);
            }
            IOObjectRelease(iterator);
            require(matches == 1, @"Internal panel identification is ambiguous");
            uint64_t registryID = 0; IORegistryEntryGetRegistryEntryID(panel, &registryID);
            require(dlopen("/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel", RTLD_LAZY | RTLD_LOCAL) != NULL, @"MonitorPanel unavailable");
            Class managerClass = NSClassFromString(@"MPDisplayMgr");
            require([managerClass respondsToSelector:@selector(sharedMgr)], @"Preset manager unavailable");
            id display = nil;
            for (id candidateDisplay in [[managerClass sharedMgr] displays]) if ((uint32_t)[candidateDisplay displayID] == ids[0]) display = candidateDisplay;
            require(display != nil, @"No matching native display");
            Method setter = class_getInstanceMethod([display class], @selector(setActivePreset:));
            require(setter && strcmp(method_getTypeEncoding(setter), "B24@0:8@16") == 0, @"Preset setter ABI changed");
            void *services = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY | RTLD_LOCAL);
            int (*getBrightness)(uint32_t, float *) = dlsym(services, "DisplayServicesGetBrightness");
            int (*setBrightness)(uint32_t, float) = dlsym(services, "DisplayServicesSetBrightness");
            int (*getAuto)(uint32_t, bool *) = dlsym(services, "DisplayServicesAmbientLightCompensationEnabled");
            require(getBrightness && setBrightness && getAuto, @"Native brightness ABI unavailable");
            float brightness = NAN; bool automatic = false;
            require(getBrightness(ids[0], &brightness) == 0 && isfinite(brightness) && getAuto(ids[0], &automatic) == 0, @"Could not read brightness state");
            NSString *command = argc > 1 ? @(argv[1]) : @"read";
            if ([command isEqualToString:@"prepare"]) {
                require(argc == 3, @"prepare requires a recovery snapshot path");
                require(!automatic, @"Turn automatic brightness off before this experiment");
                require([[display activePreset] presetIndex] == 0 || [[display activePreset] presetIndex] == 1, @"A calibrated reference mode is active");
                NSDictionary *snapshot = @{@"registryID": @(registryID), @"displayID": @(ids[0]), @"presetIndex": @([[display activePreset] presetIndex]), @"cap": readProperty(panel, @"IOMFBIndicatorNitsCap"), @"physicalCap": readProperty(panel, @"limit_max_physical_brightness"), @"level": readProperty(panel, @"IOMFBBrightnessLevel"), @"backlightCap": readProperty(panel, @"BLNitsCap"), @"brightness": @(brightness)};
                NSData *data = [NSJSONSerialization dataWithJSONObject:snapshot options:0 error:nil];
                require([data writeToFile:@(argv[2]) options:NSDataWritingAtomic error:nil], @"Could not persist recovery snapshot");
                id target = nil;
                for (id preset in [display presets]) if ([preset presetIndex] == 1) target = preset;
                require(target && [display setActivePreset:target], @"Could not select SDR preset");
                require(setBrightness(ids[0], 1.0) == 0, @"Could not set native brightness");
            } else if ([command isEqualToString:@"set"]) {
                require(argc == 3 && !automatic && [[display activePreset] presetIndex] == 1, @"Incompatible panel state");
                double nits = [@(argv[2]) doubleValue];
                require(isfinite(nits) && nits >= 100 && nits <= 1000, @"Research target must be between 100 and 1000 nits");
                NSNumber *cap = @((int64_t)llround(nits * 65536));
                kern_return_t backlightStatus = IORegistryEntrySetCFProperty(panel, CFSTR("BLNitsCap"), (__bridge CFTypeRef)cap);
                require(backlightStatus == KERN_SUCCESS, [NSString stringWithFormat:@"Driver rejected backlight cap write: 0x%x", backlightStatus]);
                kern_return_t physicalStatus = IORegistryEntrySetCFProperty(panel, CFSTR("limit_max_physical_brightness"), (__bridge CFTypeRef)cap);
                require(physicalStatus == KERN_SUCCESS, [NSString stringWithFormat:@"Driver rejected physical cap write: 0x%x", physicalStatus]);
                kern_return_t status = IORegistryEntrySetCFProperty(panel, CFSTR("IOMFBIndicatorNitsCap"), (__bridge CFTypeRef)cap);
                require(status == KERN_SUCCESS, [NSString stringWithFormat:@"Driver rejected write: 0x%x", status]);
                kern_return_t levelStatus = IORegistryEntrySetCFProperty(panel, CFSTR("IOMFBBrightnessLevel"), (__bridge CFTypeRef)cap);
                require(levelStatus == KERN_SUCCESS, [NSString stringWithFormat:@"Driver rejected level write: 0x%x", levelStatus]);
            } else if ([command isEqualToString:@"restore"]) {
                require(argc == 3, @"restore requires the original snapshot path");
                NSData *data = [NSData dataWithContentsOfFile:@(argv[2])];
                NSDictionary *original = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
                require(original && [original[@"registryID"] unsignedLongLongValue] == registryID && [original[@"displayID"] unsignedIntValue] == ids[0], @"Recovery snapshot does not match this display session");
                int64_t cap = [original[@"cap"] longLongValue];
                int64_t physicalCap = [original[@"physicalCap"] longLongValue];
                int64_t level = [original[@"level"] longLongValue];
                int64_t backlightCap = [original[@"backlightCap"] longLongValue];
                require(cap > 0 && cap <= 1600LL * 65536 && physicalCap > 0 && physicalCap <= 1600LL * 65536 && level >= 0 && level <= 1600LL * 65536 && backlightCap > 0 && backlightCap <= 1600LL * 65536, @"Invalid original cap");
                kern_return_t backlightStatus = IORegistryEntrySetCFProperty(panel, CFSTR("BLNitsCap"), (__bridge CFTypeRef)@(backlightCap));
                kern_return_t capStatus = KERN_SUCCESS;
                if ([readProperty(panel, @"IOMFBIndicatorNitsCap") longLongValue] != cap) capStatus = IORegistryEntrySetCFProperty(panel, CFSTR("IOMFBIndicatorNitsCap"), (__bridge CFTypeRef)@(cap));
                kern_return_t physicalStatus = KERN_SUCCESS;
                if ([readProperty(panel, @"limit_max_physical_brightness") longLongValue] != physicalCap) physicalStatus = IORegistryEntrySetCFProperty(panel, CFSTR("limit_max_physical_brightness"), (__bridge CFTypeRef)@(physicalCap));
                kern_return_t levelStatus = IORegistryEntrySetCFProperty(panel, CFSTR("IOMFBBrightnessLevel"), (__bridge CFTypeRef)@(level));
                id target = nil;
                for (id preset in [display presets]) if ([preset presetIndex] == [original[@"presetIndex"] unsignedIntegerValue]) target = preset;
                BOOL presetRestored = target && [display setActivePreset:target];
                int brightnessStatus = setBrightness(ids[0], [original[@"brightness"] floatValue]);
                require(backlightStatus == KERN_SUCCESS && capStatus == KERN_SUCCESS && physicalStatus == KERN_SUCCESS && levelStatus == KERN_SUCCESS && presetRestored && brightnessStatus == 0, @"One or more original settings could not be restored");
            } else require([command isEqualToString:@"read"], @"Unknown command");
            emit(@{@"registryID": @(registryID), @"presetIndex": @([[display activePreset] presetIndex]), @"IOMFBIndicatorNitsCap": readProperty(panel, @"IOMFBIndicatorNitsCap") ?: @0, @"IOMFBBrightnessLevel": readProperty(panel, @"IOMFBBrightnessLevel") ?: @0, @"BLNitsCap": readProperty(panel, @"BLNitsCap") ?: @0});
        } @catch (NSException *exception) {
            fprintf(stderr, "%s\n", exception.reason.UTF8String);
            if (panel) IOObjectRelease(panel);
            return 2;
        }
        if (panel) IOObjectRelease(panel);
        return 0;
    }
}
