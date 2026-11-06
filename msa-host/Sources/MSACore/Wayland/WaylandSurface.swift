import Foundation

public protocol WaylandSurfaceObserver: AnyObject {
    func surfaceDidUpdateFrame(_ surface: WaylandSurface, buffer: WaylandBuffer)
    func surfaceDidUpdateTitle(_ surface: WaylandSurface, title: String)
    func surfaceDidClose(_ surface: WaylandSurface)
}

public final class WaylandSurface {
    public let id: UInt32
    public var width: CGFloat = 800
    public var height: CGFloat = 600
    public var appTitle: String? = "Android App"
    public var appId: String?
    public private(set) var currentBuffer: WaylandBuffer?

    public weak var observer: WaylandSurfaceObserver?
    public var onSendMessage: ((WaylandMessage) -> Void)?

    public init(id: UInt32) {
        self.id = id
    }

    public func attach(buffer: WaylandBuffer) {
        self.currentBuffer = buffer
    }

    public func commit() {
        if let buffer = currentBuffer {
            self.width = CGFloat(buffer.width)
            self.height = CGFloat(buffer.height)
            observer?.surfaceDidUpdateFrame(self, buffer: buffer)
        }
    }

    public func setTitle(_ title: String) {
        self.appTitle = title
        observer?.surfaceDidUpdateTitle(self, title: title)
    }

    public func setAppId(_ appId: String) {
        self.appId = appId
    }

    public func close() {
        observer?.surfaceDidClose(self)
    }

    public func requestResize(width: Int32, height: Int32) {
        self.width = CGFloat(width)
        self.height = CGFloat(height)
        // Send xdg_toplevel.configure event back to Android client
        // In full Wayland: xdg_toplevel.configure(width, height, states), followed by xdg_surface.configure(serial)
    }

    public func sendPointerEvent(type: PointerEventType, x: Double, y: Double, button: UInt32 = 0) {
        // Formats pointer motion / button event to client
    }

    public func sendKeyboardEvent(keyCode: UInt32, isDown: Bool) {
        // Formats wl_keyboard.key event to client
    }
}

public enum PointerEventType {
    case motion
    case buttonDown
    case buttonUp
    case scroll(deltaX: Double, deltaY: Double)
}
