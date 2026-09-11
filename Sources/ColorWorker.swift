import AppKit
import Darwin

private struct ColorSession: Codable {
    let identity: String
    let display: UInt32
    let originalPreset: Int?
    let originalBrightness: Float
    let original: ColorCurve
    var expected: ColorCurve?
    var previous: ColorCurve?
    var expectedBrightness: Float?
}

@MainActor
final class ColorBrightnessWorker {
    private static let journal = BrightnessWorker.support.appendingPathComponent("color-recovery.json")
    private var panel: XDRNativePanel?
    private var nextPanelProbe = 0.0
    private var lastKnownSupportsBoost = false
    private var lastReportedNativeAvailable: Bool?
    private var session: ColorSession?
    private let anchor = ColorEDRAnchor()
    private let externalGamma = ExternalGamma()
    private var input = Data()
    private var active = false
    private var percentage = 100.0
    private var appliedPercentage = 100.0
    private var lastReportedPercentage: Double?
    private var revision = ControlRevision()
    private var requestID = 0
    private var heartbeat = ProcessInfo.processInfo.systemUptime
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var signals: [DispatchSourceSignal] = []
    private var lockFD: Int32 = -1
    private var keyboardRamp = false
    private var ramping = false
    private var pausedTarget: Double?
    private var pauseReasons = Set<String>()
    private var rampStarted: Double?

