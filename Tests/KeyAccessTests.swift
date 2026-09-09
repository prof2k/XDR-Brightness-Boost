import AppKit
import CoreImage

@main
enum KeyAccessTests {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        for permission: Bool? in [nil, false, true] {
            precondition(KeyAccessState.resolve(tapAvailable: true, permissionGranted: permission) == .ready,
                         "A working tap must override stale or unknown preflight results")
        }
        precondition(KeyAccessState.resolve(tapAvailable: false, permissionGranted: nil) == .checking)
        precondition(KeyAccessState.resolve(tapAvailable: false, permissionGranted: false) == .permissionRequired)
        precondition(KeyAccessState.resolve(tapAvailable: false, permissionGranted: true) == .captureUnavailable)
        precondition(!KeyAccessState.ready.showsNotice && !KeyAccessState.checking.showsNotice)

        let toggle = KeyBoostSwitch()
        toggle.controlSize = .small
        toggle.state = .on
        toggle.setAvailable(false)
        precondition(!toggle.isEnabled && toggle.state == .on)
        precondition(toggle.contentFilters.first?.value(forKey: kCIInputSaturationKey) as? NSNumber == 0)
        toggle.setAvailable(true)
        precondition(toggle.isEnabled && toggle.state == .on && toggle.contentFilters.isEmpty)
        toggle.state = .off
        toggle.setAvailable(false)
        toggle.setAvailable(true)
        precondition(toggle.state == .off, "Availability must not overwrite the saved choice")

        for state in [KeyAccessState.permissionRequired, .captureUnavailable] {
            let notice = KeyAccessNotice(state: state, target: nil, action: nil)
            precondition(notice.actionButton.title == (state == .permissionRequired ? "Open Settings" : "Retry"))
            let size = notice.fittingSize
            precondition(size.height > 0 && size.width <= 272, "Notice must fit the fixed popover width")
            notice.frame = NSRect(x: 0, y: 0, width: 272, height: size.height)
            notice.layoutSubtreeIfNeeded()
            precondition(notice.frame.width == 272)
        }
        print("PASS: permission/capture classification, stale-result precedence, grayscale and saved-state restoration, notice width and actions")

        // Visual fixture only: never creates an event tap or touches TCC.
        if CommandLine.arguments.contains("--preview") {
            let window = NSWindow(contentRect: NSRect(x: 200, y: 300, width: 304, height: 260),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "XDR key access preview"
            let material = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 304, height: 260))
            material.material = .popover
            material.state = .active
            window.contentView = material
            let permission = KeyAccessNotice(state: .permissionRequired, target: nil, action: nil)
            permission.frame = NSRect(x: 16, y: 184, width: 272, height: permission.fittingSize.height)
            material.addSubview(permission)
            let retry = KeyAccessNotice(state: .captureUnavailable, target: nil, action: nil)
            retry.frame = NSRect(x: 16, y: 98, width: 272, height: retry.fittingSize.height)
            material.addSubview(retry)
            toggle.state = .on
            toggle.setAvailable(false)
            toggle.frame = NSRect(x: 244, y: 38, width: 44, height: 22)
            toggle.alphaValue = 0.45
            material.addSubview(toggle)
            let label = NSTextField(labelWithString: "Keys can enable boost")
            label.font = .systemFont(ofSize: 12)
            label.alphaValue = 0.45
            label.frame = NSRect(x: 16, y: 41, width: 218, height: 16)
            material.addSubview(label)
            window.makeKeyAndOrderFront(nil)
            app.run()
        }
    }
}
