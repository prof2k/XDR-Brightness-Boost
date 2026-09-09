import AppKit

extension NSScreen {
    var brightnessDisplayID: CGDirectDisplayID { (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0 }
}

// DisplayServices is unsupported. Keep this SDR-only adapter separate from the
// validated built-in XDR engine; never fall back to writing another display.
@MainActor
protocol DisplayBrightnessHardware: AnyObject {
    func read(_ id: UInt32) -> Double?
    func write(_ percentage: Double, to id: UInt32) -> Bool
}

@MainActor
final class DisplayBrightnessAccess: DisplayBrightnessHardware {
    private let ddc = ExternalDDC()
    private typealias Get = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias Set = @convention(c) (UInt32, Float) -> Int32
    private let get: Get?
    private let set: Set?
    init() {
        let library = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY | RTLD_LOCAL)
        get = library.flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map { unsafeBitCast($0, to: Get.self) }
        set = library.flatMap { dlsym($0, "DisplayServicesSetBrightness") }.map { unsafeBitCast($0, to: Set.self) }
    }
    func read(_ id: UInt32) -> Double? {
        guard id != 0, CGDisplayIsOnline(id) != 0, let get, set != nil else { return nil }
        var value: Float = 0
        guard get(id, &value) == 0, value.isFinite, (0...1).contains(value) else { return CGDisplayIsBuiltin(id) == 0 ? ddc.read(id) : nil }
        return Double(value) * 100
    }
    func write(_ percentage: Double, to id: UInt32) -> Bool {
        guard CGDisplayIsBuiltin(id) == 0, CGDisplayIsOnline(id) != 0, CGDisplayIsInMirrorSet(id) == 0,
              percentage.isFinite, (0...100).contains(percentage), let set else { return false }
        var current: Float = 0
        if let get, get(id, &current) == 0 { return set(id, Float(percentage / 100)) == 0 }
        return ddc.write(percentage, to: id)
    }
}



// A single serial queue keeps DDC transactions from overlapping. Targets use
// stable UUIDs, never a list index or an implicit/default display.
@MainActor
private final class ExternalDDC {
    private struct State { var value: Double; var maximum: Double; var uuid: String }
    private var states: [UInt32: State] = [:]
    private var probing: Set<UInt32> = []
    private var lastProbe: [UInt32: Date] = [:]
    private var pending: [UInt32: Double] = [:]
    private var writing: Set<UInt32> = []
    private let queue = DispatchQueue(label: "local.elijah.XDRBrightness.ddc", qos: .userInitiated)
    private static func uuid(_ id: UInt32) -> String? {
        guard let value = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, value) as String
    }
    nonisolated private static func run(_ uuid: String, _ operation: String, _ value: Int? = nil) -> String? {
        let process = Process()
        process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/xdr-ddc")
        process.arguments = ["display", "uuid=" + uuid, operation, "luminance"] + (value.map { [String($0)] } ?? [])
        let output = Pipe()
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { process.terminate(); return nil }
        guard process.terminationStatus == 0 else { return nil }
        return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func read(_ id: UInt32) -> Double? {
        guard CGDisplayIsOnline(id) != 0, CGDisplayIsBuiltin(id) == 0, let uuid = Self.uuid(id) else { return nil }
        if states[id]?.uuid != uuid { states[id] = nil }
        if !probing.contains(id), !writing.contains(id), Date().timeIntervalSince(lastProbe[id] ?? .distantPast) > 2 {
            probing.insert(id); lastProbe[id] = Date()
            queue.async { [weak self] in
                let maximum = Self.run(uuid, "max").flatMap(Double.init)
                let current = Self.run(uuid, "get").flatMap(Double.init)
                Task { @MainActor in
                    guard let self else { return }
                    self.probing.remove(id)
                    guard Self.uuid(id) == uuid, CGDisplayIsOnline(id) != 0, !self.writing.contains(id), self.pending[id] == nil else { return }
                    if let maximum, let current, maximum > 0, maximum <= 65535, current >= 0, current <= maximum {
                        self.states[id] = State(value: current / maximum * 100, maximum: maximum, uuid: uuid)
                    } else { self.states[id] = nil }
                }
            }
        }
        return states[id]?.value
    }
    func write(_ value: Double, to id: UInt32) -> Bool {
        guard let state = states[id], Self.uuid(id) == state.uuid else { return false }
        pending[id] = value
        states[id]?.value = value
        drain(id)
        return true
    }
    private func drain(_ id: UInt32) {
        guard !writing.contains(id), let value = pending.removeValue(forKey: id), let state = states[id] else { return }
        writing.insert(id)
        let raw = Int((value / 100 * state.maximum).rounded())
        queue.async { [weak self] in
            let result = Self.run(state.uuid, "set", raw)
            Task { @MainActor in
                guard let self else { return }
                self.writing.remove(id)
                if result == nil { self.states[id] = nil; self.pending[id] = nil }
                self.lastProbe[id] = .distantPast
                self.drain(id)
            }
        }
    }
}

