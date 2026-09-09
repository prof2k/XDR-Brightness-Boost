import Foundation

struct PanelState: Codable {
    var identity: String
    var preset: Int
    var brightness: Double
    var autoBrightness: Bool
    var metrics: [String: Double]
    var gamma: String
    var neutralGamma: Bool
    var singleDisplay: Bool
    var awake: Bool
    var mode: String
    var linearBrightness: Double?

    var reportedNits: Double { (metrics["IOMFBBrightnessLevel"] ?? 0) / 65536 }
    var standardNits: Double { min(500, max(0, (linearBrightness ?? brightness) * 500)) }
}

struct RecoveryRecord: Codable {
    let original: PanelState
    var expected: [String: Double] = [:]
    var previous: [String: Double] = [:]
    var controlsNativeBrightness: Bool? = nil
    // The brightness baseline is renewed on each activation. Keep the preset
    // that preceded this controller session separately across prepared/off cycles.
    var sessionPreset: Int? = nil

    var restorationPreset: Int { sessionPreset ?? original.preset }
    var isPrepared: Bool { controlsNativeBrightness == false && expected.isEmpty && previous.isEmpty }
}

enum ControlPolicy {
    static let metricKeys = ["BLNitsCap", "IOMFBBrightnessLevel", "IOMFBIndicatorNitsCap", "limit_max_physical_brightness"]
    static let defaultPercentage = 100.0

    // One continuous control: ordinary dimming below 100, extended range above.
    static func nits(forPercentage percentage: Double) -> Double? {
        guard percentage.isFinite, (0...160).contains(percentage) else { return nil }
        return (percentage <= 100 ? percentage * 5 : 500 + (percentage - 100) * (1100 / 60)).rounded()
    }

    static func percentage(forNits nits: Double) -> Double {
        let nits = min(1600, max(0, nits))
        return nits <= 500 ? nits / 5 : 100 + (nits - 500) * (60 / 1100)
    }

    static func enabledPercentage(nativeBrightness: Double) -> Double {
        min(160, max(0, nativeBrightness * 160))
    }

    static func adjustedPercentage(_ current: Double, direction: Int, fine: Bool) -> Double {
        min(160, max(0, current + Double(direction) * (fine ? 1.5625 : 6.25)))
    }

    static func keyPercentage(_ current: Double, direction: Int, fine: Bool, supportsBoost: Bool) -> Double {
        min(supportsBoost ? 160 : 100, adjustedPercentage(current, direction: direction, fine: fine))
    }

    static func keyTarget(_ current: Double, direction: Int, fine: Bool, supportsBoost: Bool, boostEnabled: Bool, allowBoostActivation: Bool = true) -> (percentage: Double, boostEnabled: Bool) {
        let percentage = keyPercentage(current, direction: direction, fine: fine, supportsBoost: supportsBoost && (boostEnabled || allowBoostActivation))
        return (percentage, supportsBoost && (boostEnabled || percentage > 100))
    }

    static func rampValue(from: Double, to: Double, progress: Double) -> Double {
        let t = min(1, max(0, progress))
        return from + (to - from) * t * t * (3 - 2 * t)
    }

    static func shouldRecoverBlack(ownsZeroCap: Bool, requestedNits: Double, oldNative: Double, newNative: Double) -> Bool {
        ownsZeroCap && requestedNits < 1 && newNative > oldNative + 0.0001
    }

    static func target(_ nits: Double) -> [String: Double]? {
        guard nits.isFinite, (0...1600).contains(nits) else { return nil }
        return Dictionary(uniqueKeysWithValues: metricKeys.map { ($0, (nits * 65536).rounded()) })
    }

    static func activationIssue(_ state: PanelState) -> String? {
        if !state.awake || !state.singleDisplay { return "The built-in display must be awake and unmirrored." }
        if state.autoBrightness { return "Turn off automatic brightness in System Settings to use manual control." }
        if ![0, 1].contains(state.preset) { return "Choose a standard Apple display preset first." }
        return nil
    }

    static func activeIssue(_ current: PanelState, original: PanelState) -> String? {
        if current.identity != original.identity || !current.singleDisplay || !current.awake { return "The built-in display is unavailable. Control has been released." }
        // Brightness keys, color curves, resolution changes and another app's
        // presence are not reasons to switch the controller off.
        return nil
    }

