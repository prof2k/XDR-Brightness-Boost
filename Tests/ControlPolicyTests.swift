import Foundation

@main
struct ControlPolicyTests {
    static func main() {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            guard value() else { fatalError(message) }
            checks += 1
        }
        let metrics = Dictionary(uniqueKeysWithValues: ControlPolicy.metricKeys.map { ($0, 1600.0 * 65536) })
        let original = PanelState(identity: "boot:display:panel", preset: 0, brightness: 0.4, autoBrightness: false, metrics: metrics, gamma: "original", neutralGamma: true, singleDisplay: true, awake: true, mode: "original-mode")
        check(ControlPolicy.activationIssue(original) == nil, "Known compatible state must be accepted")
        for value in [Double.nan, .infinity, -.infinity, -1, 1601] {
            check(ControlPolicy.target(value) == nil, "Invalid target must never reach the driver")
        }
        check(ControlPolicy.target(650)?["IOMFBBrightnessLevel"] == 42598400, "Nits must use observed 16.16 encoding")
        check(ControlPolicy.target(1600)?["IOMFBBrightnessLevel"] == 104857600, "The peak target must stay within the native cap")
        check(ControlPolicy.nits(forPercentage: 100) == 500, "100% must mean standard SDR brightness")
        check(ControlPolicy.nits(forPercentage: 160) == 1600, "160% must request the peak")
        check(ControlPolicy.nits(forPercentage: 130) == 1050, "The boost scale must interpolate its endpoints")
        for percent in [-1.0, 161.0, .nan, .infinity] {
            check(ControlPolicy.nits(forPercentage: percent) == nil, "Out-of-range percentages must be rejected")
        }
        var state = original
        state.autoBrightness = true
        check(ControlPolicy.activationIssue(state) != nil, "Auto brightness is a competing owner")
        state = original; state.neutralGamma = false
        check(ControlPolicy.activationIssue(state) == nil, "Another color controller must not prevent activation")
        state = original; state.preset = 2
        check(ControlPolicy.activationIssue(state) != nil, "Reference presets must be preserved")
        state = original; state.singleDisplay = false
        check(ControlPolicy.activationIssue(state) != nil, "Unsupported topology must block activation")
        state = original; state.metrics["limit_max_physical_brightness"] = 900 * 65536
        check(ControlPolicy.activationIssue(state) == nil, "A cap written by another brightness app must not be a launch blocker")

        var record = RecoveryRecord(original: original, expected: ControlPolicy.target(650)!, previous: ControlPolicy.target(600)!)
        state = original; state.metrics = record.expected; state.preset = 1; state.brightness = 1
        check(ControlPolicy.activeIssue(state, original: original) == nil, "Prepared state must be accepted")
        check(ControlPolicy.metricsToRestore(record: record, current: state) == original.metrics, "Owned values must restore")
        state.metrics["BLNitsCap"] = 700 * 65536
        check(ControlPolicy.metricsToRestore(record: record, current: state)["BLNitsCap"] == nil, "A newer cap belongs to the new owner")
        state.metrics["IOMFBBrightnessLevel"] = 600 * 65536
        check(ControlPolicy.metricsToRestore(record: record, current: state)["IOMFBBrightnessLevel"] == original.metrics["IOMFBBrightnessLevel"], "An interrupted transition must restore its prior owned value")
        state.identity = "different-boot"
        check(ControlPolicy.metricsToRestore(record: record, current: state).isEmpty, "Never restore to a different session")
        record.expected = [:]; record.previous = [:]
        state = original
        check(ControlPolicy.metricsToRestore(record: record, current: state).isEmpty, "An interrupted prepare must not invent metric ownership")