    func start(recoverOnly: Bool = false) {
        do {
            // Recover an older installed engine once before taking its lock.
            if FileManager.default.fileExists(atPath: BrightnessWorker.journal.path) {
                let recovery = Process()
                recovery.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
                recovery.arguments = ["--recover-native"]
                recovery.standardOutput = FileHandle.nullDevice
                try recovery.run(); recovery.waitUntilExit()
                guard recovery.terminationStatus == 0 else { throw XDRFailure.message("Previous display settings need recovery.") }
            }
            try FileManager.default.createDirectory(at: BrightnessWorker.support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            lockFD = open(BrightnessWorker.support.appendingPathComponent("control.lock").path, O_CREAT | O_RDWR, 0o600)
            guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw XDRFailure.message("Another brightness session is active.") }
            try externalGamma.recover()
            panel = try? XDRNativePanel.open()
            if FileManager.default.fileExists(atPath: Self.journal.path) {
                session = try JSONDecoder().decode(ColorSession.self, from: Data(contentsOf: Self.journal))
                guard session!.original.isValid, session!.expected?.isValid != false, session!.previous?.isValid != false else {
                    throw XDRFailure.message("Invalid recovery curve. Recovery has been retained.")
                }
                try restore()
            }
            if recoverOnly { send("off", "Recovery completed."); exit(0) }
            if let state = panel?.readBrightnessState(), let value = state["brightness"] as? Double { percentage = value * 100 }
            send("off", panel == nil ? "No native built-in brightness control. External displays remain available." : "Ready. Display preset stays unchanged.")
            FileHandle.standardInput.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil }
                Task { @MainActor in self?.receive(data) }
            }
            timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
            RunLoop.main.add(timer!, forMode: .common)
            for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
                observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        self?.pauseReasons.insert(name.rawValue)
                        self?.pauseForSleep()
                    }
                })
            }
            for (wake, sleep) in [(NSWorkspace.didWakeNotification, NSWorkspace.willSleepNotification),
                                  (NSWorkspace.screensDidWakeNotification, NSWorkspace.screensDidSleepNotification),
                                  (NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.sessionDidResignActiveNotification)] {
                observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: wake, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        self?.pauseReasons.remove(sleep.rawValue)
                        self?.heartbeat = ProcessInfo.processInfo.systemUptime
                    }
                })
            }
            observers.append(NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in if ProcessInfo.processInfo.thermalState != .nominal { self?.stop("The Mac is warm. Boost is off.", releaseSurface: true) } }
            })
            for number in [SIGTERM, SIGINT] {
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
                source.setEventHandler { [weak self] in
                    self?.stop("Stopped.", releaseSurface: true); exit(self?.session == nil ? 0 : 2)
                }
                source.resume(); signals.append(source)
            }
        } catch { send("error", error.localizedDescription); exit(2) }
    }

    private func curve(_ display: UInt32) throws -> ColorCurve {
        let capacity = CGDisplayGammaTableCapacity(display)
        guard (2...16384).contains(capacity) else { throw XDRFailure.message("Display color table is unavailable.") }
        var r = [Float](repeating: 0, count: Int(capacity)), g = r, b = r, count: UInt32 = 0
        guard CGGetDisplayTransferByTable(display, capacity, &r, &g, &b, &count) == .success, count >= 2 else {
            throw XDRFailure.message("Could not read the display color table.")
        }
        let value = ColorCurve(red: Array(r.prefix(Int(count))), green: Array(g.prefix(Int(count))), blue: Array(b.prefix(Int(count))))
        guard value.isValid else { throw XDRFailure.message("Unexpected display color values.") }
        return value
    }

    private func write(_ curve: ColorCurve, display: UInt32) throws {
        guard curve.isValid, CGSetDisplayTransferByTable(display, UInt32(curve.red.count), curve.red, curve.green, curve.blue) == .success else {
            throw XDRFailure.message("The display rejected its color table.")
        }
    }

    private func persist() throws {
        guard let session else { return }
        try JSONEncoder().encode(session).write(to: Self.journal, options: .atomic)
        guard chmod(Self.journal.path, 0o600) == 0 else { throw XDRFailure.message("Could not secure recovery data.") }
    }

    private func receive(_ data: Data) {
        if data.isEmpty { stop("Controller closed.", releaseSurface: true); exit(session == nil ? 0 : 2) }
        input.append(data)
        guard input.count < 65536 else { stop("Invalid input.", releaseSurface: true); exit(2) }
        while let newline = input.firstIndex(of: 10) {
            let line = input.prefix(upTo: newline); input.removeSubrange(...newline)
            guard let command = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let kind = command["command"] as? String else { continue }
            if kind == "heartbeat" { heartbeat = ProcessInfo.processInfo.systemUptime; continue }
            if let id = command["requestID"] as? Int { requestID = id }
            switch kind {
            case "dimExternal":
                if let display = command["displayID"] as? UInt32, let factor = command["factor"] as? Double,
                   let identity = command["displayUUID"] as? String {
                    do { try externalGamma.set(factor, display: display, identity: identity) }
                    catch { send("error", error.localizedDescription) }
                }
            case "enable":
                keyboardRamp = false
                if let value = command["percentage"] as? Double {
                    if value.isFinite, (0...160).contains(value) { enable(at: value) }
                } else { enable() }
            case "set": if let value = command["percentage"] as? Double { set(value, activate: command["activate"] as? Bool ?? false) }
            case "adjust":
                if let direction = command["direction"] as? Int, [-1, 1].contains(direction) {
                    let next = ControlPolicy.keyTarget(ramping ? percentage : (observedPercentage() ?? percentage), direction: direction, fine: command["fine"] as? Bool ?? false, supportsBoost: supportsBoost, boostEnabled: boostEnabled, allowBoostActivation: command["allowBoostActivation"] as? Bool ?? false)
                    set(next.percentage, activate: next.boostEnabled, keyboard: true)
                }
            case "disable": disableSmoothly()
            case "quit": stop("Brightness restored with a 35% minimum.", releaseSurface: true, minimumBrightness: 0.35); exit(session == nil ? 0 : 2)
            default: break
            }
        }
    }

    private func screen(_ display: UInt32) -> NSScreen? {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display }
    }

    private var boostEnabled = false
    private var supportsBoost: Bool { panel?.readBrightnessState()?["supportsBoost"] as? Bool ?? lastKnownSupportsBoost }


    private func enable(at requested: Double? = nil, immediately: Bool = false) {
        if active {
            boostEnabled = true
            if let requested { set(requested, activate: true) }
            return
        }
        do {
            guard supportsBoost else { throw XDRFailure.message("This display does not support XDR boost.") }
            guard session == nil else { throw XDRFailure.message("Recovery is pending. Quit and reopen to retry.") }
            guard ProcessInfo.processInfo.thermalState == .nominal else { throw XDRFailure.message("Wait for the Mac to cool before boosting.") }
            guard let state = panel?.readBrightnessState(), let id = state["displayID"] as? UInt32,
                  let identity = state["identity"] as? String, let brightness = state["brightness"] as? Double,
                  let screen = screen(id), CGDisplayIsActive(id) != 0, CGDisplayIsInMirrorSet(id) == 0 else {
                throw XDRFailure.message("An awake, unmirrored built-in display is required.")
            }
            guard state["presetAllowsBoost"] as? Bool != false else { throw XDRFailure.message("Select an HDR-capable display preset that allows brightness adjustments.") }
            guard state["autoBrightness"] as? Bool != true else { throw XDRFailure.message("Turn off automatic brightness to use manual control.") }
            let original = try curve(id)
            session = ColorSession(identity: identity, display: id, originalPreset: state["preset"] as? Int, originalBrightness: Float(brightness), original: original)
            try persist()
            try anchor.start(screen: screen)
            active = true
            boostEnabled = true
            percentage = requested ?? ControlPolicy.enabledPercentage(nativeBrightness: brightness)
            appliedPercentage = brightness * 100
            let token = revision.advance()
            if immediately {
                ramping = false
                try apply(percentage)
                send("active", "Brightness control is on.")
                return
            }
            ramping = true
            rampStarted = nil
            send("active", "Brightness control is on.")
            ramp(token: token, from: appliedPercentage, started: ProcessInfo.processInfo.systemUptime)
        } catch { stop(error.localizedDescription) }
    }

    private func ramp(token: Int, from: Double, started: Double) {
        guard revision.accepts(token), ramping else { return }
        do {
            // EDR headroom is advisory and can remain 1 while the anchor is
            // active. Validate actual color writes in apply(), rather than
            // timing out and undoing an explicit brightness request.
            do {
                let now = ProcessInfo.processInfo.systemUptime
                if rampStarted == nil { rampStarted = now }
                let progress = min(1, (now - rampStarted!) / (keyboardRamp ? 0.08 : 0.28))
                let value = keyboardRamp ? from + (percentage - from) * progress : ControlPolicy.rampValue(from: from, to: percentage, progress: progress)
                if session != nil { try apply(value) }
                else { try panel?.setBrightness(ColorPolicy.native(value)); appliedPercentage = value }
                if progress >= 1 {
                    try panel?.setBrightness(ColorPolicy.native(percentage))
                    ramping = false
                    if percentage <= 100 {
                        try restore(restoringBrightness: false)
                        active = false
                    }
                    send(active ? "active" : "off", "Brightness updated.")
                    return
                }
                send(percentage > 100 ? "active" : "off", "Brightness updated.")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [weak self] in self?.ramp(token: token, from: from, started: started) }
        } catch { stop(error.localizedDescription) }
    }

    private func set(_ value: Double, activate: Bool = false, keyboard: Bool = false) {
        if keyboard && ramping && value == percentage { return }
        keyboardRamp = keyboard
        guard panel != nil, value.isFinite, (0...(supportsBoost ? 160 : 100)).contains(value) else { return }
        if value > 100, activate, active { boostEnabled = true }
        if value > 100, !active {
            if activate { enable(at: value) }
            return
        }
        let from = ramping ? appliedPercentage : (observedPercentage() ?? appliedPercentage)
        percentage = value
        ramping = true
        rampStarted = nil
        let token = revision.advance()
        ramp(token: token, from: from, started: ProcessInfo.processInfo.systemUptime)
    }

    private func disableSmoothly() {
        pausedTarget = nil
        boostEnabled = false
        let current = observedPercentage() ?? appliedPercentage
        set(min(100, max(0, current)))
    }

    private func apply(_ value: Double) throws {
        guard let old = session, let state = panel?.readBrightnessState(), state["identity"] as? String == old.identity,
              state["presetAllowsBoost"] as? Bool != false,
              old.originalPreset == nil || state["preset"] as? Int == old.originalPreset else { throw XDRFailure.message("Display configuration changed. Brightness released.") }
        let factor = ColorPolicy.factor(value)
        // Headroom can transiently report 1 while a native scalar change is
        // in flight. The curve readback below is the acceptance check; do not
        // cancel explicit input merely because that advisory value changed.
        let target = old.original.scaled(by: factor)
        let scalar = ColorPolicy.native(value)
        session?.previous = old.expected; session?.expected = target; session?.expectedBrightness = scalar
        try persist()
        // Remove software gain before lowering hardware brightness.
        if value <= 100 { try write(target, display: old.display) }
        if abs((state["brightness"] as? Float ?? -1) - scalar) > 0.002 { try panel?.setBrightness(scalar) }
        if value > 100 { try write(target, display: old.display) }
        guard try curve(old.display).matches(target) else { throw XDRFailure.message("macOS changed the brightness curve. Original settings restored.") }
        appliedPercentage = value
    }

    private func restore(restoringBrightness: Bool = true) throws {
        guard let old = session else { return }
        guard let state = panel?.readBrightnessState() else { throw XDRFailure.message("Display unavailable. Recovery has been retained.") }
        if state["identity"] as? String == old.identity {
            let current = try curve(old.display)
            if [old.expected, old.previous].compactMap({ $0 }).contains(where: { current.matches($0) }) {
                let original = old.original.red.contains(where: { $0 > 1 }) || old.original.green.contains(where: { $0 > 1 }) || old.original.blue.contains(where: { $0 > 1 })
                    ? old.original.scaled(by: 1) : old.original
                try write(original, display: old.display)
                guard try curve(old.display).matches(old.original) else { throw XDRFailure.message("Color restoration needs attention. Recovery has been retained.") }
            }
            if restoringBrightness, let expected = old.expectedBrightness, let actual = state["brightness"] as? Float, abs(actual - expected) < 0.005 {
                try panel?.setBrightness(old.originalBrightness)
            }
        }
        try FileManager.default.removeItem(at: Self.journal)
        session = nil
    }

    private func stop(_ message: String, releaseSurface: Bool = false, minimumBrightness: Float? = nil, preservingIntent: Bool = false) {
        if !preservingIntent { pausedTarget = nil }
        _ = revision.advance(); active = false; boostEnabled = preservingIntent && pausedTarget != nil; ramping = false
        var externalRecoveryError: String?
        do { try externalGamma.restoreAll() }
        catch { externalRecoveryError = error.localizedDescription }
        do {
            try restore()
            if let minimumBrightness, let state = panel?.readBrightnessState(),
               let current = state["brightness"] as? Double, current < Double(minimumBrightness) {
                try panel?.setBrightness(minimumBrightness)
            }
            if releaseSurface { anchor.stop() }
            if let state = panel?.readBrightnessState(), let value = state["brightness"] as? Double { percentage = min(100, max(0, value * 100)) }
            send(externalRecoveryError == nil ? "off" : "error", externalRecoveryError ?? message)
        } catch { send("error", error.localizedDescription) }
    }

    private func pauseForSleep() {
        if pausedTarget != nil { return }
        if boostEnabled { pausedTarget = ramping ? percentage : (observedPercentage() ?? percentage) }
        stop("Display session paused.", releaseSurface: true, preservingIntent: true)
    }

    private func tick() {
        // A desktop Mac may have no internal panel, and a sleeping/clamshell
        // panel can return later. Keep the external controller alive meanwhile.
        let now = ProcessInfo.processInfo.systemUptime
        if panel == nil && now >= nextPanelProbe {
            nextPanelProbe = now + 2
            panel = try? XDRNativePanel.open()
            if panel != nil { send("off", "Native display control is available.") }
        }
        if pauseReasons.isEmpty && ProcessInfo.processInfo.systemUptime - heartbeat > 4 { stop("Controller disconnected.", releaseSurface: true); exit(session == nil ? 0 : 2) }
        if active, let session, CGDisplayIsAsleep(session.display) != 0 || CGDisplayIsActive(session.display) == 0 {
            pauseForSleep(); return
        }
        if let target = pausedTarget {
            guard pauseReasons.isEmpty,
                  let state = panel?.readBrightnessState(), let id = state["displayID"] as? UInt32,
                  CGDisplayIsAsleep(id) == 0, CGDisplayIsActive(id) != 0 else { return }
            do { try restore() } catch { return }
            pausedTarget = nil
            keyboardRamp = false
            enable(at: target)
            return
        }
        let native = panel?.readBrightnessState()
        if (native != nil) != lastReportedNativeAvailable || (native?["supportsBoost"] as? Bool ?? lastKnownSupportsBoost) != lastKnownSupportsBoost {
            send(active ? "active" : "off", "Display availability updated.")
        }
        guard !ramping, let current = observedPercentage() else { return }
        // Observe while off too. Readback never modifies the requested target
        // or writes back over another controller's brightness adjustment.
        if lastReportedPercentage.map({ abs($0 - current) > 0.01 }) ?? true {
            send(active ? "active" : "off", "Brightness updated.", observed: current)
        }
    }

    private func observedPercentage() -> Double? {
        guard let state = panel?.readBrightnessState(), let display = state["displayID"] as? UInt32,
              let native = state["brightness"] as? Double, let actual = try? curve(display) else { return nil }
        return ColorPolicy.observedPercentage(nativeBrightness: native, curve: actual)
    }

    private func send(_ state: String, _ message: String, observed: Double? = nil) {
        let current = observed ?? observedPercentage() ?? lastReportedPercentage ?? appliedPercentage
        // Settled output above the normal range enables the global control,
        // including brightness already present when this process starts.
        // Do not undo an explicit off command during its downward animation.
        let native = panel?.readBrightnessState()
        if let supported = native?["supportsBoost"] as? Bool { lastKnownSupportsBoost = supported }
        lastReportedNativeAvailable = native != nil
        let canBoost = lastKnownSupportsBoost
        if canBoost && pausedTarget == nil && !ramping && state != "error" && current > 100.01 { boostEnabled = true }
        lastReportedPercentage = current
        let payload: [String: Any] = ["state": state, "message": message, "percentage": current,
                                      "requestedPercentage": percentage, "requestID": requestID,
                                      "boostEnabled": boostEnabled && canBoost, "supportsBoost": canBoost, "nativeAvailable": native != nil, "ramping": ramping, "prepared": false, "engine": "color-table-xdr-preset"]
        if var data = try? JSONSerialization.data(withJSONObject: payload) {
            data.append(10); _ = data.withUnsafeBytes { Darwin.write(STDOUT_FILENO, $0.baseAddress, $0.count) }
        }
    }
}