    static func activationRecord(original: PanelState, prepared: RecoveryRecord?) -> RecoveryRecord {
        let retainsPreset = prepared?.original.identity == original.identity && original.preset == 1
        return RecoveryRecord(original: original, controlsNativeBrightness: true,
                              sessionPreset: retainsPreset ? prepared?.restorationPreset : original.preset)
    }

    static func preparedRecord(after record: RecoveryRecord, current: PanelState) -> RecoveryRecord? {
        guard current.identity == record.original.identity, current.preset == 1 else { return nil }
        // No brightness writes are owned while off. Native keys and other apps
        // are free to change brightness without it being replayed on quit.
        return RecoveryRecord(original: current, controlsNativeBrightness: false,
                              sessionPreset: record.restorationPreset)
    }

    static func presetToRestore(record: RecoveryRecord, current: PanelState) -> Int? {
        guard current.identity == record.original.identity, current.preset == 1,
              record.restorationPreset != 1 else { return nil }
        return record.restorationPreset
    }

    static func needsHandoffCompletion(record: RecoveryRecord, current: PanelState) -> Bool {
        guard current.identity == record.original.identity, current.preset == 1,
              current.awake, current.singleDisplay, abs(current.brightness - 0.999) < 0.0002,
              let expected = record.expected["IOMFBBrightnessLevel"],
              abs(current.reportedNits - expected / 65536) > 1,
              abs(current.reportedNits - current.standardNits) < 1 else { return false }
        return ["limit_max_physical_brightness", "IOMFBIndicatorNitsCap"].allSatisfy { key in
            guard let value = current.metrics[key], let owned = record.expected[key] else { return false }
            return abs(value - owned) < 1
        }
    }

    // Preserve later writes by the user or another app when releasing control.
    static func metricsToRestore(record: RecoveryRecord, current: PanelState, keepingPrepared: Bool = false) -> [String: Double] {
        guard record.original.identity == current.identity else { return [:] }
        var result: [String: Double] = [:]
        for key in metricKeys {
            guard let value = current.metrics[key], let original = record.original.metrics[key] else { continue }
            if [record.expected[key], record.previous[key]].compactMap({ $0 }).contains(where: { abs($0 - value) < 1 }) {
                // An XDR-mode backlight level can be 1600 even when SDR white
                // is 500. Replaying it into the retained SDR preset would
                // briefly brighten boost-off before macOS restores its scalar.
                if keepingPrepared && current.preset == 1 && record.original.preset == 0 && ["BLNitsCap", "IOMFBBrightnessLevel"].contains(key) {
                    result[key] = (record.original.standardNits * 65536).rounded()
                } else {
                    result[key] = original
                }
            }
        }
        return result
    }
}

struct ControlRevision {
    private(set) var value = 0
    mutating func advance() -> Int { value += 1; return value }
    func accepts(_ candidate: Int) -> Bool { candidate == value }
}

// These media-key codes and subtype are declared in Apple's IOKit SDK headers.
struct BrightnessKey {
    let direction: Int
    let isDown: Bool
    let isRepeat: Bool

    static func decode(subtype: Int, data1: Int) -> BrightnessKey? {
        guard subtype == 8 else { return nil }
        let key = (data1 >> 16) & 0xffff
        let state = (data1 >> 8) & 0xff
        guard [2, 3].contains(key), [0x0a, 0x0b].contains(state) else { return nil }
        return BrightnessKey(direction: key == 2 ? 1 : -1, isDown: state == 0x0a, isRepeat: data1 & 1 != 0)
    }
}


// Never acquire a key halfway through an OS-owned repeat sequence. Releases
// always pass downstream, including after a timeout or permission interruption.
struct BrightnessKeySequence {
    private var owned: Set<Int> = []
    mutating func reset() { owned.removeAll() }
    mutating func consumes(_ key: BrightnessKey, enabled: Bool) -> Bool {
        if !key.isDown { owned.remove(key.direction); return false }
        guard enabled else { owned.remove(key.direction); return false }
        if key.isRepeat { return owned.contains(key.direction) }
        owned.insert(key.direction)
        return true
    }
}
