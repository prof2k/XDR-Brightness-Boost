#import "NativePanel.h"
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/IOKitLib.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <sys/sysctl.h>

@interface NSObject (XDRPrivateABI)
+ (id)sharedMgr;
- (NSArray *)displays;
- (int)displayID;
- (id)activePreset;
- (NSArray *)presets;
- (NSUInteger)presetIndex;
- (NSDictionary *)presetDictionary;
- (BOOL)setActivePreset:(id)preset;
@end

static NSArray<NSString *> *metricKeys(void) {
    return @[@"BLNitsCap", @"IOMFBBrightnessLevel", @"IOMFBIndicatorNitsCap", @"limit_max_physical_brightness"];
}
static BOOL fail(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"XDRNativePanel" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
    return NO;
}
static id property(io_service_t service, NSString *key) {
    return CFBridgingRelease(IORegistryEntryCreateCFProperty(service, (__bridge CFStringRef)key, kCFAllocatorDefault, 0));
}
static BOOL abi(Class cls, SEL selector, const char *signature) {
    Method method = class_getInstanceMethod(cls, selector);
    return method && strcmp(method_getTypeEncoding(method), signature) == 0;
}

BOOL XDRSupportsExtendedRange(double potentialHeadroom) {
    return isfinite(potentialHeadroom) && potentialHeadroom > 1.0;
}

BOOL XDRPresetAllowsExtendedRange(NSDictionary<NSString *, id> *parameters) {
    // Missing private preset metadata must not disqualify a display which
    // advertises EDR through AppKit. Known SDR/reference restrictions still apply.
    if (!parameters) return YES;
    if ([parameters[@"PresetHostDisableUserAdjustments"] boolValue]) return NO;
    NSNumber *hdr = parameters[@"PresetMaxHDRLuminance"];
    NSNumber *sdr = parameters[@"PresetMaxSDRLuminance"];
    if (!hdr && !sdr) return YES;
    if (![hdr isKindOfClass:NSNumber.class] || ![sdr isKindOfClass:NSNumber.class]) return NO;
    return isfinite(hdr.doubleValue) && isfinite(sdr.doubleValue) && sdr.doubleValue > 0 && hdr.doubleValue > sdr.doubleValue;
}

@implementation XDRNativePanel {
    io_service_t _panel;
    CGDirectDisplayID _displayID;
    uint64_t _registryID;
    id _display;
    int (*_getBrightness)(uint32_t, float *);
    int (*_setBrightness)(uint32_t, float);
    int (*_getLinearBrightness)(uint32_t, float *);
    int (*_getAuto)(uint32_t, bool *);
    NSString *_identity;
    BOOL _supportsBoost;
    BOOL _presetAllowsBoost;
    NSNumber *_lastPresetIndex;
}

+ (nullable instancetype)openPanelAndReturnError:(NSError **)error { return [[self alloc] initWithError:error]; }

