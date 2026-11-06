import Foundation
import Virtualization

public protocol WaylandServerDelegate: AnyObject {
    func waylandServerDidCreateSurface(_ server: WaylandServer, surface: WaylandSurface)
    func waylandServerDidDestroySurface(_ server: WaylandServer, surface: WaylandSurface)
}

public final class WaylandServer: NSObject {
    public static let defaultPort: UInt32 = 5000
    private let port: UInt32
    private let socketListener = VZVirtioSocketListener()
    private var activeSessions: [WaylandClientSession] = []
    private var surfaces: [UInt32: WaylandSurface] = [:]
    private let surfaceLock = NSLock()
    public weak var delegate: WaylandServerDelegate?

    public init(port: UInt32 = WaylandServer.defaultPort) {
        self.port = port
        super.init()
        self.socketListener.delegate = self
    }

    public func attach(to socketDevice: VZVirtioSocketDevice) {
        socketDevice.setSocketListener(socketListener, forPort: port)
    }

    public func registerSurface(id: UInt32) -> WaylandSurface {
        surfaceLock.lock()
        defer { surfaceLock.unlock() }
        if let existing = surfaces[id] {
            return existing
        }
        let surface = WaylandSurface(id: id)
        surfaces[id] = surface
        return surface
    }

    public func notifyToplevelCreated(surface: WaylandSurface) {
        delegate?.waylandServerDidCreateSurface(self, surface: surface)
    }

    public func unregisterSurface(id: UInt32) {
        surfaceLock.lock()
        let surface = surfaces.removeValue(forKey: id)
        surfaceLock.unlock()
        if let surf = surface {
            delegate?.waylandServerDidDestroySurface(self, surface: surf)
        }
    }

    public func surface(for id: UInt32) -> WaylandSurface? {
        surfaceLock.lock()
        defer { surfaceLock.unlock() }
        return surfaces[id]
    }
}

extension WaylandServer: VZVirtioSocketListenerDelegate {
    public func listener(
        _ listener: VZVirtioSocketListener,
        shouldAcceptNewConnection connection: VZVirtioSocketConnection,
        from socketDevice: VZVirtioSocketDevice
    ) -> Bool {
        let channel = VsockChannel(connection: connection)
        let session = WaylandClientSession(channel: channel, server: self)
        activeSessions.append(session)

        channel.onDataReceived = { [weak session] data in
            session?.processIncoming(data: data)
        }

        channel.onClosed = { [weak self, weak session] in
            guard let self = self, let session = session else { return }
            self.activeSessions.removeAll(where: { $0 === session })
        }

        channel.start()
        return true
    }
}

final class WaylandClientSession {
    let channel: VsockChannel
    unowned let server: WaylandServer
    var incomingBuffer = Data()
    var registryId: UInt32?
    var compositorId: UInt32?
    var subcompositorId: UInt32?
    var shmId: UInt32?
    var seatId: UInt32?
    var outputId: UInt32?
    var wmBaseId: UInt32?
    var xdgSurfaces: [UInt32: UInt32] = [:] // xdgSurfaceId -> surfaceId
    var toplevels: [UInt32: UInt32] = [:]   // toplevelId -> xdgSurfaceId
    var serialCounter: UInt32 = 0

    init(channel: VsockChannel, server: WaylandServer) {
        self.channel = channel
        self.server = server
    }

    func send(_ msg: WaylandMessage) {
        _ = channel.send(data: msg.serialize())
    }

    func processIncoming(data: Data) {
        incomingBuffer.append(data)

        while incomingBuffer.count >= 8 {
            let objectId = incomingBuffer.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
            let opcodeAndSize = incomingBuffer.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
            let size = Int(opcodeAndSize >> 16)
            let opcode = UInt16(opcodeAndSize & 0xFFFF)

            guard size >= 8 else {
                print("❌ [Wayland] Malformed message size: \(size). Resetting buffer.")
                incomingBuffer.removeAll()
                break
            }

            guard incomingBuffer.count >= size else {
                // Wait for the full message to arrive
                break
            }

            let msgData = Data(incomingBuffer.prefix(size))
            incomingBuffer = Data(incomingBuffer.dropFirst(size))
            handleMessage(objectId: objectId, opcode: opcode, size: size, data: msgData)
        }
    }

