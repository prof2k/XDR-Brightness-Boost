import AppKit

@MainActor
enum StatusItemImage {
    // Reassigning an unchanged status image invalidates AppKit's menu-bar
    // replicas. Their appearance callbacks can then request the same image
    // again, creating a continuous redraw loop.
    @discardableResult
    static func update(_ button: NSButton, image: NSImage?) -> Bool {
        guard button.image !== image else { return false }
        button.image = image
        return true
    }
}
