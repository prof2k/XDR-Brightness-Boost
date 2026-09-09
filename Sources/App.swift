import AppKit
import Darwin
import QuartzCore
import ServiceManagement

// Retained for future reconsideration; the setting and saved preference are inactive.
private enum BrightnessMarksFeature {
    static let isEnabled = false
    static var alwaysVisible: Bool {
        isEnabled && (UserDefaults.standard.object(forKey: "alwaysShowBrightnessMarks") as? Bool ?? true)
    }
}

@MainActor
final class SliderMarkers: NSView {
    var supportsBoost = true
    var percentage: Double = 0 { didSet { updateMarkers() } }
    var emphasizesMarks = false { didSet { updateMarkers() } }
    var track = NSRect.zero
    var thumbCenter = NSPoint.zero
    private var dots: [CALayer] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for _ in SliderSnapPolicy.marks {
            let dot = CALayer()
            dot.backgroundColor = NSColor.systemBlue.cgColor
            layer?.addSublayer(dot)
            dots.append(dot)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func updateMarkers() {
        guard track.width > 0 else { return }
        for (index, mark) in SliderSnapPolicy.marks.enumerated() {
            let emphasis: CGFloat = emphasizesMarks && abs(percentage - mark) <= SliderSnapPolicy.radius ? 1 : 0
            let dot = dots[index]
            dot.isHidden = !supportsBoost && mark == 100
            let size = CGSize(width: 5 + 13 * emphasis, height: 3 + 11 * emphasis)
            let previous = dot.presentation()
            let oldBounds = previous?.bounds ?? dot.bounds
            let oldRadius = previous?.cornerRadius ?? dot.cornerRadius
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            dot.position = CGPoint(x: track.minX + track.width * CGFloat(supportsBoost ? SliderScale.position(for: mark) : mark / 100), y: track.midY)
            dot.bounds = CGRect(origin: .zero, size: size)
            dot.cornerRadius = size.height / 2
            CATransaction.commit()
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                for (key, from, to) in [("bounds", NSValue(rect: oldBounds), NSValue(rect: dot.bounds)),
                                        ("cornerRadius", NSNumber(value: Double(oldRadius)), NSNumber(value: Double(dot.cornerRadius)))] {
                    let animation = CABasicAnimation(keyPath: key)
                    animation.fromValue = from
                    animation.toValue = to
                    animation.duration = 0.12
                    animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    dot.add(animation, forKey: key)
                }
            }
        }
    }
}

@MainActor
final class IconLabelButton: NSButton {
    var symbolName = "gearshape"
    var symbolSize: CGFloat = 9
    var resourceIcon: NSImage?
    var mirrorsResourceIcon = false
    var pill = false
    var alignsContentLeading = false
    private var iconGap: CGFloat { title.isEmpty ? 0 : pill ? 2 : 3 }
    private var ink: NSColor { contentTintColor ?? .secondaryLabelColor }
    private var textAttributes: [NSAttributedString.Key: Any] {
        [.font: font ?? .systemFont(ofSize: 11), .foregroundColor: ink]
    }
    override var intrinsicContentSize: NSSize {
        let text = title.size(withAttributes: textAttributes)
        return NSSize(width: symbolSize + iconGap + text.width + (pill ? 10 : 0),
                      height: max(symbolSize, text.height) + (pill ? 2 : 0))
    }
    override func draw(_ dirtyRect: NSRect) {
        if pill {
            NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.16 : 0.08).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        }
        let text = title.size(withAttributes: textAttributes)
        let width = symbolSize + iconGap + text.width
        let x = alignsContentLeading ? bounds.minX : bounds.midX - width / 2
        var configuration = NSImage.SymbolConfiguration(pointSize: symbolSize, weight: .regular)
        if #available(macOS 12, *) { configuration = configuration.applying(.init(paletteColors: [ink])) }
        let image: NSImage?
        if let resourceIcon {
            let color = ink
            let mirrored = mirrorsResourceIcon
            image = NSImage(size: NSSize(width: symbolSize, height: symbolSize), flipped: false) { rect in
                NSGraphicsContext.saveGraphicsState()
                if mirrored {
                    let transform = NSAffineTransform()
                    transform.translateX(by: rect.minX + rect.maxX, yBy: 0)
                    transform.scaleX(by: -1, yBy: 1)
                    transform.concat()
                }
                resourceIcon.draw(in: rect)
                NSGraphicsContext.restoreGraphicsState()
                color.setFill()
                rect.fill(using: .sourceIn)
                return true
            }
        } else {
            image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        }
        image?.draw(in: NSRect(x: x, y: bounds.midY - symbolSize / 2, width: symbolSize, height: symbolSize),
                    from: .zero, operation: .sourceOver, fraction: isHighlighted && !pill ? 0.7 : 1,
                    respectFlipped: true, hints: nil)
        title.draw(at: NSPoint(x: x + symbolSize + iconGap, y: bounds.midY - text.height / 2), withAttributes: textAttributes)
    }
}