        state = original; state.preset = 1; state.brightness = 1
        state.gamma = "external"
        check(ControlPolicy.activeIssue(state, original: original) == nil, "Other color controllers must not switch us off")
        state.gamma = original.gamma; state.brightness = 0.8
        check(ControlPolicy.activeIssue(state, original: original) == nil, "Brightness keys must retain active control")
        state.brightness = 1; state.mode = "new-mode"
        check(ControlPolicy.activeIssue(state, original: original) == nil, "A resolution change on the same panel must retain control")
        var revisions = ControlRevision()
        let enable = revisions.advance()
        let disable = revisions.advance()
        check(!revisions.accepts(enable) && revisions.accepts(disable), "Disable must cancel pending activation")
        let olderTarget = revisions.advance()
        let newerTarget = revisions.advance()
        check(!revisions.accepts(olderTarget) && revisions.accepts(newerTarget), "Scrubbing must discard stale targets")
        check(ControlPolicy.nits(forPercentage: 0) == 0, "0% must reach black")
        check(ControlPolicy.nits(forPercentage: 50) == 250, "Dimming must use the lower range")
        check(ControlPolicy.target(0)?["IOMFBBrightnessLevel"] == 0, "Zero is a valid owned brightness")
        check(ControlPolicy.enabledPercentage(nativeBrightness: 1) == 160, "Enabling at native 100% must target 160%")
        check(ControlPolicy.enabledPercentage(nativeBrightness: 0.5) == 80, "Enabling must expand the current native position")
        for percentage in stride(from: 0.0, through: 160.0, by: 10) {
            let roundTrip = ControlPolicy.percentage(forNits: ControlPolicy.nits(forPercentage: percentage)!)
            check(abs(roundTrip - percentage) < 0.04, "Slider mapping must round-trip")
        }
        check(ControlPolicy.adjustedPercentage(160, direction: 1, fine: false) == 160, "Up must clamp at the peak")
        check(ControlPolicy.adjustedPercentage(0, direction: -1, fine: false) == 0, "Down must clamp at black")
        check(ControlPolicy.adjustedPercentage(100, direction: 1, fine: false) == 106.25, "Keys must cross the SDR boundary")
        check(ControlPolicy.adjustedPercentage(100, direction: -1, fine: true) == 98.4375, "Option Shift must use quarter steps")
        var sequence = BrightnessKeySequence()
        let press = BrightnessKey.decode(subtype: 8, data1: (2 << 16) | (0x0a << 8))!
        let repeatKey = BrightnessKey.decode(subtype: 8, data1: (2 << 16) | (0x0a << 8) | 1)!
        let release = BrightnessKey.decode(subtype: 8, data1: (2 << 16) | (0x0b << 8))!
        check(!sequence.consumes(repeatKey, enabled: true), "Orphan repeats must remain OS-owned")
        check(sequence.consumes(press, enabled: true), "A fresh press can be captured")
        check(sequence.consumes(repeatKey, enabled: true), "Owned repeats stay captured")
        check(!sequence.consumes(release, enabled: true), "Release must always reach the OS")
        check(!sequence.consumes(repeatKey, enabled: true), "Released sequences cannot keep repeating")
        check(sequence.consumes(press, enabled: true), "Next press must work")
        sequence.reset()
        check(!sequence.consumes(repeatKey, enabled: true), "Timeout must not reacquire a held key")
        check(!sequence.consumes(release, enabled: true), "Release after timeout must reach the OS")
        check(!sequence.consumes(press, enabled: false), "Disabled control must pass presses")
        check(!sequence.consumes(repeatKey, enabled: true), "Enabling mid-hold must not steal repeats")
        check(BrightnessKey.decode(subtype: 8, data1: (2 << 16) | (0x0a << 8))?.direction == 1, "Brightness up must decode")
        check(BrightnessKey.decode(subtype: 8, data1: (3 << 16) | (0x0a << 8) | 1)?.isDown == true, "Auto-repeat must remain a down event")
        check(BrightnessKey.decode(subtype: 8, data1: (3 << 16) | (0x0b << 8))?.isDown == false, "Up events must not adjust twice")
        check(BrightnessKey.decode(subtype: 8, data1: (0 << 16) | (0x0a << 8)) == nil, "Volume keys must pass through")
        check(BrightnessKey.decode(subtype: 7, data1: (2 << 16) | (0x0a << 8)) == nil, "Unrelated system events must pass through")
        check(ControlPolicy.rampValue(from: 500, to: 1600, progress: 0) == 500, "Ramp must start at the original level")
        check(ControlPolicy.rampValue(from: 500, to: 1600, progress: 1) == 1600, "Ramp must land exactly at max")
        var last = 500.0
        for frame in 1...20 {
            let current = ControlPolicy.rampValue(from: 500, to: 1600, progress: Double(frame) / 20)
            check(current >= last && current <= 1600, "Activation must be monotonic without overshoot")
            last = current
        }
        check(ControlPolicy.shouldRecoverBlack(ownsZeroCap: true, requestedNits: 0, oldNative: 0.999, newNative: 1), "A native up press must escape black without Accessibility")
        check(!ControlPolicy.shouldRecoverBlack(ownsZeroCap: true, requestedNits: 0, oldNative: 0.999, newNative: 0.9375), "Down at black must not brighten")
        check(!ControlPolicy.shouldRecoverBlack(ownsZeroCap: false, requestedNits: 0, oldNative: 0.8, newNative: 1), "Do not overwrite another controller that already raised brightness")
        check(!ControlPolicy.shouldRecoverBlack(ownsZeroCap: true, requestedNits: 0, oldNative: 0.999, newNative: 0.9990001), "Readback noise must not brighten a black panel")
        let firstActivation = ControlPolicy.activationRecord(original: original, prepared: nil)
        check(firstActivation.restorationPreset == 0 && !firstActivation.isPrepared, "First activation must remember the original XDR preset")
        state = original; state.preset = 1
        let prepared = ControlPolicy.preparedRecord(after: firstActivation, current: state)!
        check(prepared.isPrepared && prepared.restorationPreset == 0, "Boost-off must retain the session's original preset")
        check(ControlPolicy.metricsToRestore(record: prepared, current: state).isEmpty, "Prepared/off must not claim brightness ownership")
        state.brightness = 0.65
        let secondActivation = ControlPolicy.activationRecord(original: state, prepared: prepared)
        check(secondActivation.original.brightness == 0.65, "Reactivation must snapshot the latest native brightness")
        check(secondActivation.restorationPreset == 0, "Reactivation must not replace the original preset with the prepared preset")
        let preparedAgain = ControlPolicy.preparedRecord(after: secondActivation, current: state)!
        check(preparedAgain.restorationPreset == 0 && preparedAgain.controlsNativeBrightness == false, "Repeated toggles must retain only preset ownership while off")
        check(ControlPolicy.presetToRestore(record: preparedAgain, current: state) == 0, "Quit or crash recovery from standby must restore the session preset")
        state.preset = 0
        check(ControlPolicy.presetToRestore(record: preparedAgain, current: state) == nil, "A later preset change belongs to the user or other app")
        check(ControlPolicy.preparedRecord(after: secondActivation, current: state) == nil, "Do not claim a prepared preset after another controller replaces it")
        state.identity = "new-panel"; state.preset = 1
        check(ControlPolicy.presetToRestore(record: preparedAgain, current: state) == nil, "Prepared recovery must not cross panel sessions")
        check(ControlPolicy.activationRecord(original: state, prepared: preparedAgain).restorationPreset == 1, "A new panel session must start a fresh preset baseline")
        let legacy = RecoveryRecord(original: original)
        let encoded = try! JSONEncoder().encode(legacy)
        let decoded = try! JSONDecoder().decode(RecoveryRecord.self, from: encoded)
        check(decoded.sessionPreset == nil && decoded.restorationPreset == 0 && !decoded.isPrepared, "Recovery must remain compatible with old journals")
        let savedPrepared = try! JSONDecoder().decode(RecoveryRecord.self, from: JSONEncoder().encode(preparedAgain))
        check(savedPrepared.isPrepared && savedPrepared.restorationPreset == 0, "Durable prepared state must survive a crash")
        var handoff = firstActivation
        handoff.expected = ControlPolicy.target(350)!
        state = original; state.preset = 1; state.brightness = 0.999; state.linearBrightness = 0.997
        state.metrics = handoff.expected
        state.metrics["IOMFBBrightnessLevel"] = state.standardNits * 65536
        check(ControlPolicy.needsHandoffCompletion(record: handoff, current: state), "A late native scalar write may finish once while both caps remain owned")
        state.metrics["limit_max_physical_brightness"] = 600 * 65536
        check(!ControlPolicy.needsHandoffCompletion(record: handoff, current: state), "Do not complete a handoff after a foreign cap change")
        state.metrics = handoff.expected
        check(!ControlPolicy.needsHandoffCompletion(record: handoff, current: state), "An already settled target needs no follow-up write")
        state.metrics["IOMFBBrightnessLevel"] = 700 * 65536
        check(!ControlPolicy.needsHandoffCompletion(record: handoff, current: state), "Unrelated levels must not be mistaken for a native scalar completion")
        state.metrics["IOMFBBrightnessLevel"] = state.standardNits * 65536; state.brightness = 0.8
        check(!ControlPolicy.needsHandoffCompletion(record: handoff, current: state), "An external native brightness change must cancel handoff completion")
        state = original; state.preset = 1; state.metrics = handoff.expected
        let standbyMetrics = ControlPolicy.metricsToRestore(record: handoff, current: state, keepingPrepared: true)
        check(standbyMetrics["IOMFBBrightnessLevel"] == original.standardNits * 65536, "Boost-off must convert the old HDR backlight level to normal SDR brightness")
        check(standbyMetrics["limit_max_physical_brightness"] == original.metrics["limit_max_physical_brightness"], "Normalizing the off level must still restore the owned physical cap")
        state.preset = 0
        check(ControlPolicy.metricsToRestore(record: handoff, current: state, keepingPrepared: true)["IOMFBBrightnessLevel"] == original.metrics["IOMFBBrightnessLevel"], "Do not apply SDR normalization after another app has restored the XDR preset")
        state.preset = 1
        state.metrics["IOMFBBrightnessLevel"] = 900 * 65536
        check(ControlPolicy.metricsToRestore(record: handoff, current: state, keepingPrepared: true)["IOMFBBrightnessLevel"] == nil, "Off-state normalization must preserve a foreign level write")
        let crossed = ControlPolicy.keyTarget(100, direction: 1, fine: false, supportsBoost: true, boostEnabled: false)
        check(crossed.percentage == 106.25 && crossed.boostEnabled, "Keys enable boost above 100 without recalling the old maximum")
        let fineCrossed = ControlPolicy.keyTarget(99, direction: 1, fine: true, supportsBoost: true, boostEnabled: false)
        check(fineCrossed.percentage == 100.5625 && fineCrossed.boostEnabled, "Fine keys enable boost when crossing 100")
        let atBoundary = ControlPolicy.keyTarget(93.75, direction: 1, fine: false, supportsBoost: true, boostEnabled: false)
        check(atBoundary.percentage == 100 && !atBoundary.boostEnabled, "Exactly 100 does not enable boost")
        let lowered = ControlPolicy.keyTarget(101, direction: -1, fine: false, supportsBoost: true, boostEnabled: true)
        check(lowered.percentage == 94.75 && lowered.boostEnabled, "Lowering below 100 retains the toggle")
        let offDown = ControlPolicy.keyTarget(100, direction: -1, fine: false, supportsBoost: true, boostEnabled: false)
        check(offDown.percentage == 93.75 && !offDown.boostEnabled, "Down after toggle-off leaves boost off")
        var held = (percentage: 100.0, boostEnabled: false)
        for _ in 0..<40 {
            held = ControlPolicy.keyTarget(held.percentage, direction: 1, fine: false, supportsBoost: true, boostEnabled: held.boostEnabled)
            check(held.percentage <= 160 && held.boostEnabled, "Held up remains enabled and caps at 160")
        }
        check(held.percentage == 160, "Held up reaches 160")
        for _ in 0..<40 {
            held = ControlPolicy.keyTarget(held.percentage, direction: -1, fine: false, supportsBoost: true, boostEnabled: held.boostEnabled)
        }
        check(held.percentage == 0 && held.boostEnabled, "Held down stops at zero without disabling boost")
        for fine in [false, true] {
            let unsupported = ControlPolicy.keyTarget(100, direction: 1, fine: fine, supportsBoost: false, boostEnabled: true)
            check(unsupported.percentage == 100 && !unsupported.boostEnabled, "Unsupported display stays capped even with stale enabled state")
        }
        check(ControlPolicy.keyPercentage(0, direction: -1, fine: false, supportsBoost: false) == 0, "SDR keys stop at zero")
        for fine in [false, true] {
            let restricted = ControlPolicy.keyTarget(100, direction: 1, fine: fine, supportsBoost: true, boostEnabled: false, allowBoostActivation: false)
            check(restricted.percentage == 100 && !restricted.boostEnabled, "Setting off keeps keys at 100 when boost is off")
            let enabled = ControlPolicy.keyTarget(100, direction: 1, fine: fine, supportsBoost: true, boostEnabled: true, allowBoostActivation: false)
            check(enabled.percentage > 100 && enabled.boostEnabled, "Setting off still permits boost when manually enabled")
            let capped = ControlPolicy.keyTarget(159.5, direction: 1, fine: fine, supportsBoost: true, boostEnabled: true, allowBoostActivation: false)
            check(capped.percentage == 160 && capped.boostEnabled, "Manual boost remains capped at 160")
        }
        print("Control policy: \(checks) checks passed")
    }
}
