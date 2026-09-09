import AppKit

@MainActor
private final class ObservedButton: NSButton {
    var assignments = 0
    var didAssignImage: (() -> Void)?
    override var image: NSImage? {
        didSet { assignments += 1; didAssignImage?() }
    }
}

@main
enum StatusItemImageTests {
    @MainActor static func main() {
        let button = ObservedButton()
        let idle = NSImage(size: NSSize(width: 18, height: 18))
        let boostedDark = NSImage(size: idle.size)
        let boostedLight = NSImage(size: idle.size)
        // Simulate the appearance notification caused by an image assignment.
        button.didAssignImage = { [weak button] in
            guard let button else { return }
            precondition(!StatusItemImage.update(button, image: button.image))
        }
        let initial = button.assignments
        precondition(StatusItemImage.update(button, image: idle))
        for _ in 0..<10_000 { precondition(!StatusItemImage.update(button, image: idle)) }
        precondition(button.assignments == initial + 1)
        for image in [boostedDark, boostedLight, boostedDark, idle] {
            precondition(StatusItemImage.update(button, image: image))
            precondition(button.image === image)
            precondition(!StatusItemImage.update(button, image: image))
        }
        precondition(button.assignments == initial + 5)
        precondition(StatusItemImage.update(button, image: nil))
        precondition(!StatusItemImage.update(button, image: nil))
        print("PASS: unchanged status images, appearance feedback, boost/appearance transitions, and nil image")
    }
}
