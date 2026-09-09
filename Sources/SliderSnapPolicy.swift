import Foundation

enum SliderScale {
    static func position(for percentage: Double, supportsBoost: Bool = true) -> Double {
        if !supportsBoost { return min(100, max(0, percentage)) / 100 }
        let value = min(160, max(0, percentage))
        return value <= 100 ? value * 0.65 / 100 : 0.65 + (value - 100) * 0.35 / 60
    }

    static func percentage(at position: Double, supportsBoost: Bool = true) -> Double {
        if !supportsBoost { return min(1, max(0, position)) * 100 }
        let value = min(1, max(0, position))
        return value <= 0.65 ? value * 100 / 0.65 : 100 + (value - 0.65) * 60 / 0.35
    }
}

enum SliderSnapPolicy {
    static let marks = [10.0, 100.0]
    static let radius = 5.0

    static func snapped(_ percentage: Double) -> Double {
        let value = min(160, max(0, percentage))
        guard let mark = marks.first(where: { abs(value - $0) < radius }) else { return value }
        let distance = (value - mark) / radius
        // Continuous resistance: 20% speed at the landmark, returning smoothly
        // to normal speed at both boundaries. Absolute input prevents trapping.
        let blend = 1 - distance * distance
        return mark + radius * distance * (1 - 0.8 * blend * blend)
    }
}

struct SliderDragGeometry {
    let minimumX: Double
    let maximumX: Double
    let grabOffset: Double

    func percentage(at pointerX: Double) -> Double {
        guard maximumX > minimumX else { return 0 }
        return SliderScale.percentage(at: (pointerX - grabOffset - minimumX) / (maximumX - minimumX))
    }
}
