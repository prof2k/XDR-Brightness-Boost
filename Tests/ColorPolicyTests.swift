import Foundation

@main struct ColorPolicyTests {
    static func main() {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool) { precondition(value()); checks += 1 }
        let linear = (0..<1024).map { Float($0) / 1023 }
        let original = ColorCurve(red: linear, green: linear, blue: linear)
        check(original.isValid)
        check(original.matches(original.scaled(by: 1)))
        let boosted = original.scaled(by: 1.6)
        check(boosted.red.count == 256)
        check(abs(boosted.red.last! - 1.6) < 0.0001)
        check(boosted.red[192] < boosted.red.last!)
        check(boosted.red[192] > 1)
        check(!original.matches(boosted))
        let restored = boosted.scaled(by: 1 / 1.6)
        check(restored.matches(original))
        check(ColorPolicy.native(0) == 0)
        check(ColorPolicy.native(50) == 0.5)
        check(ColorPolicy.native(100) == 1)
        check(ColorPolicy.native(160) == 1)
        check(ColorPolicy.factor(0) == 1)
        check(ColorPolicy.factor(100) == 1)
        check(abs(ColorPolicy.factor(160) - 1.6) < 0.0001)
        check(ColorPolicy.observedPercentage(nativeBrightness: 0.625, curve: original) == 62.5)
        check(abs(ColorPolicy.observedPercentage(nativeBrightness: 1, curve: boosted)! - 160) < 0.001)
        // External native changes must still be reflected under an owned boost.
        check(abs(ColorPolicy.observedPercentage(nativeBrightness: 0.5, curve: boosted)! - 80) < 0.001)
        check(ColorPolicy.observedPercentage(nativeBrightness: 0, curve: boosted) == 0)
        check(ColorPolicy.observedPercentage(nativeBrightness: 1, curve: original.scaled(by: 0.5)) == 50)
        check(ColorPolicy.observedPercentage(nativeBrightness: 1, curve: original.scaled(by: 2)) == 160)
        check(ColorPolicy.observedPercentage(nativeBrightness: .nan, curve: original) == nil)
        check(ColorPolicy.observedPercentage(nativeBrightness: 1.1, curve: original) == nil)
        check(ColorPolicy.observedPercentage(nativeBrightness: 0.5, curve: ColorCurve(red: [], green: [], blue: [])) == nil)
        check(!ColorCurve(red: [.nan, 1], green: [0, 1], blue: [0, 1]).isValid)
        check(!ColorCurve(red: [0], green: [0], blue: [0]).isValid)
        let data = try! JSONEncoder().encode(boosted)
        check(try! JSONDecoder().decode(ColorCurve.self, from: data).matches(boosted))
        print("PASS: \(checks) color curve and range checks")
    }
}