@MainActor
final class BrightnessSlider: NSSlider {
    var supportsBoost = true
    var onInteraction: (() -> Void)?
    private var trackingMarkers: SliderMarkers?
    private var dragGeometry: SliderDragGeometry?
    var isTrackingPointer: Bool { dragGeometry != nil }
    private var markerTimeout: Timer?
    func applyMarkerPreference() {
        markerTimeout?.invalidate()
        showsPersistentMarkers = BrightnessMarksFeature.alwaysVisible
    }
    func showAdjustmentMarkers() {
        markerTimeout?.invalidate()
        showsPersistentMarkers = true
        markerTimeout = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.showsPersistentMarkers = BrightnessMarksFeature.alwaysVisible }
        }
    }
    var showsPersistentMarkers = false {
        didSet {
            if !showsPersistentMarkers && !isTrackingPointer {
                trackingMarkers?.removeFromSuperview()
                trackingMarkers = nil
            }
            if showsPersistentMarkers && trackingMarkers == nil {
                let markers = SliderMarkers(frame: bounds)
                markers.autoresizingMask = [.width, .height]
                markers.setAccessibilityElement(false)
                addSubview(markers)
                trackingMarkers = markers
            }
            refreshMarkers()
        }
    }
    override func layout() { super.layout(); refreshMarkers() }

    func cancelAnimation() { thumbTimer?.invalidate(); thumbTimer = nil; animationTarget = nil }
    private var thumbTimer: Timer?
    private(set) var animationTarget: Double?
    func animatePercentage(to target: Double) {
        guard animationTarget != target else { return }
        thumbTimer?.invalidate()
        let from = percentage
        animationTarget = target
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            percentage = target; animationTarget = nil; return
        }
        let start = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let progress = min(1, (ProcessInfo.processInfo.systemUptime - start) / 0.08)
                self.percentage = from + (target - from) * progress
                if progress >= 1 { timer.invalidate(); self.animationTarget = nil }
            }
        }
        thumbTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    var percentage: Double {
        get { SliderScale.percentage(at: doubleValue, supportsBoost: supportsBoost) }
        set { doubleValue = SliderScale.position(for: newValue, supportsBoost: supportsBoost); refreshMarkers() }
    }

    override func accessibilityValue() -> Any? { percentage }
    override func accessibilityMinValue() -> Any? { 0.0 }
    override func accessibilityMaxValue() -> Any? { supportsBoost ? 160.0 : 100.0 }
    override func accessibilityValueDescription() -> String? { "\(Int(percentage.rounded())) percent" }

    override func setAccessibilityValue(_ value: Any?) {
        guard let value = value as? NSNumber, value.doubleValue.isFinite, (0...160).contains(value.doubleValue) else { return }
        percentage = value.doubleValue
        _ = sendAction(action, to: target)
    }

    override func accessibilityPerformIncrement() -> Bool {
        percentage = ControlPolicy.keyPercentage(percentage, direction: 1, fine: false, supportsBoost: supportsBoost)
        return sendAction(action, to: target)
    }

    override func accessibilityPerformDecrement() -> Bool {
        percentage = ControlPolicy.keyPercentage(percentage, direction: -1, fine: false, supportsBoost: supportsBoost)
        return sendAction(action, to: target)
    }

    private var nativeGeometry: (track: NSRect, knob: NSRect)? {
        guard let cell = cell as? NSSliderCell else { return nil }
        let knob = cell.knobRect(flipped: isFlipped)
        let bar = cell.barRect(flipped: isFlipped)
        guard knob.width > 0, bar.width > knob.width else { return nil }
        return (bar.insetBy(dx: knob.width / 2, dy: 0), knob)
    }

    func refreshMarkers() {
        guard let markers = trackingMarkers, let geometry = nativeGeometry else { return }
        markers.track = markers.convert(geometry.track, from: self)
        markers.thumbCenter = markers.convert(NSPoint(x: geometry.knob.midX, y: geometry.knob.midY), from: self)
        markers.supportsBoost = supportsBoost
        markers.emphasizesMarks = isTrackingPointer
        markers.percentage = percentage
    }

    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        if let geometry = dragGeometry, let window,
           !NSEvent.modifierFlags.contains(.option) {
            let pointer = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            // Read the pointer rather than the previously snapped value, so
            // small drag steps can still escape either edge of the snap zone.
            percentage = supportsBoost ? SliderSnapPolicy.snapped(geometry.percentage(at: Double(pointer.x))) : min(100, max(0, (Double(pointer.x) - geometry.grabOffset - geometry.minimumX) / (geometry.maximumX - geometry.minimumX) * 100))
            refreshMarkers()
        }
        return super.sendAction(action, to: target)
    }

    override func mouseDown(with event: NSEvent) {
        thumbTimer?.invalidate(); animationTarget = nil
        // Leave the native cell and its Liquid Glass rendering untouched.
        if let geometry = nativeGeometry {
            let pointer = convert(event.locationInWindow, from: nil)
            dragGeometry = SliderDragGeometry(minimumX: Double(geometry.track.minX), maximumX: Double(geometry.track.maxX),
                                              grabOffset: geometry.knob.contains(pointer) ? Double(pointer.x - geometry.knob.midX) : 0)
        }
        trackingMarkers?.removeFromSuperview()
        let markers = SliderMarkers(frame: bounds)
        markers.percentage = percentage
        trackingMarkers = markers
        markers.autoresizingMask = [.width, .height]
        markers.setAccessibilityElement(false)
        addSubview(markers)
        refreshMarkers()
        defer {
            if !showsPersistentMarkers { markers.removeFromSuperview(); trackingMarkers = nil }
            dragGeometry = nil
            refreshMarkers()
        }
        onInteraction?()
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        onInteraction?()
        super.keyDown(with: event)
    }
}

