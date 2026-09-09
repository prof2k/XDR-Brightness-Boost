import CoreGraphics
import Darwin
import Foundation

// Unsupported APIs. Read-only research boundary; never linked implicitly.
// Signatures cross-checked against Lunar at 8a21ffe302a00890d9f5d5101536cdd2a4631be8,
// Lunar/DDC/Lunar-Bridging-Header.h, and exports in the installed macOS 27 SDK.
final class PrivateDisplayReader {
    private let core = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY | RTLD_LOCAL)
    private let services = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY | RTLD_LOCAL)

    deinit {
        if let core { dlclose(core) }
        if let services { dlclose(services) }
    }

    func read(_ id: CGDirectDisplayID) -> [String: Any] {
        var result: [String: Any] = [:]
        typealias DoubleRead = @convention(c) (UInt32) -> Double
        typealias FloatRead = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
        typealias BoolRead = @convention(c) (UInt32, UnsafeMutablePointer<Bool>) -> Int32
        typealias InfoRead = @convention(c) (UInt32) -> Unmanaged<CFDictionary>?
        if let core {
            for name in ["CoreDisplay_Display_GetUserBrightness", "CoreDisplay_Display_GetLinearBrightness", "CoreDisplay_Display_GetDynamicLinearBrightness"] {
                if let symbol = dlsym(core, name) {
                    let value = unsafeBitCast(symbol, to: DoubleRead.self)(id)
                    if value.isFinite { result[name] = value }
                }
            }
            if let symbol = dlsym(core, "CoreDisplay_DisplayCreateInfoDictionary"),
               let info = unsafeBitCast(symbol, to: InfoRead.self)(id)?.takeRetainedValue() {
                result["filteredDisplayInfo"] = Self.filter(info as NSDictionary)
            }
        }
        if let services {
            for name in ["DisplayServicesGetBrightness", "DisplayServicesGetLinearBrightness"] {
                if let symbol = dlsym(services, name) {
                    var value = Float.nan
                    let status = unsafeBitCast(symbol, to: FloatRead.self)(id, &value)
                    result[name + "Status"] = status
                    if status == 0, value.isFinite { result[name] = value }
                }
            }
            if let symbol = dlsym(services, "DisplayServicesAmbientLightCompensationEnabled") {
                var enabled = false
                let status = unsafeBitCast(symbol, to: BoolRead.self)(id, &enabled)
                result["autoBrightnessReadStatus"] = status
                if status == 0 { result["autoBrightnessEnabled"] = enabled }
            }
        }
        return result
    }

    private static func filter(_ dictionary: NSDictionary) -> [String: Any] {
        var result: [String: Any] = [:]
        let relevant = ["brightness", "luminance", "gamma", "edr", "hdr", "preset", "backlight", "whitepoint", "whitelevel"]
        for (rawKey, value) in dictionary {
            guard let key = rawKey as? String else { continue }
            if let nested = value as? NSDictionary {
                let filtered = filter(nested)
                if !filtered.isEmpty { result[key] = filtered }
            } else if relevant.contains(where: key.lowercased().contains),
                      value is NSNumber || value is String {
                result[key] = value
            }
        }
        return result
    }
}
