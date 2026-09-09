import AppKit
import Darwin

enum XDRFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(value) = self { return value }; return nil }
}

// Experimental only. Never writes driver caps or selects an SDR preset.
// The supervising script restores the serialized table even after a crash.
struct GammaSnapshot: Codable {
    let display: UInt32
    let identity: String
    let brightness: Float
    let red: [Float]
    let green: [Float]
    let blue: [Float]

    func apply(factor: Float = 1, tableSize: Int = 256) throws {
        func scaled(_ table: [Float]) -> [Float] {
            if factor == 1 { return table }
            return (0..<tableSize).map { index in
                let position = Double(index) * Double(table.count - 1) / Double(tableSize - 1)
                let lower = Int(position), upper = min(table.count - 1, lower + 1)
                let fraction = Float(position - Double(lower))
                return (table[lower] * (1 - fraction) + table[upper] * fraction) * factor
            }
        }
        let r = scaled(red), g = scaled(green), b = scaled(blue)
        guard CGSetDisplayTransferByTable(display, UInt32(r.count), r, g, b) == .success else {
            throw XDRFailure.message("Gamma write rejected")
        }
    }
}

@main struct PresetPreservingProbe {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let panel = try XDRNativePanel.open()
        let arguments = CommandLine.arguments
        if arguments[1] == "inspect" {
            let display = CGMainDisplayID(), capacity = CGDisplayGammaTableCapacity(CGMainDisplayID())
            var r = [Float](repeating: 0, count: Int(capacity)), g = r, b = r
            var count: UInt32 = 0
            guard CGGetDisplayTransferByTable(display, capacity, &r, &g, &b, &count) == .success, count > 0 else {
                throw XDRFailure.message("Gamma read failed")
            }
            let value: [String: Any] = ["midpoint": r[Int(count / 2)], "threeQuarter": r[Int(count * 3 / 4)], "endpoint": r[Int(count-1)]]
            print(String(data: try JSONSerialization.data(withJSONObject: value), encoding: .utf8)!)
            return
        }
        if arguments[1] == "xdr-preset" { try panel.selectPreset(0); return }
        let path = URL(fileURLWithPath: arguments[2])
        if arguments[1] == "restore" {
            let saved = try JSONDecoder().decode(GammaSnapshot.self, from: Data(contentsOf: path))
            guard panel.readState()?["identity"] as? String == saved.identity else {
                throw XDRFailure.message("Hardware session changed; refusing stale restoration")
            }
            try saved.apply()
            try panel.setBrightness(saved.brightness)
            return
        }
        guard let state = panel.readState(), state["preset"] as? Int == 0,
              let identity = state["identity"] as? String,
              let brightness = state["brightness"] as? Double,
              let screen = NSScreen.screens.first(where: {
                  let id = ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
                  return CGDisplayIsBuiltin(id) != 0
              }) else { throw XDRFailure.message("An active XDR preset is required") }
        let display = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value
        let capacity = CGDisplayGammaTableCapacity(display)
        guard capacity > 0 else { throw XDRFailure.message("Gamma table unavailable") }
        var r = [Float](repeating: 0, count: Int(capacity)), g = r, b = r
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(display, capacity, &r, &g, &b, &count) == .success, count > 0 else {
            throw XDRFailure.message("Gamma snapshot failed")
        }
        let saved = GammaSnapshot(display: display, identity: identity, brightness: Float(brightness),
                                  red: Array(r.prefix(Int(count))), green: Array(g.prefix(Int(count))), blue: Array(b.prefix(Int(count))))
        try JSONEncoder().encode(saved).write(to: path, options: .atomic)
        chmod(path.path, 0o600)
        defer { try? saved.apply(); try? panel.setBrightness(saved.brightness) }
        let anchor = EDRAnchor()
        try anchor.start()
        defer { anchor.stop() }
        let started = ProcessInfo.processInfo.systemUptime
        // Sample preset and gamma endpoints at 60Hz through repeated transitions.
        for target: Float in [1, 1.15, 1, 1.3, 1, 1.6, 1] {
            let tableSize = arguments.count > 3 && arguments[3] == "1024" ? 1024 : 256
            try saved.apply(factor: target, tableSize: tableSize)
            for _ in 0..<45 {
                RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60))
                guard let current = panel.readState() else {
                    throw XDRFailure.message("Native panel readback unavailable or outside its accepted bounds")
                }
                guard current["preset"] as? Int == 0 else {
                    throw XDRFailure.message("Preset changed during experiment")
                }
                var rr = r, gg = g, bb = b, samples: UInt32 = 0
                let status = CGGetDisplayTransferByTable(display, capacity, &rr, &gg, &bb, &samples)
                let event: [String: Any] = ["seconds": ProcessInfo.processInfo.systemUptime - started,
                    "factor": target, "preset": 0, "awake": current["awake"] ?? false,
                    "inputTableSize": tableSize,
                    "gammaStatus": status.rawValue, "gammaEndpoint": rr[Int(max(1, samples))-1],
                    "gammaMidpoint": rr[Int(samples / 2)],
                    "gammaThreeQuarter": rr[Int(samples * 3 / 4)],
                    "baselineMidpoint": saved.red[Int(count / 2)],
                    "headroom": screen.maximumExtendedDynamicRangeColorComponentValue]
                print(String(data: try JSONSerialization.data(withJSONObject: event), encoding: .utf8)!)
                fflush(stdout)
            }
        }
    }
}