@MainActor
final class FixedPopoverPage: NSViewController {
    var pageHeight: CGFloat = 0
    override var preferredContentSize: NSSize {
        get { NSSize(width: 304, height: pageHeight) }
        set { pageHeight = newValue.height }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var worker: Process?
    private var input: FileHandle?
    private var output = Data()
    private var awaitingSliderSettlement = false
    private var heartbeat: Timer?
    private var statusItem: NSStatusItem!
    private var appearanceObservation: NSKeyValueObservation?
    private var actualBoosted = false
    private let externalBrightness = ExternalBrightnessController()
    private var selectedDisplay: UInt32 = 0
    private var popupDisplay: UInt32 = 0
    private var builtinState: [String: Any] = [:]
    private let displayPicker = RoundedDisplayPicker(frame: .zero, pullsDown: false)
    private var boostLabel: NSTextField?
    private let unsupportedIcon = NSImageView()
    private var displayObserver: NSObjectProtocol?
    private var externalPoll: Timer?
    private var selectedScreen: NSScreen? { NSScreen.screens.first { $0.brightnessDisplayID == selectedDisplay } }
    private var selectedIsBuiltin: Bool { selectedDisplay != 0 && CGDisplayIsBuiltin(selectedDisplay) != 0 }

    private let popover = NSPopover()
    private var popoverOutsideClickMonitor: Any?
    private let brightnessPreview = BrightnessPreview()
    private let toggle = NSSwitch()
    private let slider = BrightnessSlider(value: ControlPolicy.defaultPercentage, minValue: 0, maxValue: 160, target: nil, action: nil)
    private let percentageLabel = PercentageReadout()
    private let brightnessKeys = BrightnessKeys()
    private let keyBoostToggle = KeyBoostSwitch()
    private var keyBoostRow: NSView?
    private var keysCanEnableBoost: Bool {
        UserDefaults.standard.object(forKey: "keysCanEnableBoost") as? Bool ?? true
    }
    private let loginToggle = NSSwitch()
    private let marksToggle = NSSwitch()
    private var mainPage: NSViewController!
    private var brightnessRows: [NSView] = []
    private var displaySelectorRow: NSView?
    private var mainShowsSelector: Bool?
    private var settingsPage: NSViewController!
    private var settingsNoticeState: KeyAccessState?
    private var enabled = false
    private var quitting = false
    private var recoveryAttempted = false
    private var lastStatus = ""
    private var controlRevision = ControlRevision()
    private var lastXDRPercentage: Double = {
        for key in ["lastXDRBrightness", "lastRequestedBrightness"] {
            if let value = UserDefaults.standard.object(forKey: key) as? Double,
               value.isFinite, value > 100, value <= 160 { return value }
        }
        return 160
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        selectedDisplay = NSScreen.screens.first(where: { CGDisplayIsBuiltin($0.brightnessDisplayID) != 0 })?.brightnessDisplayID ?? NSScreen.screens.first?.brightnessDisplayID ?? 0
        externalBrightness.onSoftwareBrightness = { [weak self] id, factor in
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return }
            self?.send("dimExternal", extra: ["displayID": id, "displayUUID": CFUUIDCreateString(nil, uuid) as String, "factor": factor])
        }
        buildMenuBarControl()
        updateDisplayUI()
        displayObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.displaysChanged() }
        }
        externalPoll = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshExternalBrightness() }
        }
        brightnessPreview.onBrightnessChanged = { [weak self] percentage in
            guard let self else { return }
            guard self.selectedDisplay == self.popupDisplay, self.selectedScreen != nil else { return }
            self.slider.percentage = percentage
            self.sliderChanged()
        }
        brightnessKeys.onStep = { [weak self] direction, fine in self?.brightnessKey(direction: direction, fine: fine) }
        refreshKeys()
        launchWorker()
        heartbeat = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.send("heartbeat"); self?.refreshKeys() }
        }
        RunLoop.main.add(heartbeat!, forMode: .common)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !popover.isShown { showPopover() }
        return true
    }

    func applicationDidResignActive(_ notification: Notification) {
        popover.performClose(nil)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if enabled { brightnessKeys.connect(reclaim: true) }
    }

    private func buildMenuBarControl() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        updateMenuBarIcon()
        appearanceObservation = button.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                self.updateMenuBarIcon()
            }
        }
        button.target = self
        button.action = #selector(togglePopover)
        button.toolTip = "XDR Brightness"

        toggle.target = self
        toggle.action = #selector(toggled)
        toggle.controlSize = .small
        toggle.setAccessibilityLabel("Enable XDR boost")
        let toggleRow = settingRow("Enable XDR boost", control: toggle, fontSize: 13)
        boostLabel = toggleRow.subviews.compactMap { $0 as? NSTextField }.first
        unsupportedIcon.image = bundledIcon("boost-unsupported")
        unsupportedIcon.imageScaling = .scaleProportionallyDown
        unsupportedIcon.isHidden = true
        unsupportedIcon.setAccessibilityElement(false)
        unsupportedIcon.translatesAutoresizingMaskIntoConstraints = false
        toggleRow.addSubview(unsupportedIcon)
        if let boostLabel {
            boostLabel.setContentHuggingPriority(.required, for: .horizontal)
            NSLayoutConstraint.activate([
                unsupportedIcon.leadingAnchor.constraint(equalTo: boostLabel.trailingAnchor, constant: 6),
                unsupportedIcon.centerYAnchor.constraint(equalTo: boostLabel.centerYAnchor),
                unsupportedIcon.widthAnchor.constraint(equalToConstant: 13),
                unsupportedIcon.heightAnchor.constraint(equalToConstant: 13),
            ])
        }

        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.controlSize = .large
        slider.showsPersistentMarkers = BrightnessMarksFeature.alwaysVisible
        slider.minValue = 0
        slider.maxValue = 1
        slider.percentage = 100
        slider.onInteraction = { [weak self] in self?.brightnessKeys.connect(reclaim: true) }
        slider.isContinuous = true
        slider.setAccessibilityLabel("Brightness, 0 to 160 percent")
        slider.setAccessibilityHelp("100 percent is at 65 percent of the track. Gentle resistance within 5 percentage points of 10 and 100 percent. Option-drag for precise values.")
        slider.isEnabled = true
        slider.trackFillColor = .labelColor
        refreshPercentage()
        let sliderRow = NSStackView(views: [symbol("sun.min.fill", 13), slider, percentageLabel])
        sliderRow.orientation = .horizontal
        sliderRow.alignment = .centerY
        sliderRow.spacing = 5

        let settings = iconButton("Settings", symbol: "gearshape", action: #selector(showSettings))
        settings.symbolSize = 10
        settings.resourceIcon = bundledIcon("setting")
        let footer = horizontal([settings, NSView(), quitButton()])
        brightnessRows = [toggleRow, sliderRow, footer]
        displaySelectorRow = displaySelector()
        updateMainPageLayout()

        keyBoostToggle.controlSize = .small
        keyBoostToggle.target = self
        keyBoostToggle.action = #selector(keyBoostToggled)
        keyBoostToggle.state = keysCanEnableBoost ? .on : .off
        keyBoostToggle.setAccessibilityLabel("Keys can enable boost")
        keyBoostToggle.setAccessibilityHelp("Go above 100% while boost is off.")
        loginToggle.controlSize = .small
        loginToggle.target = self
        loginToggle.action = #selector(loginToggled)
        loginToggle.setAccessibilityLabel("Start on login")
        marksToggle.controlSize = .small
        marksToggle.target = self
        marksToggle.action = #selector(marksToggled)
        marksToggle.state = slider.showsPersistentMarkers ? .on : .off
        marksToggle.setAccessibilityLabel("Always show brightness marks")
        keyBoostRow = keyBoostSettingRow()
        updateSettingsPage(access: .checking)
        popover.contentViewController = mainPage
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
    }

    private func updateSettingsPage(access: KeyAccessState) {
        let noticeState = access.showsNotice ? access : nil
        guard settingsPage == nil || settingsNoticeState != noticeState, let keyBoostRow else { return }
        let showingSettings = settingsPage != nil && popover.contentViewController === settingsPage
        settingsNoticeState = noticeState
        var rows = [settingsHeader()]
        var heights: [CGFloat] = [22]
        if let noticeState {
            let notice = KeyAccessNotice(state: noticeState, target: self, action: #selector(keyAccessAction))
            rows.append(notice)
            heights.append(notice.fittingSize.height)
        }
        rows.append(keyBoostRow)
        heights.append(keyBoostRow.fittingSize.height)
        rows.append(settingRow("Start on login", control: loginToggle))
        heights.append(22)
        if BrightnessMarksFeature.isEnabled { rows.append(marksSettingRow()); heights.append(22) }
        settingsPage = page(rows: rows, heights: heights, gaps: Array(repeating: 12, count: rows.count - 1))
        if showingSettings {
            popover.contentViewController = settingsPage
            popover.contentSize = settingsPage.preferredContentSize
        }
    }

    private func horizontal(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        return stack
    }

    private func settingRow(_ title: String, control: NSView, fontSize: CGFloat = 12) -> NSView {
        let row = NSView()
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: fontSize, weight: fontSize == 13 ? .medium : .regular)
        label.lineBreakMode = .byClipping
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        for view in [label, control] {
            view.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(view)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -8),
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    @objc private func marksToggled() {
        let persistent = marksToggle.state == .on
        UserDefaults.standard.set(persistent, forKey: "alwaysShowBrightnessMarks")
        slider.applyMarkerPreference()
        brightnessPreview.applyMarkerPreference()
    }

    private func keyBoostSettingRow() -> NSView {
        let row = NSView()
        let title = NSTextField(labelWithString: "Keys can enable boost")
        title.font = .systemFont(ofSize: 12)
        let description = NSTextField(labelWithString: "Go above 100% while boost is off.")
        description.font = .systemFont(ofSize: 10)
        description.textColor = .secondaryLabelColor
        let text = NSStackView(views: [title, description])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        for view in [text, keyBoostToggle] {
            view.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(view)
        }
        NSLayoutConstraint.activate([
            text.topAnchor.constraint(equalTo: row.topAnchor),
            text.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            text.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: keyBoostToggle.leadingAnchor, constant: -8),
            keyBoostToggle.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            keyBoostToggle.centerYAnchor.constraint(equalTo: text.centerYAnchor),
        ])
        return row
    }

    @objc private func keyBoostToggled() {
        guard keyBoostToggle.isEnabled else { return }
        UserDefaults.standard.set(keyBoostToggle.state == .on, forKey: "keysCanEnableBoost")
    }

    private func marksSettingRow() -> NSView {
        let row = settingRow("Always show marks", control: marksToggle)
        let label = row.subviews.compactMap { $0 as? NSTextField }.first!
        label.setContentHuggingPriority(.required, for: .horizontal)
        let sample = BrightnessMarkSample()
        sample.trackHeight = { [weak self] in
            guard let slider = self?.slider, let cell = slider.cell as? NSSliderCell else { return 6 }
            return cell.barRect(flipped: slider.isFlipped).height
        }
        sample.translatesAutoresizingMaskIntoConstraints = false
        sample.setAccessibilityElement(false)
        row.addSubview(sample)
        NSLayoutConstraint.activate([
            sample.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6),
            sample.trailingAnchor.constraint(lessThanOrEqualTo: marksToggle.leadingAnchor, constant: -8),
            sample.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            sample.widthAnchor.constraint(equalToConstant: 28),
            sample.heightAnchor.constraint(equalToConstant: 18),
        ])
        return row
    }

    private func settingsHeader() -> NSView {
        let header = NSView()
        let back = iconButton("", symbol: "chevron.left", action: #selector(showBrightness))
        back.symbolSize = 10
        back.alignsContentLeading = true
        back.contentTintColor = .labelColor
        back.resourceIcon = bundledIcon("left-arrow")
        back.setAccessibilityLabel("Back to brightness")
        back.toolTip = "Back to brightness"
        let title = NSTextField(labelWithString: "Settings")
        title.font = .systemFont(ofSize: 11)
        title.textColor = .labelColor
        for view in [back, title] {
            view.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(view)
        }
        NSLayoutConstraint.activate([
            back.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            back.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            back.widthAnchor.constraint(equalToConstant: 20),
            back.heightAnchor.constraint(equalToConstant: 20),
            title.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            title.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ])
        return header
    }

    private func page(rows: [NSView], heights: [CGFloat], gaps: [CGFloat]? = nil) -> NSViewController {
        let spacing = gaps ?? Array(repeating: 16, count: rows.count - 1)
        let root = FixedPopoverPage()
        root.preferredContentSize = NSSize(width: 304, height: heights.reduce(0, +) + spacing.reduce(0, +) + 28)
        root.view = NSView(frame: NSRect(origin: .zero, size: root.preferredContentSize))
        var top = root.preferredContentSize.height - 14
        for (index, row) in rows.enumerated() {
            let height = heights[index]
            top -= height
            row.translatesAutoresizingMaskIntoConstraints = true
            row.frame = NSRect(x: 16, y: top, width: 272, height: height)
            row.autoresizingMask = [.width, .minYMargin]
            root.view.addSubview(row)
            if index < spacing.count { top -= spacing[index] }
        }
        return root
    }

    private func iconButton(_ title: String, symbol: String, action: Selector, pill: Bool = false) -> IconLabelButton {
        let button = IconLabelButton(title: title, target: self, action: action)
        button.symbolName = symbol
        button.symbolSize = 9
        button.pill = pill
        button.isBordered = false
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        button.contentTintColor = .secondaryLabelColor
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    private func quitButton() -> NSButton {
        let button = iconButton("Quit", symbol: "xmark", action: #selector(quit), pill: true)
        button.symbolSize = 7
        button.resourceIcon = bundledIcon("close")
        return button
    }

    private lazy var idleMenuIcon = makeMenuBarIcon("brightness-default")
    private lazy var activeMenuIcon = makeMenuBarIcon("brightness-active")
    private lazy var lightActiveMenuIcon = makeMenuBarIcon("brightness-active-light")

    private func makeMenuBarIcon(_ name: String) -> NSImage? {
        let image = bundledIcon(name)
        image?.size = NSSize(width: 18, height: 18)
        image?.isTemplate = name == "brightness-default"
        return image
    }

    private func updateMenuBarIcon() {
        guard let button = statusItem.button else { return }
        StatusItemImage.update(button, image: menuBarIcon(boosted: actualBoosted))
    }

    private func menuBarIcon(boosted: Bool) -> NSImage? {
        guard boosted else { return idleMenuIcon }
        let dark = statusItem.button?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark ? activeMenuIcon : lightActiveMenuIcon
    }

    private func bundledIcon(_ name: String) -> NSImage? {
        Bundle.main.url(forResource: name, withExtension: "svg").flatMap { NSImage(contentsOf: $0) }
    }

    private func updateMainPageLayout() {
        let showsSelector = NSScreen.screens.count > 1
        guard mainShowsSelector != showsSelector, let selector = displaySelectorRow else { return }
        let wasShowingMain = mainPage != nil && popover.contentViewController === mainPage
        selector.removeFromSuperview()
        let rows = showsSelector ? [selector] + brightnessRows : brightnessRows
        mainPage = page(rows: rows,
                        heights: showsSelector ? [20, 22, 28, 18] : [22, 28, 18],
                        gaps: showsSelector ? [10, 14, 14] : [14, 14])
        mainShowsSelector = showsSelector
        if wasShowingMain {
            popover.contentViewController = mainPage
            popover.contentSize = mainPage.preferredContentSize
        }
    }

    private func displaySelector() -> NSView {
        let container = NSView()
        displayPicker.controlSize = .small
        displayPicker.font = .systemFont(ofSize: 10, weight: .medium)
        displayPicker.bezelStyle = .rounded
        displayPicker.target = self
        displayPicker.action = #selector(displayPicked)
        displayPicker.setAccessibilityLabel("Choose display")
        displayPicker.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(displayPicker)
        NSLayoutConstraint.activate([
            displayPicker.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            displayPicker.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            displayPicker.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor),
        ])
        return container
    }
    @objc private func displayPicked() {
        guard let id = displayPicker.selectedItem?.representedObject as? NSNumber else { return }
        selectDisplay(id.uint32Value)
    }
    private func refreshDisplayPicker() {
        displayPicker.removeAllItems()
        for screen in NSScreen.screens {
            let item = NSMenuItem(title: screen.localizedName, action: nil, keyEquivalent: "")
            item.representedObject = NSNumber(value: screen.brightnessDisplayID)
            displayPicker.menu?.addItem(item)
            if screen.brightnessDisplayID == selectedDisplay { displayPicker.select(item) }
        }
        if displayPicker.numberOfItems == 0 { displayPicker.addItem(withTitle: "No display") }
        displayPicker.isEnabled = displayPicker.numberOfItems > 1
        (displayPicker.cell as? NSPopUpButtonCell)?.arrowPosition = NSScreen.screens.count > 1 ? .arrowAtCenter : .noArrow
        displayPicker.invalidateIntrinsicContentSize()
    }
    private func selectDisplay(_ id: UInt32) {
        guard id != selectedDisplay, NSScreen.screens.contains(where: { $0.brightnessDisplayID == id }) else { return }
        brightnessPreview.hide()
        slider.cancelAnimation()
        selectedDisplay = id
        awaitingSliderSettlement = false
        updateDisplayUI()
    }
    private func displaysChanged() {
        externalBrightness.displaysChanged()
        updateMainPageLayout()
        brightnessPreview.hide()
        if selectedScreen == nil { selectedDisplay = NSScreen.screens.first?.brightnessDisplayID ?? 0 }
        updateDisplayUI()
    }
    private func updateDisplayUI() {
        slider.cancelAnimation()
        slider.toolTip = nil
        refreshDisplayPicker()
        slider.supportsBoost = selectedIsBuiltin
        slider.setAccessibilityLabel(selectedIsBuiltin ? "Brightness, 0 to 160 percent" : "Brightness, 0 to 100 percent")
        boostLabel?.stringValue = selectedIsBuiltin ? "Enable XDR boost" : "XDR boost unsupported"
        toggle.isHidden = !selectedIsBuiltin
        unsupportedIcon.isHidden = selectedIsBuiltin
        toggle.isEnabled = selectedIsBuiltin && worker?.isRunning == true
        enabled = selectedIsBuiltin && (builtinState["boostEnabled"] as? Bool ?? false)
        toggle.state = enabled ? .on : .off
        if selectedIsBuiltin {
            slider.isEnabled = worker?.isRunning == true
            slider.percentage = builtinState["percentage"] as? Double ?? 100
        } else {
            let reading = externalBrightness.read(selectedDisplay)
            slider.isEnabled = reading != nil && CGDisplayIsInMirrorSet(selectedDisplay) == 0
            slider.percentage = reading ?? 0
            slider.toolTip = slider.isEnabled ? nil : "Independent brightness control is unavailable for this mirrored or disconnected display."
        }
        refreshPercentage()
    }
    private func refreshExternalBrightness() {
        externalBrightness.refreshPendingHardware()
        guard !selectedIsBuiltin, !slider.isTrackingPointer, slider.animationTarget == nil else { return }
        guard let reading = externalBrightness.read(selectedDisplay) else { slider.isEnabled = false; return }
        slider.isEnabled = CGDisplayIsInMirrorSet(selectedDisplay) == 0
        slider.percentage = reading
        refreshPercentage()
    }

    private func refreshPercentage() {
        slider.refreshMarkers()
        percentageLabel.setPercentage(Int(slider.percentage.rounded()), animated: popover.isShown)
    }

    @objc private func showBrightnessPreview() {
        guard let button = statusItem.button, let window = button.window, let screen = selectedScreen else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        popover.performClose(nil)
        popupDisplay = selectedDisplay
        brightnessPreview.show(near: anchor, screen: screen, percentage: slider.animationTarget ?? slider.percentage, supportsBoost: selectedIsBuiltin, controllable: slider.isEnabled)
    }

    @objc private func showSettings() {
        refreshKeys()
        refreshLogin()
        popover.contentViewController = settingsPage
        popover.contentSize = settingsPage.preferredContentSize
    }

    @objc private func showBrightness() {
        popover.contentViewController = mainPage
        popover.contentSize = mainPage.preferredContentSize
    }

    private func refreshLogin() {
        if #available(macOS 13, *) {
            loginToggle.state = SMAppService.mainApp.status == .enabled ? .on : .off
        } else {
            loginToggle.state = .off
            loginToggle.isEnabled = false
            loginToggle.toolTip = "On macOS 11–12, add the app in System Preferences → Users & Groups → Login Items."
        }
    }

    @objc private func loginToggled() {
        guard #available(macOS 13, *) else { return }
        do {
            if loginToggle.state == .on {
                if SMAppService.mainApp.status != .requiresApproval { try SMAppService.mainApp.register() }
                if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            } else { try SMAppService.mainApp.unregister() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not update start on login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        refreshLogin()
    }

    private func symbol(_ name: String, _ size: CGFloat) -> NSImageView {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        return NSImageView(image: image ?? NSImage())
    }

    @objc private func togglePopover() {
        popover.isShown ? popover.performClose(nil) : showPopover()
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        // Menu-bar replicas can share a status item. Prefer the clicked screen,
        // then reconcile with the actual popover window once AppKit places it.
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? button.window?.screen {
            selectDisplay(screen.brightnessDisplayID)
        }
        showBrightness()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if let screen = popover.contentViewController?.view.window?.screen {
            selectDisplay(screen.brightnessDisplayID)
        }
        configurePopoverWindow()
        popover.contentViewController?.view.window?.makeKey()
    }

    private func configurePopoverWindow() {
        guard let window = popover.contentViewController?.view.window else { return }
        window.hasShadow = false
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        // Do not let Show Desktop carry the popover to the screen edge.
        var behavior = window.collectionBehavior
        behavior.remove([.managed, .transient])
        behavior.insert(.stationary)
        window.collectionBehavior = behavior
    }

    func popoverDidShow(_ notification: Notification) {
        configurePopoverWindow()
        if let monitor = popoverOutsideClickMonitor { NSEvent.removeMonitor(monitor) }
        popoverOutsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.popover.performClose(nil) }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        if let monitor = popoverOutsideClickMonitor { NSEvent.removeMonitor(monitor) }
        popoverOutsideClickMonitor = nil
    }

    private func launchWorker(recoverOnly: Bool = false) {
        controlRevision = ControlRevision()
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/XDRBrightnessController.app/Contents/MacOS/XDRBrightnessController")
        let process = Process()
        process.executableURL = executable
        process.arguments = [recoverOnly ? "--recover" : "--worker"]
        let incoming = Pipe(), outgoing = Pipe()
        process.standardInput = incoming
        process.standardOutput = outgoing
        process.standardError = FileHandle.nullDevice
        outgoing.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            Task { @MainActor in self?.received(data) }
        }
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                guard let self else { return }
                if self.quitting {
                    if process.terminationStatus == 0 { NSApp.reply(toApplicationShouldTerminate: true) }
                    else { self.quitting = false; self.lastStatus = "Restoration needs attention. Reopen the app to retry recovery."; NSApp.reply(toApplicationShouldTerminate: false) }
                } else if process.terminationStatus != 0 && !self.recoveryAttempted {
                    self.recoveryAttempted = true
                    self.launchWorker(recoverOnly: true)
                } else {
                    self.enabled = false
                    self.brightnessKeys.controlsBrightness = false
                    if self.selectedIsBuiltin {
                        self.toggle.state = .off
                        self.slider.isEnabled = false
                        self.toggle.isEnabled = false
                    }
                    if recoverOnly && process.terminationStatus == 0 {
                        self.lastStatus = "Recovery completed. Restart the app to continue."
                    } else if self.lastStatus.isEmpty {
                        self.lastStatus = "Controller unavailable. Restart the app to retry."
                    }
                }
            }
        }
        do { try process.run(); worker = process; input = incoming.fileHandleForWriting }
        catch { lastStatus = error.localizedDescription; toggle.isEnabled = false }
    }

    private func received(_ data: Data) {
        guard !data.isEmpty else { return }
        output.append(data)
        while let newline = output.firstIndex(of: 10) {
            let line = output.prefix(upTo: newline)
            output.removeSubrange(...newline)
            guard let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let state = value["state"] as? String else { continue }
            if let requestID = value["requestID"] as? Int, !controlRevision.accepts(requestID) { continue }
            builtinState = value
            if let percentage = value["percentage"] as? Double {
                actualBoosted = percentage > 100
                updateMenuBarIcon()
            }
            guard selectedIsBuiltin else { continue }
            enabled = value["boostEnabled"] as? Bool ?? false
            if !slider.isTrackingPointer { setBoostToggle(enabled) }
            brightnessKeys.controlsBrightness = brightnessKeys.isAvailable
            slider.isEnabled = worker?.isRunning == true
            toggle.isEnabled = slider.isEnabled
            let text = value["message"] as? String ?? ""
            lastStatus = text
            toggle.setAccessibilityHelp(state == "error" ? text : nil)
            if let percentage = value["percentage"] as? Double {
                if enabled, let requested = value["requestedPercentage"] as? Double { remember(requested) }
                // Live readback drives the UI; requested brightness is separate
                // so external changes and boost-off cannot erase the next target.
                if value["ramping"] as? Bool != true { awaitingSliderSettlement = false }
                // Pointer intent owns the thumb until its command settles.
                // Intermediate hardware readbacks must never pull a drag backward.
                if !slider.isTrackingPointer && !awaitingSliderSettlement {
                    slider.percentage = percentage
                    refreshPercentage()
                }
                actualBoosted = percentage > 100
                updateMenuBarIcon()
            }

        }
    }

    private func send(_ command: String, extra: [String: Any] = [:]) {
        guard let input, worker?.isRunning == true else { return }
        if command != "heartbeat" && command != "dimExternal" { _ = controlRevision.advance() }
        var payload: [String: Any] = ["command": command, "requestID": controlRevision.value]
        if command == "set" { payload["percentage"] = slider.percentage }
        payload.merge(extra) { _, newer in newer }
        guard var data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        data.append(10)
        _ = data.withUnsafeBytes { Darwin.write(input.fileDescriptor, $0.baseAddress, $0.count) }
    }

    private func refreshKeys() {
        brightnessKeys.connect()
        let active = brightnessKeys.isAvailable
        keyBoostToggle.setAvailable(active)
        let opacity: CGFloat = active ? 1.0 : 0.45
        if keyBoostRow?.alphaValue != opacity { keyBoostRow?.alphaValue = opacity }
        brightnessKeys.controlsBrightness = active
        updateSettingsPage(access: brightnessKeys.accessState)
    }

    private func brightnessKey(direction: Int, fine: Bool) {
        guard brightnessKeys.isAvailable else { return }
        if !popover.isShown, let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) { selectDisplay(screen.brightnessDisplayID) }
        guard slider.isEnabled else { return }
        if !selectedIsBuiltin {
            let next = ControlPolicy.keyPercentage(slider.animationTarget ?? slider.percentage, direction: direction, fine: fine, supportsBoost: false)
            if externalBrightness.write(next, to: selectedDisplay) { slider.animatePercentage(to: next); refreshPercentage() }
            else { slider.isEnabled = false }
            if !popover.isShown || popover.contentViewController === settingsPage { showBrightnessPreview() }
            return
        }
        slider.showAdjustmentMarkers()
        let next = ControlPolicy.keyTarget(slider.animationTarget ?? slider.percentage, direction: direction, fine: fine, supportsBoost: true, boostEnabled: enabled, allowBoostActivation: keysCanEnableBoost)
        enabled = next.boostEnabled
        setBoostToggle(enabled)
        slider.animatePercentage(to: next.percentage)
        awaitingSliderSettlement = true
        refreshPercentage()
        remember(next.percentage)
        send("adjust", extra: ["direction": direction, "fine": fine, "allowBoostActivation": keysCanEnableBoost])
        if !popover.isShown || popover.contentViewController === settingsPage { showBrightnessPreview() }
    }

    @objc private func keyAccessAction() {
        let needsPermission = brightnessKeys.accessState == .permissionRequired
        brightnessKeys.connect(prompt: needsPermission, reclaim: true)
        if needsPermission, !brightnessKeys.isAvailable,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        refreshKeys()
    }

    private func setBoostToggle(_ on: Bool) {
        let state: NSControl.StateValue = on ? .on : .off
        guard toggle.state != state else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
            context.allowsImplicitAnimation = true
            toggle.animator().state = state
        }
    }

    @objc private func toggled() {
        guard selectedIsBuiltin else { return }
        if toggle.state == .on { brightnessKeys.connect(reclaim: true) }
        brightnessKeys.controlsBrightness = brightnessKeys.isAvailable
        if toggle.state == .on {
            send("enable", extra: ["percentage": lastXDRPercentage])
        } else {
            send("disable")
        }
    }

    private func remember(_ value: Double) {
        guard value.isFinite, value > 100, value <= 160 else { return }
        guard lastXDRPercentage != value || UserDefaults.standard.object(forKey: "lastXDRBrightness") == nil else { return }
        lastXDRPercentage = value
        UserDefaults.standard.set(value, forKey: "lastXDRBrightness")
    }

    @objc private func sliderChanged() {
        guard selectedScreen != nil else { return }
        if !selectedIsBuiltin {
            if !externalBrightness.write(slider.percentage, to: selectedDisplay) { slider.isEnabled = false }
            refreshPercentage()
            return
        }
        awaitingSliderSettlement = true
        refreshPercentage()
        if !enabled { brightnessKeys.connect(reclaim: true) }
        enabled = enabled || slider.percentage > 100
        setBoostToggle(enabled)
        brightnessKeys.controlsBrightness = brightnessKeys.isAvailable
        remember(slider.percentage)
        send("set", extra: ["activate": enabled])
    }

    @objc private func quit() { NSApp.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) { brightnessKeys.disconnect(); externalBrightness.close() }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard worker?.isRunning == true else { return .terminateNow }
        quitting = true
        send("quit")
        return .terminateLater
    }
}

