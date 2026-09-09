import AppKit
import Darwin

enum XDRFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

@MainActor
final class BrightnessWorker {
    static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("XDRBrightness", isDirectory: true)
    static let journal = support.appendingPathComponent("recovery.json")
    private var panel: XDRNativePanel!
    private var record: RecoveryRecord?
    private var revision = ControlRevision()
    private var timer: Timer?
    private var input = Data()
    private var observations: [NSObjectProtocol] = []
    private var lastHeartbeat = ProcessInfo.processInfo.systemUptime
    private var targetNits = 650.0
    private var active = false
    private var settlingUntil = 0.0
    private var isRamping = false
    private var lastAppliedNits = 0.0
    private var lastNativeBrightness = 0.999
    private var nativeHandoffUntil = 0.0
    private var lockFD: Int32 = -1
    private var signals: [DispatchSourceSignal] = []
    private var activationStart = 0.0
    private var activationTiming: [String: Double] = [:]
    private var edrAnchor: EDRAnchor!
    private var requestID = 0

    func start(recoverOnly: Bool = false) {
        do {
            try FileManager.default.createDirectory(at: Self.support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            lockFD = open(Self.support.appendingPathComponent("control.lock").path, O_CREAT | O_RDWR, 0o600)
            guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw XDRFailure.message("Another XDR Brightness session already owns the panel.") }
            panel = try XDRNativePanel.open()
            if FileManager.default.fileExists(atPath: Self.journal.path) {
                record = try JSONDecoder().decode(RecoveryRecord.self, from: Data(contentsOf: Self.journal))
                try restore()
            }
            if recoverOnly { send("off", "Recovery completed."); exit(0) }
            edrAnchor = EDRAnchor()
            try edrAnchor.prepare()
            let state = try read()
            send("off", ControlPolicy.activationIssue(state) ?? "Ready.", percentage: state.brightness * 100)
            FileHandle.standardInput.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil }
                Task { @MainActor in self?.received(data) }
            }
            let workspace = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
                observations.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.stop("Display session paused. Boost is off.") }
                })
            }
            observations.append(NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    if ProcessInfo.processInfo.thermalState != .nominal { self?.stop("The Mac is warm. Boost is off.") }
                }
            })
            timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            RunLoop.main.add(timer!, forMode: .common)
            for number in [SIGTERM, SIGINT] {
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
                source.setEventHandler { [weak self] in
                    self?.stop("Controller stopped. Original settings restored.")
                    exit(self?.record == nil ? 0 : 2)
                }
                source.resume(); signals.append(source)
            }
        } catch { send("error", error.localizedDescription); exit(2) }
    }

    private func read() throws -> PanelState {
        guard let value = panel.readState() else { throw XDRFailure.message("The internal panel is temporarily unavailable.") }
        do { return try JSONDecoder().decode(PanelState.self, from: JSONSerialization.data(withJSONObject: value)) }
        catch { throw XDRFailure.message("Native readback format changed: \(error)") }
    }

    private func persist(_ replacement: RecoveryRecord? = nil) throws {
        guard let record = replacement ?? record else { return }
        try JSONEncoder().encode(record).write(to: Self.journal, options: .atomic)
        guard chmod(Self.journal.path, 0o600) == 0 else { throw XDRFailure.message("Could not secure the recovery record.") }
    }

    private func received(_ data: Data) {
        if data.isEmpty { stop("Controller closed. Original settings restored."); exit(record == nil ? 0 : 2) }
        input.append(data)
        guard input.count < 65536 else { stop("Invalid controller input."); exit(2) }
        while let newline = input.firstIndex(of: 10) {
            let line = input.prefix(upTo: newline)
            input.removeSubrange(...newline)
            guard let command = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let kind = command["command"] as? String else { continue }
            if ["enable", "set", "adjust", "disable", "quit"].contains(kind), let id = command["requestID"] as? Int { requestID = id }
            switch kind {
            case "heartbeat": lastHeartbeat = ProcessInfo.processInfo.systemUptime
            case "enable": enable(command["nits"] as? Double)
            case "set":
                let nits = (command["percentage"] as? Double).flatMap(ControlPolicy.nits(forPercentage:)) ?? command["nits"] as? Double ?? .nan
                setTarget(nits)
            case "adjust":
                guard active, let direction = command["direction"] as? Int, [-1, 1].contains(direction) else { continue }
                let percentage = ControlPolicy.adjustedPercentage(ControlPolicy.percentage(forNits: targetNits), direction: direction, fine: command["fine"] as? Bool ?? false)
                if let nits = ControlPolicy.nits(forPercentage: percentage) { setTarget(nits) }
            case "disable": stop("Boost is off.", keepingPrepared: true)
            case "quit": stop("Original settings restored."); exit(record == nil ? 0 : 2)
            default: break
            }
        }
    }

    private func enable(_ requested: Double?) {
        guard !active else { return }
        guard record == nil || record?.isPrepared == true else {
            send("error", "Display recovery is pending. Quit and reopen the app to retry."); return
        }
        activationStart = ProcessInfo.processInfo.systemUptime
        activationTiming = [:]
        do {
            guard ProcessInfo.processInfo.thermalState == .nominal else { throw XDRFailure.message("Wait for the Mac to cool before enabling extended brightness.") }
            let original = try read()
            markActivation("snapshot")
            if let issue = ControlPolicy.activationIssue(original) { throw XDRFailure.message(issue) }
            let percentage = ControlPolicy.enabledPercentage(nativeBrightness: original.brightness)
            guard let nits = requested ?? ControlPolicy.nits(forPercentage: percentage), ControlPolicy.target(nits) != nil else { return }
            record = ControlPolicy.activationRecord(original: original, prepared: record)
            try persist()
            markActivation("recoverySaved")
            targetNits = nits
            send("preparing", "Taking control of brightness…")
            // Select SDR before presenting EDR, so an intermediate HDR ramp is
            // not started and then abruptly cancelled by the preset switch.
            if original.preset != 1 { try panel.selectPreset(1) }
            markActivation("presetSelected")
            try edrAnchor.start()
            markActivation("surfacePresented")
            try acquireNativeBrightness(from: original.brightness)
            markActivation("nativeBrightnessSet")
            lastNativeBrightness = 0.999
            // Begin at the previous SDR light level, not at a hard-coded boost.
            try apply(original.standardNits)
            markActivation("initialLevelApplied")
            active = true
            beginRamp(to: nits, duration: 0.28)
        } catch { stop(error.localizedDescription) }
    }

    private func markActivation(_ stage: String) {
        activationTiming[stage] = (ProcessInfo.processInfo.systemUptime - activationStart) * 1000
    }

    private func beginRamp(to nits: Double, duration: Double) {
        let token = revision.advance()
        let start = ProcessInfo.processInfo.systemUptime
        let initial = lastAppliedNits
        targetNits = nits
        isRamping = true
        send("active", "Brightness control is on.", reported: initial)
        rampFrame(token: token, from: initial, to: nits, start: start, duration: duration)
    }

    private func rampFrame(token: Int, from: Double, to: Double, start: Double, duration: Double) {
        guard active, revision.accepts(token), record != nil else { return }
        do {
            let progress = min(1, (ProcessInfo.processInfo.systemUptime - start) / duration)
            try apply(ControlPolicy.rampValue(from: from, to: to, progress: progress))
            if progress >= 1 {
                isRamping = false
                let state = try read()
                markActivation("targetApplied")
                send("active", "Brightness control is on.", reported: state.reportedNits)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [weak self] in
                    self?.rampFrame(token: token, from: from, to: to, start: start, duration: duration)
                }
            }
        } catch { stop(error.localizedDescription) }
    }

    private func setTarget(_ nits: Double) {
        guard ControlPolicy.target(nits) != nil else { return }
        guard active, record != nil else { send("off", "Enable brightness control to use the full range."); return }
        // Slider and keyboard intent immediately interrupts the activation ramp.
        let token = revision.advance(); isRamping = false
        targetNits = nits
        do {
            let current = try read()
            if let issue = ControlPolicy.activeIssue(current, original: record!.original) { throw XDRFailure.message(issue) }
            if ![0, 1].contains(current.preset) { send("active", "Choose a standard Apple preset to adjust brightness.", reported: current.reportedNits); return }
            if current.preset != 1 { try panel.selectPreset(1) }
            try acquireNativeBrightness(from: current.brightness)
            lastNativeBrightness = 0.999
            try apply(nits)
            send("active", "Brightness control is on.", reported: try read().reportedNits)
            completeNativeHandoff(token: token)
        } catch { stop(error.localizedDescription) }
    }

    private func acquireNativeBrightness(from brightness: Double) throws {
        guard abs(brightness - 0.999) > 0.0001 else { return }
        try panel.setBrightness(0.999)
        nativeHandoffUntil = ProcessInfo.processInfo.systemUptime + 0.1
    }

    private func completeNativeHandoff(token: Int) {
        guard ProcessInfo.processInfo.systemUptime < nativeHandoffUntil else { return }
        // DisplayServices can finish its scalar write after the driver target
        // was applied. Complete that owned handoff once, without delaying input
        // or periodically asserting brightness against another controller.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.active, self.revision.accepts(token), let record = self.record else { return }
            do {
                guard ControlPolicy.needsHandoffCompletion(record: record, current: try self.read()) else { return }
                try self.apply(self.targetNits)
                self.send("active", "Brightness control is on.", reported: try self.read().reportedNits)
            } catch { self.stop(error.localizedDescription) }
        }
    }

    private func apply(_ nits: Double) throws {
        guard let values = ControlPolicy.target(nits), let old = record else { throw XDRFailure.message("No active brightness transaction.") }
        record?.previous = old.expected
        record?.expected = values
        try persist()
        try panel.writeMetrics(values.mapValues(NSNumber.init(value:)))
        lastAppliedNits = nits
        settlingUntil = ProcessInfo.processInfo.systemUptime + 0.2
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastHeartbeat > 5 { stop("Controller stopped responding. Original settings restored."); exit(record == nil ? 0 : 2) }
        guard active, let record else { return }
        do {
            let current = try read()
            if let issue = ControlPolicy.activeIssue(current, original: record.original) { throw XDRFailure.message(issue) }
            guard !isRamping, now >= settlingUntil else { return }
            // Without key permission, a native up press must still escape 0%.
            // This one adjustment is limited to a black panel and a rising
            // native scalar; it is not a recurring brightness assertion.
            if ControlPolicy.shouldRecoverBlack(ownsZeroCap: current.metrics["limit_max_physical_brightness"] == 0 && record.expected["limit_max_physical_brightness"] == 0, requestedNits: lastAppliedNits, oldNative: lastNativeBrightness, newNative: current.brightness) {
                setTarget(31)
                return
            }
            // A native adjustment from the OS or another controller is adopted
            // without writing back. Only explicit slider/key intent reclaims the
            // native scalar, avoiding a background fight with BetterDisplay.
            if abs(current.brightness - lastNativeBrightness) > 0.002 {
                lastNativeBrightness = current.brightness
                targetNits = ControlPolicy.nits(forPercentage: min(100, max(0, current.brightness * 100))) ?? targetNits
                lastAppliedNits = current.reportedNits
                send("active", "System brightness changed. Control remains on.", reported: current.reportedNits)
                return
            }
            let matched = record.expected.allSatisfy { key, value in abs((current.metrics[key] ?? -.infinity) - value) <= 65536 }
            // Another app or the OS may write the same panel. Keep the switch on
            // and report readback; do not enter a competing background write loop.
            send("active", matched ? "Brightness control is on." : "Brightness changed externally. Slider and keys remain available.", reported: current.reportedNits)
        } catch { stop(error.localizedDescription) }
    }

    private func restore(keepingPrepared: Bool = false) throws {
        guard let record else { return }
        let current = try read()
        // A reboot ends the old hardware session. Never replay its state.
        if current.identity != record.original.identity {
            try FileManager.default.removeItem(at: Self.journal); self.record = nil; return
        }
        var failures: [String] = []
        let metrics = ControlPolicy.metricsToRestore(record: record, current: current, keepingPrepared: keepingPrepared)
        if !metrics.isEmpty {
            do { try panel.writeMetrics(metrics.mapValues(NSNumber.init(value:))) }
            catch { failures.append(error.localizedDescription) }
        }
        if current.preset == 1 {
            if record.controlsNativeBrightness != false && abs(current.brightness - 1) < 0.005 {
                do { try panel.setBrightness(Float(record.original.brightness)) }
                catch { failures.append(error.localizedDescription) }
            }
            if !keepingPrepared, let preset = ControlPolicy.presetToRestore(record: record, current: current) {
                do { try panel.selectPreset(UInt(preset)) }
                catch { failures.append(error.localizedDescription) }
            }
        }
        guard failures.isEmpty else { throw XDRFailure.message("Restoration needs attention: " + failures.joined(separator: " ")) }
        let verified = try read()
        for key in ["limit_max_physical_brightness", "IOMFBIndicatorNitsCap"] {
            if let expected = metrics[key], abs((verified.metrics[key] ?? -.infinity) - expected) > 1 {
                throw XDRFailure.message("The original panel limit did not restore. Recovery has been retained.")
            }
        }
        if keepingPrepared, let prepared = ControlPolicy.preparedRecord(after: record, current: verified) {
            // Commit the off-state baseline only after brightness restoration
            // succeeds. A crash before this point still recovers the active record.
            try persist(prepared)
            self.record = prepared
        } else {
            try FileManager.default.removeItem(at: Self.journal)
            self.record = nil
        }
    }

    private func stop(_ message: String, keepingPrepared: Bool = false) {
        _ = revision.advance(); active = false; isRamping = false
        do {
            try restore(keepingPrepared: keepingPrepared)
            let prepared = keepingPrepared && record?.isPrepared == true
            if !prepared { edrAnchor?.stop() }
            let percentage = (try? read()).map { $0.brightness * 100 }
            send("off", prepared ? "Boost is off. Display setup stays ready until you quit." : message, percentage: percentage)
        }
        catch { send("error", error.localizedDescription) }
    }

    private func send(_ state: String, _ message: String, reported: Double? = nil, percentage: Double? = nil) {
        var output: [String: Any] = ["state":state, "message":message, "requested":targetNits, "requestID":requestID]
        output["prepared"] = !active && record?.isPrepared == true
        output["percentage"] = percentage ?? ControlPolicy.percentage(forNits: targetNits)
        if state == "active" { output["activationMilliseconds"] = activationTiming }
        if let reported { output["reported"] = reported }
        if let data = try? JSONSerialization.data(withJSONObject: output, options: .sortedKeys) {
            var line = data; line.append(10)
            _ = line.withUnsafeBytes { Darwin.write(STDOUT_FILENO, $0.baseAddress, $0.count) }
        }
    }
}
