import Foundation
@main struct ExternalDimmingPolicyTests {
    static func main() {
        var count = 0
        func check(_ value: Bool) { precondition(value); count += 1 }
        for hardware in [true, false] {
            check(ExternalDimmingPolicy.opacity(percentage: 0, hardwareControlled: hardware) == 1)
            check(ExternalDimmingPolicy.opacity(percentage: 100, hardwareControlled: hardware) == 0)
            check(ExternalDimmingPolicy.opacity(percentage: -.infinity, hardwareControlled: hardware) == 0)
            check(ExternalDimmingPolicy.opacity(percentage: .nan, hardwareControlled: hardware) == 0)
            let values = (0...1000).map { ExternalDimmingPolicy.opacity(percentage: Double($0) / 10, hardwareControlled: hardware) }
            check(values.allSatisfy { (0...1).contains($0) })
            check(zip(values, values.dropFirst()).allSatisfy { $0 >= $1 && $0 - $1 < 0.006 })
        }
        check(ExternalDimmingPolicy.opacity(percentage: 20, hardwareControlled: true) == 0.8)
        check(ExternalDimmingPolicy.opacity(percentage: 10, hardwareControlled: true) == 0.9)
        check(ExternalDimmingPolicy.opacity(percentage: 50, hardwareControlled: false) == 0.5)
        print("PASS: \(count) external dimming endpoint, continuity, monotonicity and invalid-input checks")
    }
}
