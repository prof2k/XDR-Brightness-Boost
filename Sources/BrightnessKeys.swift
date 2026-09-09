import AppKit
import os

// The tap observes only system-defined media events. It never reads text keys.
// The callback performs no panel I/O; it forwards brightness intent to the worker.
@MainActor
final class BrightnessKeys {
    // Key control is automatic; the old allowBrightnessKeys preference is
    // deliberately ignored. System permission is still required.
    var controlsBrightness = false
    var onStep: ((Int, Bool) -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var lastDiagnostic = ""
    private var sequence = BrightnessKeySequence()
    private var deliveryGeneration = 0
    private static let log = Logger(subsystem: "local.elijah.XDRBrightness", category: "BrightnessKeys")
    private(set) var accessState: KeyAccessState = .checking
    private var permissionGranted: Bool?
    private var checkingPermission = false
    private var nextPermissionCheck = 0.0
    private let permissionQueue = DispatchQueue(label: "local.elijah.XDRBrightness.key-permission", qos: .utility)
    var isAvailable: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    func connect(prompt: Bool = false, reclaim: Bool = false) {
        defer { refreshAccessState() }
        // An active filter needs Core Graphics event-control access. Broad AX
        // trust is a different check, especially under macOS 27's access model.
        // Never gate tap creation on a preflight; its actual result is final.
        if prompt && !isAvailable { _ = CGRequestPostEventAccess() }
        if prompt || reclaim { nextPermissionCheck = 0 }
        // Never tear down a working tap on activation or popup interaction:
        // doing so can split a held key sequence between us and macOS.
        if reclaim && tap != nil && !isAvailable {
            let wasControlling = controlsBrightness
            disconnect()
            controlsBrightness = wasControlling
        }
        defer {
            // Permission preflights can block in TCC. Never run one in the
            // heartbeat while a working tap exists; it delays key delivery on
            // this run loop and can make macOS disable the callback by timeout.
            let diagnostic = "session tap=\(isAvailable)"
            if diagnostic != lastDiagnostic {
                lastDiagnostic = diagnostic
                Self.log.notice("\(diagnostic, privacy: .public)")
            }
        }
        if let tap, CFMachPortIsValid(tap) {
            if !CGEvent.tapIsEnabled(tap: tap) {
                sequence.reset()
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }
        if tap != nil {
            let wasControlling = controlsBrightness
            disconnect()
            controlsBrightness = wasControlling
        }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return MainActor.assumeIsolated {
                let owner = Unmanaged<BrightnessKeys>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    owner.sequence.reset()
                    owner.deliveryGeneration += 1
                    BrightnessKeys.log.error("Brightness tap interrupted: \(type.rawValue)")
                    if let tap = owner.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                guard type.rawValue == NSEvent.EventType.systemDefined.rawValue,
                      let native = NSEvent(cgEvent: event),
                      let key = BrightnessKey.decode(subtype: Int(native.subtype.rawValue), data1: native.data1) else {
                    return Unmanaged.passUnretained(event)
                }
                guard owner.sequence.consumes(key, enabled: owner.controlsBrightness) else {
                    return Unmanaged.passUnretained(event)
                }
                let fine = native.modifierFlags.contains([.option, .shift])
                let generation = owner.deliveryGeneration
                // Finish the filtering callback before doing UI, native-display
                // discovery, popup animation, or IPC work.
                DispatchQueue.main.async { [weak owner] in
                    guard let owner, owner.controlsBrightness, owner.deliveryGeneration == generation else { return }
                    owner.onStep?(key.direction, fine)
                }
                return nil
            }
        }
        // Capture in the logged-in user's session, the same location used by
        // MediaKeyTap. The HID entry point has different access constraints and
        // is unnecessary for consuming these system-defined brightness events.
        guard let created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                              eventsOfInterest: CGEventMask(1) << NSEvent.EventType.systemDefined.rawValue,
                                              callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        tap = created
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
    }

    private func refreshAccessState() {
        accessState = KeyAccessState.resolve(tapAvailable: isAvailable, permissionGranted: permissionGranted)
        // Never run a TCC check on the event-tap/UI thread. Check only when
        // capture failed, coalescing retries, and let a working tap win over
        // any older permission result that arrives after access is granted.
        guard !isAvailable, !checkingPermission,
              ProcessInfo.processInfo.systemUptime >= nextPermissionCheck else { return }
        checkingPermission = true
        nextPermissionCheck = ProcessInfo.processInfo.systemUptime + 5
        permissionQueue.async { [weak self] in
            let allowed = CGPreflightPostEventAccess()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.checkingPermission = false
                self.permissionGranted = allowed
                self.accessState = KeyAccessState.resolve(tapAvailable: self.isAvailable, permissionGranted: allowed)
            }
        }
    }

    func disconnect() {
        controlsBrightness = false
        sequence.reset()
        deliveryGeneration += 1
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil; tap = nil
    }
}
