import Foundation
import CoreGraphics

// Read-only, bounded trace for observing asynchronous native transitions.
@main
struct WatchPanel {
    static func main() throws {
        let panel = try XDRNativePanel.open()
        let duration = min(30, max(1, Double(CommandLine.arguments.dropFirst().first ?? "10") ?? 10))
        let deadline = ProcessInfo.processInfo.systemUptime + duration
        var last = ""
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let state = panel.readState() {
                let keys = ["preset", "brightness", "linearBrightness", "metrics", "awake", "mode"]
                var compact = state.filter { keys.contains($0.key) }
                let data = try JSONSerialization.data(withJSONObject: compact, options: .sortedKeys)
                let fingerprint = String(decoding: data, as: UTF8.self)
                if fingerprint != last {
                    compact["time"] = Date().timeIntervalSince1970
                    let line = try JSONSerialization.data(withJSONObject: compact, options: .sortedKeys)
                    FileHandle.standardOutput.write(line + Data([10]))
                    last = fingerprint
                }
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
    }
}
