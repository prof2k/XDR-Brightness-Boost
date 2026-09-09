import AppKit
import SwiftUI

@MainActor
private final class PreviewHoverView: NSView {
    var hoverChanged: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { hoverChanged?(false) }
}

@MainActor
private final class PreviewPanel: NSPanel {
    var onResignKey: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func resignKey() { super.resignKey(); onResignKey?() }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class PillValue: ObservableObject {
    @Published var percentage = 100
    @Published var nits = 500
    @Published var showsNits = true
}

private struct PillText: View {
    @ObservedObject var value: PillValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 3) {
            CompatibleNumericText(text: "\(value.percentage)%", value: Double(value.percentage))
            if value.showsNits {
                Text("•")
                CompatibleNumericText(text: "\(value.nits) nits", value: Double(value.nits))
            }
        }
        .font(Font(NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)))
        .foregroundColor(value.percentage > 100 ? Color.white : Color(NSColor.secondaryLabelColor))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Capsule().fill(value.percentage > 100 ? Color(NSColor.systemBlue) : Color.primary.opacity(0.08)))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18))
    }
}

@MainActor
private final class BrightnessPill: NSView {
    private let model = PillValue()
    func setShowsNits(_ shows: Bool) { model.showsNits = shows; invalidateIntrinsicContentSize() }
    override init(frame: NSRect) {
        super.init(frame: frame)
        let host = NSHostingView(rootView: PillText(value: model))
        if #available(macOS 13, *) { host.sizingOptions = [] }
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        addSubview(host)
    }
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    override var intrinsicContentSize: NSSize {
        let text = model.showsNits ? "\(model.percentage)% • \(model.nits) nits" : "\(model.percentage)%"
        return NSSize(width: ceil(text.size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)]).width) + 12, height: 19)
    }
    func update(_ percentage: Double, animated: Bool) {
        let percent = Int(percentage.rounded())
        let nits = Int(ControlPolicy.nits(forPercentage: percentage) ?? 0)
        let text = "\(percent)% • \(nits) nits"
        _ = text
        var transaction = Transaction()
        transaction.disablesAnimations = !animated
        withTransaction(transaction) { model.percentage = percent; model.nits = nits }
        invalidateIntrinsicContentSize()
    }
}

/// The card and its close control share one material; only their shape differs.
@MainActor
private func previewGlass(content: NSView, cornerRadius: CGFloat) -> NSView {
    if #available(macOS 26, *) {
        let effect = NSGlassEffectView(frame: content.frame)
        effect.cornerRadius = cornerRadius
        effect.style = .clear
        effect.tintColor = NSColor.black.withAlphaComponent(0.22)
        if #available(macOS 27, *) { effect.effectIsInteractive = true }
        effect.contentView = content
        return effect
    } else {
        let effect = NSVisualEffectView(frame: content.frame)
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.masksToBounds = true
        content.autoresizingMask = [.width, .height]
        effect.addSubview(content)
        return effect
    }
}

