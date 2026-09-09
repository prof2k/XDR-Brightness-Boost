import Foundation

@main struct SliderSnapPolicyTests {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool) { precondition(condition()); checks += 1 }
        for mark in SliderSnapPolicy.marks {
            check(SliderSnapPolicy.snapped(mark - 5) == mark - 5)
            check(SliderSnapPolicy.snapped(mark + 5) == mark + 5)
            check(SliderSnapPolicy.snapped(mark) == mark)
            check(SliderSnapPolicy.snapped(mark - 5.01) == mark - 5.01)
            check(SliderSnapPolicy.snapped(mark + 5.01) == mark + 5.01)
        }
        check(SliderSnapPolicy.snapped(0) == 0)
        check(SliderSnapPolicy.snapped(160) == 160)
        for mark in SliderSnapPolicy.marks {
            let inputs = (0...1200).map { mark - 6 + Double($0) / 100 }
            let outputs = inputs.map(SliderSnapPolicy.snapped)
            check(zip(outputs, outputs.dropFirst()).allSatisfy { $1 > $0 && $1 - $0 < 0.02 })
            check(abs(SliderSnapPolicy.snapped(mark + 0.1) - mark) < 0.03)
            for boundary in [mark - 5, mark + 5] {
                check(abs(SliderSnapPolicy.snapped(boundary + 0.00001) - SliderSnapPolicy.snapped(boundary - 0.00001)) < 0.00003)
            }
        }
        // Off-center thumb grabs preserve the pointer/value mapping at different widths.
        for width in [210.0, 300] {
            for offset in [-8.0, 0, 8] {
                let geometry = SliderDragGeometry(minimumX: 12, maximumX: width - 12, grabOffset: offset)
                for value in [0.0, 10, 92, 108, 160] {
                    let pointer = 12 + (width - 24) * SliderScale.position(for: value) + offset
                    check(abs(geometry.percentage(at: pointer) - value) < 0.0001)
                }
                check(geometry.percentage(at: -100) == 0)
                check(geometry.percentage(at: width + 100) == 160)
            }
        }
        check(SliderScale.position(for: 100) == 0.65)
        check(SliderScale.percentage(at: 0.65) == 100)
        check(SliderScale.position(for: 0) == 0)
        check(SliderScale.position(for: 160) == 1)
        for percentage in [0.0, 10, 50, 96, 100, 104, 120, 160] {
            check(abs(SliderScale.percentage(at: SliderScale.position(for: percentage)) - percentage) < 0.0001)
        }
        for value in [0.0, 10, 50, 100] {
            check(abs(SliderScale.percentage(at: SliderScale.position(for: value, supportsBoost: false), supportsBoost: false) - value) < 0.0001)
        }
        check(SliderScale.position(for: 100, supportsBoost: false) == 1)
        check(SliderScale.position(for: 160, supportsBoost: false) == 1)
        check(SliderScale.position(for: -10, supportsBoost: false) == 0)
        check(SliderScale.percentage(at: 2, supportsBoost: false) == 100)
        check(SliderScale.percentage(at: -1, supportsBoost: false) == 0)
        print("PASS: \(checks) slider snap and pointer geometry checks")
    }
}
