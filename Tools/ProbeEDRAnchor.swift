import AppKit
import Metal
import QuartzCore

@MainActor
final class EDRAnchor {
    private let device = MTLCreateSystemDefaultDevice()
    private var window: NSPanel?
    private var layer: CAMetalLayer?
    private var queue: MTLCommandQueue?
    private var presented = false

    init() { queue = device?.makeCommandQueue() }

    func prepare() throws {
        guard window == nil else { return }
        guard let device, queue != nil, let screen = NSScreen.screens.first(where: {
            guard let number = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(number.uint32Value) != 0
        }) else { throw XDRFailure.message("The display’s HDR surface is unavailable.") }
        // Diagnostic visible one-point HDR trigger; never part of the installed app.
        let panel = NSPanel(contentRect: NSRect(x: screen.frame.minX + 4, y: screen.frame.maxY - 60, width: 1, height: 1), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let surface = CAMetalLayer()
        surface.device = device
        surface.pixelFormat = .rgba16Float
        surface.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        surface.wantsExtendedDynamicRangeContent = true
        surface.isOpaque = false
        surface.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        surface.contentsScale = screen.backingScaleFactor
        surface.drawableSize = CGSize(width: screen.backingScaleFactor, height: screen.backingScaleFactor)
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer = surface
        window = panel; layer = surface
    }

    func start() throws {
        guard !presented else { return }
        try prepare()
        guard let panel = window, let surface = layer, let queue else { throw XDRFailure.message("The HDR surface is unavailable.") }
        panel.orderFrontRegardless()
        presented = true
        CATransaction.flush()
        guard let drawable = surface.nextDrawable(), let command = queue.makeCommandBuffer() else {
            stop(); throw XDRFailure.message("The HDR surface could not be presented.")
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 1.6, green: 1.6, blue: 1.6, alpha: 1)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            stop(); throw XDRFailure.message("The HDR surface could not be initialized.")
        }
        encoder.endEncoding()
        command.present(drawable)
        command.commit()
    }

    func stop() {
        window?.orderOut(nil)
        presented = false
    }
}
