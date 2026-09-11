#import <AppKit/AppKit.h>
#import "../Sources/NativePanel.h"
#include <math.h>

static void check(BOOL value, const char *message) {
    if (!value) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
}
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc > 1 && strcmp(argv[1], "--probe") == 0) {
            NSError *error = nil;
            XDRNativePanel *panel = [XDRNativePanel openPanelAndReturnError:&error];
            NSDictionary *state = [panel readBrightnessState];
            if (!state) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 2; }
            NSData *data = [NSJSONSerialization dataWithJSONObject:state options:NSJSONWritingPrettyPrinted error:nil];
            fwrite(data.bytes, 1, data.length, stdout); puts("");
            return 0;
        }
        check(!XDRSupportsExtendedRange(1), "SDR display must stay at 100 percent");
        check(!XDRSupportsExtendedRange(0), "Unavailable headroom must not enable boost");
        check(!XDRSupportsExtendedRange(NAN), "Invalid capability must not enable boost");
        check(!XDRSupportsExtendedRange(INFINITY), "Infinite capability must not enable boost");
        for (NSNumber *value in @[@1.25, @2, @3.2, @16, @32]) {
            check(XDRSupportsExtendedRange(value.doubleValue), "Any finite EDR capability above one is eligible, without a model/build/resolution list");
        }
        check(XDRPresetAllowsExtendedRange(nil), "Missing optional preset API must not block EDR-capable hardware");
        check(XDRPresetAllowsExtendedRange(@{}), "Unknown preset metadata falls back to display capability");
        check(XDRPresetAllowsExtendedRange(@{@"PresetMaxHDRLuminance": @1600, @"PresetMaxSDRLuminance": @500}), "HDR preset allows boost");
        check(XDRPresetAllowsExtendedRange(@{@"PresetMaxHDRLuminance": @2000, @"PresetMaxSDRLuminance": @1000}), "Future luminance values must not require a new allowlist");
        check(!XDRPresetAllowsExtendedRange(@{@"PresetMaxHDRLuminance": @500, @"PresetMaxSDRLuminance": @500}), "An explicitly SDR-limited preset cannot provide boost");
        check(!XDRPresetAllowsExtendedRange(@{@"PresetMaxHDRLuminance": @1600, @"PresetMaxSDRLuminance": @500, @"PresetHostDisableUserAdjustments": @YES}), "Honor fixed reference preset controls");
        check(!XDRPresetAllowsExtendedRange(@{@"PresetMaxHDRLuminance": @1600, @"PresetMaxSDRLuminance": @0}), "Reject invalid luminance ratios");
        check(!XDRPresetAllowsExtendedRange(@{@"PresetMaxHDRLuminance": @"invalid", @"PresetMaxSDRLuminance": @500}), "Reject malformed metadata");
        puts("PASS: 17 display capability and HDR/SDR preset scenarios");
    }
}
