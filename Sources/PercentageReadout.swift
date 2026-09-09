import AppKit
import SwiftUI

@MainActor
private final class PercentageValue: ObservableObject {
    @Published var percentage = 160
}

// Keep numeric animation on modern systems without requiring it to launch.
struct CompatibleNumericText: View {
    let text: String
    let value: Double
    @ViewBuilder var body: some View {
        if #available(macOS 14, *) {
            Text(text).contentTransition(.numericText(value: value))
        } else {
            Text(text)
        }
    }
}

private struct PercentageText: View {
    @ObservedObject var value: PercentageValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        CompatibleNumericText(text: "\(value.percentage)%", value: Double(value.percentage))
            .font(Font(NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)))
            .foregroundColor(Color(NSColor.secondaryLabelColor))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .accessibilityLabel("\(value.percentage) percent")
    }
}

@MainActor
final class PercentageReadout: NSView {
    private let value = PercentageValue()

    init() {
        super.init(frame: .zero)
        let hosting = NSHostingView(rootView: PercentageText(value: value))
        if #available(macOS 13, *) { hosting.sizingOptions = [] }
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 34),
            heightAnchor.constraint(equalToConstant: 20),
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init()") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setPercentage(_ percentage: Int, animated: Bool) {
        guard value.percentage != percentage else { return }
        // Hidden/initial updates should already be settled when the menu opens.
        var transaction = Transaction()
        transaction.disablesAnimations = !animated
        withTransaction(transaction) { value.percentage = percentage }
    }
}