@main
struct XDRMain {
    @MainActor static func main() {
        signal(SIGPIPE, SIG_IGN)
        if CommandLine.arguments.contains("--recover-native") {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            app.finishLaunching()
            let controller = BrightnessWorker()
            controller.start(recoverOnly: true)
        } else if CommandLine.arguments.contains("--worker") || CommandLine.arguments.contains("--recover") {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            app.finishLaunching()
            let controller = ColorBrightnessWorker()
            controller.start(recoverOnly: CommandLine.arguments.contains("--recover"))
            withExtendedLifetime(controller) { RunLoop.main.run() }
        } else {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let delegate = AppDelegate()
            app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
        }
    }
}

@MainActor
private final class BrightnessMarkSample: NSView {
    var trackHeight: () -> CGFloat = { 6 }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let pill = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        pill.addClip()
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        pill.fill()
        NSColor.labelColor.setFill()
        let height = max(1, trackHeight())
        NSBezierPath(rect: NSRect(x: 0, y: bounds.midY - height / 2, width: bounds.width, height: height)).fill()
        NSColor.systemBlue.setFill()
        NSBezierPath(roundedRect: NSRect(x: bounds.midX - 2.5, y: bounds.midY - 1.5, width: 5, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
    }
}


@MainActor
private final class DisplaySelectorSurface: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }
}