/// App-owned brightness HUD, shown only in response to captured keys.
@MainActor
final class BrightnessPreview: NSObject {
    var onBrightnessChanged: ((Double) -> Void)?
    private var hovering = false
    private var popupSize = NSSize.zero
    private let panel = PreviewPanel(contentRect: NSRect.zero,
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let slider = BrightnessSlider(value: 0.65, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let value = BrightnessPill(frame: .zero)
    private let close = NSButton()
    private let title = NSTextField(labelWithString: "Display")
    private var brightIcon: NSImageView?
    private var targetDisplay: UInt32 = 0
    func hide() { dismissal?.invalidate(); slider.cancelAnimation(); generation += 1; panel.orderOut(nil) }
    private var dismissal: Timer?
    private var generation = 0

    func applyMarkerPreference() {
        slider.applyMarkerPreference()
    }

    override init() {
        super.init()
        slider.applyMarkerPreference()
        panel.onResignKey = { [weak self] in self?.dismiss() }
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let root = PreviewHoverView(frame: NSRect.zero)
        panel.contentView = root
        let content = NSView(frame: .zero)
        let glass = previewGlass(content: content, cornerRadius: 27)
        root.addSubview(glass)
        title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        value.toolTip = "Estimated luminance, not a measured panel reading"
        let header = NSStackView(views: [title, value, NSView()])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 5
        title.setContentHuggingPriority(.required, for: .horizontal)
        value.setContentHuggingPriority(.required, for: .horizontal)
        var icons: [NSImageView] = []
        for name in ["sun.min.fill", "sun.max.fill"] {
            let image = NSImageView()
            image.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            if name == "sun.max.fill", let url = Bundle.main.url(forResource: "brightness-active", withExtension: "svg") {
                image.image = NSImage(contentsOf: url)
            } else { image.contentTintColor = .labelColor }
            image.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([image.widthAnchor.constraint(equalToConstant: 16), image.heightAnchor.constraint(equalToConstant: 16)])
            if name == "sun.max.fill" { brightIcon = image }
            icons.append(image)
        }
        slider.controlSize = .regular
        slider.trackFillColor = .labelColor
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.setAccessibilityLabel("Brightness, 0 to 160 percent")
        let sliderRow = NSStackView(views: [icons[0], slider, icons[1]])
        sliderRow.orientation = .horizontal
        sliderRow.alignment = .centerY
        sliderRow.spacing = 6
        let rows = NSStackView(views: [header, sliderRow])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 4
        rows.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(rows)
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: 290),
            rows.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            rows.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            rows.topAnchor.constraint(equalTo: content.topAnchor, constant: 11),
            rows.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
            header.widthAnchor.constraint(equalTo: rows.widthAnchor),
            sliderRow.widthAnchor.constraint(equalTo: rows.widthAnchor),
            slider.heightAnchor.constraint(equalToConstant: 26),
        ])
        let fitted = content.fittingSize
        popupSize = NSSize(width: fitted.width + 16, height: fitted.height + 20)
        root.frame = NSRect(origin: .zero, size: popupSize)
        glass.frame = NSRect(origin: NSPoint(x: 8, y: 8), size: fitted)
        content.frame = NSRect(origin: .zero, size: fitted)
        content.layoutSubtreeIfNeeded()
        // System HUD reference at 2x: a 36 px button, centered 14 px inward
        // from each top-left edge. Keep the geometry relative to the fitted card.
        let closeDiameter: CGFloat = 18
        let closeInset: CGFloat = 7
        let closeContent = NSView(frame: NSRect(x: 0, y: 0, width: closeDiameter, height: closeDiameter))
        close.frame = closeContent.bounds
        close.autoresizingMask = [.width, .height]
        close.title = ""
        close.imagePosition = .imageOnly
        close.isBordered = false
        close.contentTintColor = .labelColor
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close brightness popup")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .regular))
        close.imageScaling = .scaleProportionallyDown
        close.controlSize = .mini
        close.target = self
        close.action = #selector(dismiss)
        closeContent.addSubview(close)
        let closeGlass = previewGlass(content: closeContent, cornerRadius: closeDiameter / 2)
        closeGlass.frame = NSRect(x: glass.frame.minX + closeInset - closeDiameter / 2,
                                 y: glass.frame.maxY - closeInset - closeDiameter / 2,
                                 width: closeDiameter, height: closeDiameter)
        closeGlass.alphaValue = 0
        root.addSubview(closeGlass)
        root.hoverChanged = { [weak self, weak closeGlass] hovering in
            guard let self else { return }
            self.hovering = hovering
            self.dismissal?.invalidate()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                closeGlass?.animator().alphaValue = hovering ? 1 : 0
            }
            if !hovering { self.scheduleDismissal() }
        }
    }

    func show(near anchor: NSRect, screen: NSScreen, percentage: Double, supportsBoost: Bool, controllable: Bool) {
        if targetDisplay != screen.brightnessDisplayID { hide() }
        targetDisplay = screen.brightnessDisplayID
        title.stringValue = NSScreen.screens.count == 1 ? "Display" : screen.localizedName
        slider.supportsBoost = supportsBoost
        slider.isEnabled = controllable
        slider.setAccessibilityLabel(supportsBoost ? "Brightness, 0 to 160 percent" : "Brightness, 0 to 100 percent")
        value.setShowsNits(supportsBoost)
        brightIcon?.image = supportsBoost ? Bundle.main.url(forResource: "brightness-active", withExtension: "svg").flatMap { NSImage(contentsOf: $0) } : NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: nil)
        brightIcon?.contentTintColor = supportsBoost ? nil : .labelColor
        generation += 1
        dismissal?.invalidate()
        slider.applyMarkerPreference()
        if panel.isVisible { slider.animatePercentage(to: min(160, max(0, percentage))) }
        else { slider.percentage = min(160, max(0, percentage)) }
        changed()
        if panel.isVisible && panel.alphaValue > 0.99 {
            if !hovering { scheduleDismissal() }
            return
        }
        let visible = screen.visibleFrame
        let x = min(visible.maxX - 314, max(visible.minX + 8, anchor.midX - 153))
        let destination = NSRect(x: x, y: visible.maxY - popupSize.height + 6, width: popupSize.width, height: popupSize.height)
        panel.setFrame(destination.offsetBy(dx: 0, dy: 7), display: false)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().setFrame(destination, display: true)
            panel.animator().alphaValue = 1
        }
        scheduleDismissal()
    }

    @objc private func sliderChanged() {
        changed()
        onBrightnessChanged?(slider.percentage)
    }

    @objc private func changed() {
        value.update(slider.animationTarget ?? slider.percentage, animated: panel.isVisible)
        slider.refreshMarkers()
    }
    private func scheduleDismissal() {
        dismissal?.invalidate()
        dismissal = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }
    }
    @objc private func dismiss() {
        dismissal?.invalidate()
        generation += 1
        let token = generation
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
            panel.animator().setFrame(panel.frame.offsetBy(dx: 0, dy: 9), display: true)
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.panel.orderOut(nil)
            }
        }
    }
}
