#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>

// Lists method names/types only. Does not invoke private display methods.
int main(void) {
    @autoreleasepool {
        void *handle = dlopen("/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel", RTLD_LAZY | RTLD_LOCAL);
        if (!handle) { fprintf(stderr, "MonitorPanel unavailable\n"); return 2; }
        for (NSString *name in @[@"MPDisplayMgr", @"MPDisplay", @"MPDisplayPreset"]) {
            Class cls = NSClassFromString(name);
            if (!cls) continue;
            for (int kind = 0; kind < 2; kind++) {
                unsigned count = 0;
                Method *methods = class_copyMethodList(kind ? object_getClass(cls) : cls, &count);
                for (unsigned i = 0; i < count; i++) {
                    NSString *selector = NSStringFromSelector(method_getName(methods[i]));
                    NSString *lower = selector.lowercaseString;
                    if ([lower containsString:@"preset"] || [lower containsString:@"display"] ||
                        [lower containsString:@"shared"] || [lower containsString:@"brightness"] ||
                        [lower containsString:@"luminance"] || [lower containsString:@"nits"] ||
                        [lower isEqualToString:@"name"] || [lower isEqualToString:@"init"]) {
                        printf("%s %s %s %s\n", name.UTF8String, kind ? "+" : "-", selector.UTF8String, method_getTypeEncoding(methods[i]));
                    }
                }
                free(methods);
            }
        }
        dlclose(handle);
    }
    return 0;
}
