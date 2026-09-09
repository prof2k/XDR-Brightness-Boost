import AppKit

/// Owned by the existing watchdog helper, not the UI process. Restore only
/// curves that still match our writes; never reset every display's ColorSync.
@MainActor
final class ExternalGamma {
    private struct Session: Codable {
        let uuid: String
        let original: ColorCurve
        var expected: ColorCurve
        var previous: ColorCurve
    }
    private let journal = BrightnessWorker.support.appendingPathComponent("external-gamma-recovery.json")
    private var sessions: [String: Session] = [:]

    func recover() throws {
        guard FileManager.default.fileExists(atPath: journal.path) else { return }
        sessions = try JSONDecoder().decode([String: Session].self, from: Data(contentsOf: journal))
        guard sessions.values.allSatisfy({ $0.original.isValid && $0.expected.isValid && $0.previous.isValid }) else { throw XDRFailure.message("Invalid external dimming recovery data.") }
        try restoreAll()
    }
    private func uuid(_ id: UInt32) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
    private func read(_ id: UInt32) throws -> ColorCurve {
        let capacity = CGDisplayGammaTableCapacity(id)
        guard (2...16384).contains(capacity) else { throw XDRFailure.message("Display-level dimming is unavailable.") }
        var r = [Float](repeating: 0, count: Int(capacity)), g = r, b = r, count: UInt32 = 0
        guard CGGetDisplayTransferByTable(id, capacity, &r, &g, &b, &count) == .success else { throw XDRFailure.message("Could not read the external color table.") }
        let curve = ColorCurve(red: Array(r.prefix(Int(count))), green: Array(g.prefix(Int(count))), blue: Array(b.prefix(Int(count))))
        guard curve.isValid else { throw XDRFailure.message("Invalid external color table.") }
        return curve
    }
    private func write(_ curve: ColorCurve, to id: UInt32) throws {
        guard CGSetDisplayTransferByTable(id, UInt32(curve.red.count), curve.red, curve.green, curve.blue) == .success,
              try read(id).matches(curve) else { throw XDRFailure.message("External display rejected display-level dimming.") }
    }
    private func persist() throws {
        try FileManager.default.createDirectory(at: BrightnessWorker.support, withIntermediateDirectories: true)
        try JSONEncoder().encode(sessions).write(to: journal, options: .atomic)
        guard chmod(journal.path, 0o600) == 0 else { throw XDRFailure.message("Could not secure external recovery data.") }
    }
    func set(_ factor: Double, display id: UInt32, identity: String) throws {
        guard factor.isFinite, (0...1).contains(factor), CGDisplayIsBuiltin(id) == 0,
              CGDisplayIsOnline(id) != 0, CGDisplayIsInMirrorSet(id) == 0, uuid(id) == identity else { return }
        let actual = try read(id)
        if let session = sessions[identity] {
            guard actual.matches(session.expected) || actual.matches(session.previous) else {
                sessions[identity] = nil; try persist()
                throw XDRFailure.message("Another controller changed the external color table; dimming released.")
            }
        } else {
            guard factor < 1 else { return }
            sessions[identity] = Session(uuid: identity, original: actual, expected: actual, previous: actual)
        }
        guard var session = sessions[identity] else { return }
        let desired = session.original.scaled(by: Float(factor))
        session.previous = session.expected
        session.expected = desired
        sessions[identity] = session
        try persist() // Journal before changing display state, for crash recovery.
        try write(desired, to: id)
        if factor == 1 { sessions[identity] = nil; try persist() }
    }
    func restoreAll() throws {
        for screen in NSScreen.screens {
            let id = screen.brightnessDisplayID
            guard let identity = uuid(id), let session = sessions[identity], CGDisplayIsBuiltin(id) == 0 else { continue }
            let current = try read(id)
            if current.matches(session.expected) || current.matches(session.previous) { try write(session.original.scaled(by: 1), to: id) }
            sessions[identity] = nil
        }
        if !sessions.isEmpty || FileManager.default.fileExists(atPath: journal.path) { try persist() }
    }
}
