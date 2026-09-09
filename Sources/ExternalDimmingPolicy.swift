import Foundation

/// Hardware and software dimming share the same 0–100 request.
/// Software remains continuous when hardware discovery finishes later.
enum ExternalDimmingPolicy {
    static func opacity(percentage: Double, hardwareControlled: Bool) -> Double {
        guard percentage.isFinite else { return 0 }
        let range = 100.0
        return min(1, max(0, 1 - percentage / range))
    }
}
