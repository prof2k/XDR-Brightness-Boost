import AppKit
import CoreGraphics
import CryptoKit
import Foundation

// Read-only. Display IDs are valid for this session only. This tool does not
// create windows, enable EDR, change display modes, or write gamma/brightness.
@main
struct DisplayProbe {
    @MainActor
    static func main() throws {
        var count: UInt32 = 0
        let status = CGGetOnlineDisplayList(0, nil, &count)
        guard status == .success, count > 0 else {
            FileHandle.standardError.write(Data("No displays available to this process (CGError \(status.rawValue)).\n".utf8))
            exit(2)
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        let listStatus = CGGetOnlineDisplayList(count, &ids, &count)
        guard listStatus == .success else {
            FileHandle.standardError.write(Data("Display enumeration failed: \(listStatus.rawValue).\n".utf8))
            exit(2)
        }
        let screens = NSScreen.screens
        let privateReader = CommandLine.arguments.contains("--native") ? PrivateDisplayReader() : nil
        let displays: [[String: Any]] = ids.prefix(Int(count)).map { id in
            let screen = screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
            }
            let mode = CGDisplayCopyDisplayMode(id)
            var result: [String: Any] = [
                "sessionDisplayID": id,
                "builtIn": CGDisplayIsBuiltin(id) != 0,
                "main": CGDisplayIsMain(id) != 0,
                "active": CGDisplayIsActive(id) != 0,
                "asleep": CGDisplayIsAsleep(id) != 0,
                "inMirrorSet": CGDisplayIsInMirrorSet(id) != 0,
                "mirrorsSessionDisplayID": CGDisplayMirrorsDisplay(id),
            ]
            if let mode {
                result["modeLogicalSize"] = [mode.width, mode.height]
                result["modePixelSize"] = [mode.pixelWidth, mode.pixelHeight]
                result["modeRefreshHz"] = mode.refreshRate
            }
            if let screen {
                result["name"] = screen.localizedName
                result["backingScale"] = screen.backingScaleFactor
                result["currentEDRHeadroom"] = screen.maximumExtendedDynamicRangeColorComponentValue
                result["potentialEDRHeadroom"] = screen.maximumPotentialExtendedDynamicRangeColorComponentValue
                result["referenceEDRHeadroom"] = screen.maximumReferenceExtendedDynamicRangeColorComponentValue
                result["maximumFramesPerSecond"] = screen.maximumFramesPerSecond
                result["colorSpace"] = screen.colorSpace?.localizedName
            }
            if let privateReader { result["unsupportedReadOnlyAPI"] = privateReader.read(id) }
            let capacity = CGDisplayGammaTableCapacity(id)
            if capacity > 0, capacity <= 16384 {
                var red = [CGGammaValue](repeating: 0, count: Int(capacity))
                var green = red
                var blue = red
                var samples: UInt32 = 0
                let gammaStatus = CGGetDisplayTransferByTable(id, capacity, &red, &green, &blue, &samples)
                if gammaStatus == .success, samples > 0, samples <= capacity {
                    let count = Int(samples)
                    let values = Array(red.prefix(count)) + Array(green.prefix(count)) + Array(blue.prefix(count))
                    let hash = values.withUnsafeBytes { SHA256.hash(data: $0) }.map { String(format: "%02x", $0) }.joined()
                    result["gammaReadback"] = [
                        "sampleCount": count,
                        "lastRGB": [red[count - 1], green[count - 1], blue[count - 1]],
                        "sha256": hash,
                    ]
                }
            }
            return result
        }
        let report: [String: Any] = [
            "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
            "displays": displays,
            "notes": [
                "EDR headroom is a ratio, not measured panel luminance in nits.",
                "Mode pixel dimensions describe the render buffer, not necessarily the physical panel.",
                "A non-built-in display is not by itself evidence of a virtual display.",
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data)
        print()
    }
}
