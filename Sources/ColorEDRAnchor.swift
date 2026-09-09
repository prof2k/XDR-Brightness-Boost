import AppKit
import MetalKit

@MainActor
final class ColorEDRAnchor: NSObject, MTKViewDelegate {
    private var panel: NSPanel?
    private var surface: MTKView?
    private var queue: MTLCommandQueue?

    func start(screen: NSScreen) throws {
        if let panel { panel.orderFrontRegardless(); return }
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw XDRFailure.message("HDR rendering is unavailable.")
        }
        self.queue = queue
        let panel = NSPanel(contentRect: NSRect(x: screen.frame.minX + 2, y: screen.frame.maxY - 60, width: 1, height: 1),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = MTKView(frame: NSRect(x: 0, y: 0, width: 1, height: 1), device: device)
        view.colorPixelFormat = .rgba16Float
        view.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        view.autoResizeDrawable = false; view.drawableSize = CGSize(width: 1, height: 1)
        view.clearColor = MTLClearColor(red: 1.6, green: 1.6, blue: 1.6, alpha: 1)
        view.preferredFramesPerSecond = 5
        if let layer = view.layer as? CAMetalLayer { layer.wantsExtendedDynamicRangeContent = true; layer.isOpaque = false }
        view.delegate = self; panel.contentView = view
        self.panel = panel; surface = view
        panel.orderFrontRegardless(); view.draw()
    }

    func draw(in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let command = queue?.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.endEncoding(); command.present(drawable); command.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func stop() { surface?.isPaused = true; panel?.orderOut(nil); surface = nil; panel = nil; queue = nil }
}