- (nullable instancetype)initWithError:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    @try {
        uint32_t count = 0; CGDirectDisplayID ids[16];
        if (CGGetOnlineDisplayList(16, ids, &count) != kCGErrorSuccess) { fail(error, @"Display enumeration failed."); return nil; }
        NSUInteger internalCount = 0;
        for (uint32_t i = 0; i < count; i++) if (CGDisplayIsBuiltin(ids[i])) { _displayID = ids[i]; internalCount++; }
        if (internalCount != 1) { fail(error, @"The built-in display is unavailable."); return nil; }
        io_iterator_t iterator = IO_OBJECT_NULL;
        // Registry metrics belong to the legacy driver engine. The current
        // color engine uses the display ID and does not require this service.
        IOServiceGetMatchingServices(MACH_PORT_NULL, IOServiceMatching("AppleCLCD2"), &iterator);
        NSUInteger matches = 0; io_service_t candidate;
        while (iterator && (candidate = IOIteratorNext(iterator))) {
            if ([property(candidate, @"IOMFBSupports2DBL") boolValue]) {
                matches++; if (_panel) IOObjectRelease(_panel); _panel = candidate;
            } else IOObjectRelease(candidate);
        }
        if (iterator) IOObjectRelease(iterator);
        if (matches != 1 || IORegistryEntryGetRegistryEntryID(_panel, &_registryID) != KERN_SUCCESS) {
            if (_panel) IOObjectRelease(_panel);
            _panel = IO_OBJECT_NULL;
            _registryID = 0;
        }
        // Preset metadata is optional for color control. Validate methods before
        // calling them, but do not reject a whole macOS version by its build ID.
        dlopen("/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel", RTLD_LAZY | RTLD_LOCAL);
        Class cls = NSClassFromString(@"MPDisplayMgr");
        Class displayClass = NSClassFromString(@"MPDisplay");
        if (abi(object_getClass(cls), @selector(sharedMgr), "@16@0:8") && abi(cls, @selector(displays), "@16@0:8") &&
            abi(displayClass, @selector(displayID), "i16@0:8") && abi(displayClass, @selector(activePreset), "@16@0:8") &&
            abi(NSClassFromString(@"MPDisplayPreset"), @selector(presetIndex), "Q16@0:8")) {
            for (id display in [[cls sharedMgr] displays]) if ((uint32_t)[display displayID] == _displayID) _display = display;
        }
        void *services = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY | RTLD_LOCAL);
        if (!services) { fail(error, @"Native brightness service unavailable."); return nil; }
        _getBrightness = dlsym(services, "DisplayServicesGetBrightness");
        _getLinearBrightness = dlsym(services, "DisplayServicesGetLinearBrightness");
        _setBrightness = dlsym(services, "DisplayServicesSetBrightness");
        _getAuto = dlsym(services, "DisplayServicesAmbientLightCompensationEnabled");
        if (!_getBrightness || !_setBrightness) { fail(error, @"Native brightness symbols unavailable."); return nil; }
        struct timeval boot = {0}; size_t size = sizeof(boot);
        if (sysctlbyname("kern.boottime", &boot, &size, NULL, 0)) { fail(error, @"Boot identity unavailable."); return nil; }
        if (_registryID) {
            _identity = [NSString stringWithFormat:@"%ld:%d:%llu", boot.tv_sec, _displayID, _registryID];
        } else {
            CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(_displayID);
            if (!uuid) { fail(error, @"Display identity unavailable."); return nil; }
            NSString *displayUUID = CFBridgingRelease(CFUUIDCreateString(kCFAllocatorDefault, uuid));
            CFRelease(uuid);
            _identity = [NSString stringWithFormat:@"%ld:%@", boot.tv_sec, displayUUID];
        }
        // Color control does not depend on driver cap/level values. The legacy
        // driver worker validates those separately before every transaction.
        if (![self readBrightnessState]) { fail(error, @"Initial native brightness readback failed."); return nil; }
    } @catch (NSException *exception) { fail(error, @"Native display discovery failed."); return nil; }
    return self;
}

- (void)dealloc { if (_panel) IOObjectRelease(_panel); }

- (nullable NSDictionary *)readState {
    @try {
        if (!CGDisplayIsOnline(_displayID) || !_panel || !_display || !_getAuto || !_getLinearBrightness) return nil;
        float brightness = NAN, linear = NAN; bool automatic = false;
        if (_getBrightness(_displayID, &brightness) || !isfinite(brightness) || _getAuto(_displayID, &automatic) || _getLinearBrightness(_displayID, &linear) || !isfinite(linear)) return nil;
        NSMutableDictionary *metrics = [NSMutableDictionary dictionary];
        for (NSString *key in metricKeys()) {
            NSNumber *value = property(_panel, key);
            if (![value isKindOfClass:NSNumber.class] || value.longLongValue < 0 || value.longLongValue > 1600LL * 65536) return nil;
            metrics[key] = value;
        }
        uint32_t capacity = CGDisplayGammaTableCapacity(_displayID), count = 0;
        if (!capacity || capacity > 16384) return nil;
        NSMutableData *gamma = [NSMutableData dataWithLength:capacity * 3 * sizeof(CGGammaValue)];
        float *samples = gamma.mutableBytes;
        if (CGGetDisplayTransferByTable(_displayID, capacity, samples, samples + capacity, samples + 2 * capacity, &count) != kCGErrorSuccess || count != capacity) return nil;
        BOOL neutral = YES;
        for (uint32_t i = 0; i < capacity; i++) {
            float expected = (float)i / (capacity - 1);
            for (int channel = 0; channel < 3; channel++) if (!isfinite(samples[channel * capacity + i]) || fabsf(samples[channel * capacity + i] - expected) > 0.002) neutral = NO;
        }
        uint32_t online = 0; CGGetOnlineDisplayList(0, NULL, &online);
        CGDisplayModeRef mode = CGDisplayCopyDisplayMode(_displayID);
        NSString *modeKey = mode ? [NSString stringWithFormat:@"%zu:%zu:%zu:%zu:%.2f", CGDisplayModeGetWidth(mode), CGDisplayModeGetHeight(mode), CGDisplayModeGetPixelWidth(mode), CGDisplayModeGetPixelHeight(mode), CGDisplayModeGetRefreshRate(mode)] : @"unavailable";
        if (mode) CGDisplayModeRelease(mode);
        return @{@"identity":_identity, @"preset":@([[_display activePreset] presetIndex]), @"brightness":@(brightness), @"linearBrightness":@(linear), @"autoBrightness":@(automatic), @"metrics":metrics, @"gamma": [gamma base64EncodedStringWithOptions:0], @"neutralGamma":@(neutral), @"singleDisplay":@((BOOL)(online == 1 && !CGDisplayIsInMirrorSet(_displayID))), @"awake":@((BOOL)(CGDisplayIsActive(_displayID) && !CGDisplayIsAsleep(_displayID))), @"mode":modeKey};
    } @catch (NSException *exception) { return nil; }
}

