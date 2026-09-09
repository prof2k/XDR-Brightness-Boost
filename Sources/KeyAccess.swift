import AppKit
import CoreImage

enum KeyAccessState: Equatable {
    case checking, ready, permissionRequired, captureUnavailable

    static func resolve(tapAvailable: Bool, permissionGranted: Bool?) -> Self {
        if tapAvailable { return .ready }
        guard let permissionGranted else { return .checking }
        return permissionGranted ? .captureUnavailable : .permissionRequired
    }

    var showsNotice: Bool { self == .permissionRequired || self == .captureUnavailable }
}

@MainActor
final class KeyAccessNotice: NSView {
    let actionButton: NSButton

    init(state: KeyAccessState, target: AnyObject?, action: Selector?) {
        let needsPermission = state == .permissionRequired
        actionButton = NSButton(title: needsPermission ? "Open Settings" : "Retry", target: target, action: action)
        super.init(frame: .zero)
        let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .systemRed
        icon.setAccessibilityElement(false)
        let title = NSTextField(labelWithString: needsPermission ? "Allow brightness key control" : "Brightness keys are unavailable")
        title.font = .systemFont(ofSize: 11, weight: .medium)
        title.textColor = .systemRed
        let heading = NSStackView(views: [icon, title])
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.spacing = 6
        icon.widthAnchor.constraint(equalToConstant: 12).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 12).isActive = true
        let message = NSTextField(labelWithString: needsPermission
            ? "Give XDR Brightness Boost permission\nin System Settings."
            : "Permission is granted. Try reconnecting\nbrightness key control.")
        message.font = .systemFont(ofSize: 10)
        message.textColor = .secondaryLabelColor
        actionButton.isBordered = false
        actionButton.alignment = .left
        actionButton.font = .systemFont(ofSize: 11)
        actionButton.contentTintColor = .linkColor
        actionButton.setContentHuggingPriority(.required, for: .horizontal)
        let content = NSStackView(views: [heading, message, actionButton])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 4
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
final class KeyBoostSwitch: NSSwitch {
    // Filter the native control rather than replacing its drawing or changing
    // its saved on/off position just to obtain a gray disabled appearance.
    func setAvailable(_ available: Bool) {
        guard isEnabled != available else { return }
        isEnabled = available
        wantsLayer = true
        if available {
            contentFilters = []
        } else if let filter = CIFilter(name: "CIColorControls") {
            filter.setDefaults()
            filter.setValue(0, forKey: kCIInputSaturationKey)
            contentFilters = [filter]
        }
    }
}
