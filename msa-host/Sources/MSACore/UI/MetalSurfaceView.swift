import AppKit
import Metal
import QuartzCore

public final class MetalSurfaceView: NSView {
    private var metalLayer: CAMetalLayer?
    private var currentImage: CGImage?
    private var trackingArea: NSTrackingArea?
    private let renderer: MetalRenderer? = MetalRenderer.shared

    public var onMouseEvent: ((PointerEventType, Double, Double, UInt32) -> Void)?
    public var onKeyEvent: ((UInt32, Bool) -> Void)?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayer()
    }

    private func setupLayer() {
        wantsLayer = true
        let layer = CAMetalLayer()
        layer.device = renderer?.device ?? MTLCreateSystemDefaultDevice()
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        self.metalLayer = layer
        self.layer = layer
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea = trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        self.trackingArea = area
    }

    /// Primary GPU render path via Metal hardware acceleration
    public func renderGPU(pixelData: Data, width: Int, height: Int, stride: Int, format: WaylandShmFormat = .xbgr8888) {
        guard let layer = self.metalLayer, let renderer = self.renderer else {
            return
        }

        let success = renderer.render(
            pixelData: pixelData,
            width: width,
            height: height,
            stride: stride,
            format: format,
            to: layer
        )

        if !success {
            // Fallback to CGImage blit if Metal presentation fails
            let fallbackBuffer = WaylandBuffer(id: 0, width: width, height: height, stride: stride, format: format, data: pixelData)
            renderFallback(buffer: fallbackBuffer)
        }
    }

    /// Render a Wayland buffer using the Metal GPU pipeline with software fallback
    public func render(buffer: WaylandBuffer) {
        if let layer = self.metalLayer, let renderer = self.renderer {
            let rendered = renderer.render(
                pixelData: buffer.pixelData,
                width: buffer.width,
                height: buffer.height,
                stride: buffer.stride,
                format: buffer.format,
                to: layer
            )
            if rendered { return }
        }

        renderFallback(buffer: buffer)
    }

    private func renderFallback(buffer: WaylandBuffer) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let cgImage = buffer.createCGImage() {
                self.currentImage = cgImage
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.layer?.contents = cgImage
                CATransaction.commit()
            }
        }
    }

    public override var acceptsFirstResponder: Bool {
        return true
    }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    // Mouse events
    private func localCoordinates(for event: NSEvent) -> (x: Double, y: Double) {
        let location = convert(event.locationInWindow, from: nil)
        // Flip Y for macOS coordinate system to standard Wayland top-left
        let flippedY = Double(bounds.height - location.y)
        return (Double(location.x), flippedY)
    }

    public override func mouseMoved(with event: NSEvent) {
        let (x, y) = localCoordinates(for: event)
        onMouseEvent?(.motion, x, y, 0)
    }

    public override func mouseDragged(with event: NSEvent) {
        let (x, y) = localCoordinates(for: event)
        let button = InputBridge.linuxButton(from: event)
        onMouseEvent?(.motion, x, y, button)
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let (x, y) = localCoordinates(for: event)
        let button = InputBridge.linuxButton(from: event)
        onMouseEvent?(.buttonDown, x, y, button)
    }

    public override func mouseUp(with event: NSEvent) {
        let (x, y) = localCoordinates(for: event)
        let button = InputBridge.linuxButton(from: event)
        onMouseEvent?(.buttonUp, x, y, button)
    }

    public override func rightMouseDown(with event: NSEvent) {
        let (x, y) = localCoordinates(for: event)
        let button = InputBridge.linuxButton(from: event)
        onMouseEvent?(.buttonDown, x, y, button)
    }

    public override func rightMouseUp(with event: NSEvent) {
        let (x, y) = localCoordinates(for: event)
        let button = InputBridge.linuxButton(from: event)
        onMouseEvent?(.buttonUp, x, y, button)
    }

    public override func scrollWheel(with event: NSEvent) {
        let (x, y) = localCoordinates(for: event)
        onMouseEvent?(.scroll(deltaX: Double(event.scrollingDeltaX), deltaY: Double(event.scrollingDeltaY)), x, y, 0)
    }

    // Keyboard events
    public override func keyDown(with event: NSEvent) {
        let keycode = InputBridge.linuxKeycode(from: event.keyCode)
        onKeyEvent?(keycode, true)
    }

    public override func keyUp(with event: NSEvent) {
        let keycode = InputBridge.linuxKeycode(from: event.keyCode)
        onKeyEvent?(keycode, false)
    }
}
