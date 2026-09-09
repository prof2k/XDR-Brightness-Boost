import Foundation

struct ColorCurve: Codable {
    var red: [Float]
    var green: [Float]
    var blue: [Float]

    var isValid: Bool {
        red.count >= 2 && red.count <= 16384 && red.count == green.count && red.count == blue.count &&
        [red, green, blue].allSatisfy { $0.allSatisfy { $0.isFinite && (0...16).contains($0) } }
    }

    func scaled(by factor: Float, count: Int = 256) -> ColorCurve {
        func sample(_ values: [Float]) -> [Float] {
            (0..<count).map { index in
                let position = Double(index) * Double(values.count - 1) / Double(count - 1)
                let lower = Int(position), upper = min(values.count - 1, lower + 1)
                let part = Float(position - Double(lower))
                return (values[lower] * (1 - part) + values[upper] * part) * factor
            }
        }
        return ColorCurve(red: sample(red), green: sample(green), blue: sample(blue))
    }

    func matches(_ other: ColorCurve, tolerance: Float = 0.003) -> Bool {
        guard isValid, other.isValid else { return false }
        let a = scaled(by: 1), b = other.scaled(by: 1)
        return zip(a.red + a.green + a.blue, b.red + b.green + b.blue).allSatisfy { abs($0 - $1) <= tolerance }
    }
}

enum ColorPolicy {
    // The app's control scale combines native brightness with the color
    // table's white-level gain. It is a readback, not a measurement in nits.
    static func observedPercentage(nativeBrightness: Double, curve: ColorCurve) -> Double? {
        guard nativeBrightness.isFinite, (0...1).contains(nativeBrightness), curve.isValid else { return nil }
        let white = Double(max(curve.red.last!, curve.green.last!, curve.blue.last!))
        return min(160, max(0, nativeBrightness * white * 100))
    }

    static func factor(_ percentage: Double) -> Float {
        Float(1 + max(0, min(160, percentage) - 100) / 100)
    }
    static func native(_ percentage: Double) -> Float {
        Float(min(100, max(0, percentage)) / 100)
    }
}