@MainActor
private final class RoundedDisplayPicker: NSPopUpButton {
    private lazy var backIcon = Bundle.main.url(forResource: "left-arrow", withExtension: "svg").flatMap { NSImage(contentsOf: $0) }
    override var intrinsicContentSize: NSSize {
        let text = titleOfSelectedItem ?? "Display"
        let width = text.size(withAttributes: [.font: font ?? .systemFont(ofSize: 10, weight: .medium)]).width
        return NSSize(width: ceil(width) + 36, height: 22)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.16 : 0.08).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingMiddle
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? .systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        let text = titleOfSelectedItem ?? "Display"
        let height = text.size(withAttributes: attributes).height
        text.draw(in: NSRect(x: 10, y: bounds.midY - height / 2, width: max(0, bounds.width - 30), height: height), withAttributes: attributes)
        if let backIcon {
            let downIcon = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
                NSGraphicsContext.saveGraphicsState()
                let transform = NSAffineTransform()
                transform.translateX(by: rect.midX, yBy: rect.midY)
                transform.rotate(byDegrees: 90)
                transform.concat()
                backIcon.draw(in: NSRect(x: -4, y: -4, width: 8, height: 8))
                NSGraphicsContext.restoreGraphicsState()
                NSColor.labelColor.setFill()
                rect.fill(using: .sourceIn)
                return true
            }
            downIcon.draw(in: NSRect(x: bounds.maxX - 17, y: bounds.midY - 4, width: 8, height: 8))
        }
    }
}