@MainActor
final class ExternalBrightnessController {
    private let hardware: DisplayBrightnessHardware
    private var pendingHardware: [UInt32: Double] = [:]
    private var softwareValues: [UInt32: Double] = [:]
    var onSoftwareBrightness: ((UInt32, Double) -> Void)?
    private var factors: [UInt32: Double] = [:]
    private func applySoftware(_ value: Double, id: UInt32) {
        let factor = min(1, max(0, value / 100))
        guard factors[id] != factor else { return }
        factors[id] = factor
        onSoftwareBrightness?(id, factor)
    }
    init(hardware: DisplayBrightnessHardware? = nil) { self.hardware = hardware ?? DisplayBrightnessAccess() }

    func refreshPendingHardware() {
        for id in Array(pendingHardware.keys) { _ = read(id) }
    }

    func read(_ id: UInt32) -> Double? {
        guard screen(id) != nil else { pendingHardware[id] = nil; return nil }
        if let value = hardware.read(id) {
            if let requested = pendingHardware[id] {
                if hardware.write(requested, to: id) { pendingHardware[id] = nil }
                return requested
            }
            if factors[id] != nil { applySoftware(value, id: id) }
            return value
        }
        return softwareValues[id] ?? 100
    }

    func write(_ percentage: Double, to id: UInt32) -> Bool {
        guard percentage.isFinite, (0...100).contains(percentage), screen(id) != nil else { return false }
        // Keep the newest hardware request until discovery can service it.
        // Software feedback starts immediately; it never disables hardware.
        pendingHardware[id] = percentage
        if hardware.read(id) != nil, hardware.write(percentage, to: id) { pendingHardware[id] = nil }
        softwareValues[id] = percentage
        applySoftware(percentage, id: id)
        return true
    }

    func displaysChanged() {
        factors = factors.filter { screen($0.key) != nil }
        pendingHardware = pendingHardware.filter { screen($0.key) != nil }
        softwareValues = softwareValues.filter { screen($0.key) != nil }
    }

    func close() {
        for id in factors.keys { onSoftwareBrightness?(id, 1) }
        factors.removeAll()
        pendingHardware.removeAll()
    }

    private func screen(_ id: UInt32) -> NSScreen? {
        guard CGDisplayIsBuiltin(id) == 0, CGDisplayIsInMirrorSet(id) == 0 else { return nil }
        return NSScreen.screens.first { $0.brightnessDisplayID == id }
    }
}

/// App-owned, click-through black surface. It cannot become key or intercept
/// input; our popover and recovery HUD stay above it. Process exit
/// removes it automatically, including a crash or force quit.
@MainActor
private final class DisplayDimmer {
    private let panel: NSPanel
    private var timer: Timer?
    private var target = 0.0
    init(screen: NSScreen) {
        panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.backgroundColor = .black
        panel.isOpaque = true
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.alphaValue = 0
    }
    func resize(_ screen: NSScreen) {
        if panel.frame != screen.frame { panel.setFrame(screen.frame, display: true) }
    }
    func setOpacity(_ opacity: Double) {
        guard opacity != target else { return }
        target = opacity
        timer?.invalidate()
        let from = panel.alphaValue
        if opacity > 0 { panel.orderFrontRegardless() }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.alphaValue = opacity
            if opacity == 0 { panel.orderOut(nil) }
            return
        }
        let start = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let progress = min(1, (ProcessInfo.processInfo.systemUptime - start) / 0.08)
                self.panel.alphaValue = from + (opacity - from) * progress
                if progress >= 1 {
                    timer.invalidate()
                    if opacity == 0 { self.panel.orderOut(nil) }
                }
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func close() { timer?.invalidate(); panel.orderOut(nil) }
}