- (nullable NSDictionary *)readBrightnessState {
    @try {
        float brightness = NAN; bool automatic = false;
        if (!CGDisplayIsOnline(_displayID) || _getBrightness(_displayID, &brightness) || !isfinite(brightness)) return nil;
        for (NSScreen *screen in NSScreen.screens) {
            if ([screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue] == _displayID) {
                _supportsBoost = XDRSupportsExtendedRange(screen.maximumPotentialExtendedDynamicRangeColorComponentValue);
                break;
            }
        }
        id preset = [_display activePreset];
        NSNumber *index = preset ? @([preset presetIndex]) : @(-1);
        if (![_lastPresetIndex isEqual:index]) {
            NSDictionary *parameters = nil;
            if (preset && abi([preset class], @selector(presetDictionary), "@16@0:8")) parameters = [preset presetDictionary];
            _presetAllowsBoost = XDRPresetAllowsExtendedRange(parameters);
            _lastPresetIndex = index;
        }
        NSMutableDictionary *state = [@{@"identity": _identity, @"preset": index, @"brightness": @(brightness),
                                        @"displayID": @(_displayID), @"supportsBoost": @(_supportsBoost),
                                        @"presetAllowsBoost": @(_presetAllowsBoost)} mutableCopy];
        if (_getAuto && _getAuto(_displayID, &automatic) == 0) state[@"autoBrightness"] = @(automatic);
        return state;
    } @catch (NSException *exception) { return nil; }
}

- (BOOL)selectPreset:(NSUInteger)index error:(NSError **)error {
    @try {
        if (!_display || !abi([_display class], @selector(presets), "@16@0:8") || !abi([_display class], @selector(setActivePreset:), "B24@0:8@16")) return fail(error, @"Native preset selection unavailable.");
        if (index > 1) return fail(error, @"Only the two standard Apple presets may be selected.");
        for (id preset in [_display presets]) if ([preset presetIndex] == index) return [_display setActivePreset:preset] ?: fail(error, @"The native preset change was rejected.");
        return fail(error, @"The required Apple preset is unavailable.");
    } @catch (NSException *exception) { return fail(error, @"The native preset change failed."); }
}

- (BOOL)setBrightness:(float)value error:(NSError **)error {
    if (!isfinite(value) || value < 0 || value > 1) return fail(error, @"Invalid native brightness.");
    return _setBrightness(_displayID, value) == 0 ?: fail(error, @"The native brightness change failed.");
}

- (BOOL)writeMetrics:(NSDictionary<NSString *,NSNumber *> *)values error:(NSError **)error {
    if (!_panel || !values.count || !CGDisplayIsOnline(_displayID)) return fail(error, @"No writable internal panel.");
    for (NSString *key in values) {
        NSNumber *value = values[key];
        if (![metricKeys() containsObject:key] || ![value isKindOfClass:NSNumber.class] || !isfinite(value.doubleValue) || value.longLongValue < 0 || value.longLongValue > 1600LL * 65536) return fail(error, @"Invalid panel transaction.");
    }
    // The driver does not promise to apply every key in a multi-property call.
    // Use the individually verified setters, serialized within this worker.
    for (NSString *key in @[@"BLNitsCap", @"limit_max_physical_brightness", @"IOMFBIndicatorNitsCap", @"IOMFBBrightnessLevel"]) {
        if (!values[key]) continue;
        kern_return_t result = IORegistryEntrySetCFProperty(_panel, (__bridge CFStringRef)key, (__bridge CFTypeRef)values[key]);
        if (result != KERN_SUCCESS) return fail(error, [NSString stringWithFormat:@"The panel rejected %@ (0x%x).", key, result]);
    }
    return YES;
}
@end