    private func handleMessage(objectId: UInt32, opcode: UInt16, size: Int, data: Data) {
        // 1. wl_display (objectId 1)
        if objectId == 1 {
            if opcode == 0 && size >= 12 {
                // wl_display.sync(callback_id)
                let callbackId = data.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self) }
                serialCounter += 1
                send(WaylandMessage.callbackDoneEvent(callbackId: callbackId, serial: serialCounter))
                print("⚡️ [Wayland] Handled wl_display.sync callback #\(callbackId)")
                return
            } else if opcode == 1 && size >= 12 {
                // wl_display.get_registry(registry_id)
                let regId = data.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self) }
                self.registryId = regId

                let globals: [(UInt32, String, UInt32)] = [
                    (1, WaylandGlobalInterface.wlCompositor.rawValue, 4),
                    (2, WaylandGlobalInterface.wlSubcompositor.rawValue, 1),
                    (3, WaylandGlobalInterface.wlShm.rawValue, 1),
                    (4, WaylandGlobalInterface.xdgWmBase.rawValue, 1),
                    (5, WaylandGlobalInterface.wlSeat.rawValue, 5),
                    (6, WaylandGlobalInterface.wlOutput.rawValue, 2)
                ]
                for (name, iface, version) in globals {
                    send(WaylandMessage.globalEvent(registryId: regId, name: name, interface: iface, version: version))
                }
                print("⚡️ [Wayland] Advertised globals to registry #\(regId)")
                return
            }
        }

        // 2. wl_registry
        if let regId = registryId, objectId == regId {
            if opcode == 0 && size >= 16 {
                // wl_registry.bind(name, iface, version, id)
                let name = data.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self) }
                let strLen = Int(data.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt32.self) })
                let alignedStrLen = (strLen + 3) & ~3
                let iface: String = data.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress, data.count >= 16 else { return "" }
                    return String(cString: base.advanced(by: 16).assumingMemoryBound(to: CChar.self))
                }
                let verOffset = 16 + alignedStrLen
                let version = (data.count >= verOffset + 4) ? data.withUnsafeBytes { $0.load(fromByteOffset: verOffset, as: UInt32.self) } : 1
                let idOffset = verOffset + 4
                let newId = (data.count >= idOffset + 4) ? data.withUnsafeBytes { $0.load(fromByteOffset: idOffset, as: UInt32.self) } : 0

                print("⚡️ [Wayland] Bound global '\(iface)' (name: \(name), ver: \(version)) -> id #\(newId)")

                switch iface {
                case WaylandGlobalInterface.wlCompositor.rawValue:
                    self.compositorId = newId
                case WaylandGlobalInterface.wlSubcompositor.rawValue:
                    self.subcompositorId = newId
                case WaylandGlobalInterface.wlShm.rawValue:
                    self.shmId = newId
                    send(WaylandMessage.shmFormatEvent(shmId: newId, format: 0)) // ARGB8888
                    send(WaylandMessage.shmFormatEvent(shmId: newId, format: 1)) // XRGB8888
                case WaylandGlobalInterface.wlSeat.rawValue:
                    self.seatId = newId
                    send(WaylandMessage.seatCapabilitiesEvent(seatId: newId, capabilities: 7)) // pointer|keyboard|touch
                    send(WaylandMessage.seatNameEvent(seatId: newId, name: "seat0"))
                case WaylandGlobalInterface.wlOutput.rawValue:
                    self.outputId = newId
                    send(WaylandMessage.outputGeometryEvent(
                        outputId: newId, x: 0, y: 0, physicalWidth: 400, physicalHeight: 300, subpixel: 0,
                        make: "Apple", model: "MSA-VirtualDisplay", transform: 0
                    ))
                    send(WaylandMessage.outputModeEvent(outputId: newId, flags: 3, width: 1920, height: 1080, refresh: 60000))
                    send(WaylandMessage.outputScaleEvent(outputId: newId, factor: 1))
                    send(WaylandMessage.outputDoneEvent(outputId: newId))
                case WaylandGlobalInterface.xdgWmBase.rawValue:
                    self.wmBaseId = newId
                default:
                    break
                }
                return
            }
        }

        // 3. wl_compositor
        if let compId = compositorId, objectId == compId {
            if opcode == 0 && size >= 12 {
                // create_surface(id)
                let surfaceId = data.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self) }
                let surface = server.registerSurface(id: surfaceId)
                surface.onSendMessage = { [weak self] msg in
                    self?.send(msg)
                }
                print("⚡️ [Wayland] wl_compositor.create_surface -> #\(surfaceId)")
                return
            } else if opcode == 1 && size >= 12 {
                // create_region(id)
                let regionId = data.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self) }
                print("⚡️ [Wayland] wl_compositor.create_region -> #\(regionId)")
                return
            }
        }

        // 4. xdg_wm_base
        if let wmId = wmBaseId, objectId == wmId {
            if opcode == 2 && size >= 16 {
                // get_xdg_surface(id, surface)
                let xdgSurfaceId = data.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self) }
                let surfaceId = data.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt32.self) }
                xdgSurfaces[xdgSurfaceId] = surfaceId
                print("⚡️ [Wayland] xdg_wm_base.get_xdg_surface #\(xdgSurfaceId) for surface #\(surfaceId)")
                return
            } else if opcode == 3 && size >= 12 {
                // pong(serial)
                let serial = data.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self) }
                print("⚡️ [Wayland] xdg_wm_base.pong serial=\(serial)")
                return
            }
        }

        // 5. xdg_surface
        if xdgSurfaces[objectId] != nil {
            if opcode == 1 && size >= 12 {
                // get_toplevel(id)
                let toplevelId = data.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self) }
                toplevels[toplevelId] = objectId
                serialCounter += 1
                let ser = serialCounter
                print("⚡️ [Wayland] xdg_surface.get_toplevel -> toplevel #\(toplevelId)")
                send(WaylandMessage.xdgToplevelConfigureEvent(toplevelId: toplevelId, width: 0, height: 0, states: []))
                send(WaylandMessage.xdgSurfaceConfigureEvent(xdgSurfaceId: objectId, serial: ser))

                if let surfaceId = xdgSurfaces[objectId], let surface = server.surface(for: surfaceId) {
                    server.notifyToplevelCreated(surface: surface)
                }
                return
            } else if opcode == 4 && size >= 12 {
                // ack_configure(serial)
                let serial = data.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self) }
                print("⚡️ [Wayland] xdg_surface #\(objectId) ack_configure serial=\(serial)")
                return
            }
        }

        // 6. xdg_toplevel
        if let xdgSurfaceId = toplevels[objectId], let surfaceId = xdgSurfaces[xdgSurfaceId], let surface = server.surface(for: surfaceId) {
            if opcode == 2 && size >= 12 {
                // set_title(title)
                let title: String = data.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress, data.count >= 12 else { return "" }
                    return String(cString: base.advanced(by: 12).assumingMemoryBound(to: CChar.self))
                }
                surface.setTitle(title)
                print("⚡️ [Wayland] xdg_toplevel set_title: '\(title)'")
                server.notifyToplevelCreated(surface: surface)
                return
            } else if opcode == 3 && size >= 12 {
                // set_app_id(app_id)
                let appId: String = data.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress, data.count >= 12 else { return "" }
                    return String(cString: base.advanced(by: 12).assumingMemoryBound(to: CChar.self))
                }
                surface.setAppId(appId)
                print("⚡️ [Wayland] xdg_toplevel set_app_id: '\(appId)'")
                return
            }
        }

        // 7. wl_surface
        if let surface = server.surface(for: objectId) {
            if opcode == 3 && size >= 12 {
                // frame(callback_id)
                let callbackId = data.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self) }
                serialCounter += 1
                send(WaylandMessage.callbackDoneEvent(callbackId: callbackId, serial: serialCounter))
                return
            } else if opcode == 6 {
                // commit
                surface.commit()
                return
            }
        }

        // General fallback for surface creation
        if size >= 8 && objectId > 1 && server.surface(for: objectId) == nil {
            let surface = server.registerSurface(id: objectId)
            surface.onSendMessage = { [weak self] msg in
                self?.send(msg)
            }
        }
    }
}
