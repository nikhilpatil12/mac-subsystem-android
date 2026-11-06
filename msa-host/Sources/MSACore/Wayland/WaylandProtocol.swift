import Foundation

public struct WaylandHeader {
    public let objectId: UInt32
    public let opcode: UInt16
    public let size: UInt16

    public init(objectId: UInt32, opcode: UInt16, size: UInt16) {
        self.objectId = objectId
        self.opcode = opcode
        self.size = size
    }

    public static func parse(from data: Data) -> WaylandHeader? {
        guard data.count >= 8 else { return nil }
        let objectId = data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
        let opcodeAndSize = data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
        let size = UInt16(opcodeAndSize >> 16)
        let opcode = UInt16(opcodeAndSize & 0xFFFF)
        return WaylandHeader(objectId: objectId, opcode: opcode, size: size)
    }

    public func serialize() -> Data {
        var data = Data(capacity: 8)
        var objId = objectId
        var opcodeAndSize = (UInt32(size) << 16) | UInt32(opcode)
        withUnsafeBytes(of: &objId) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &opcodeAndSize) { data.append(contentsOf: $0) }
        return data
    }
}

public enum WaylandGlobalInterface: String {
    case wlCompositor = "wl_compositor"
    case wlSubcompositor = "wl_subcompositor"
    case wlShm = "wl_shm"
    case wlSeat = "wl_seat"
    case wlOutput = "wl_output"
    case xdgWmBase = "xdg_wm_base"
    case wpViewporter = "wp_viewporter"
}

public struct WaylandMessage {
    public let header: WaylandHeader
    public let payload: Data

    public init(header: WaylandHeader, payload: Data = Data()) {
        self.header = header
        self.payload = payload
    }

    public func serialize() -> Data {
        var fullData = header.serialize()
        fullData.append(payload)
        return fullData
    }

    public static func encodeString(_ string: String) -> Data {
        var data = Data()
        guard let utf8 = string.data(using: .utf8) else { return data }
        var length = UInt32(utf8.count + 1) // Include null terminator
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(utf8)
        data.append(0) // Null terminator

        // 32-bit alignment padding
        let padding = (4 - (data.count % 4)) % 4
        for _ in 0..<padding {
            data.append(0)
        }
        return data
    }

    public static func globalEvent(registryId: UInt32, name: UInt32, interface: String, version: UInt32) -> WaylandMessage {
        var payload = Data()
        var nameVal = name
        withUnsafeBytes(of: &nameVal) { payload.append(contentsOf: $0) }
        payload.append(encodeString(interface))
        var verVal = version
        withUnsafeBytes(of: &verVal) { payload.append(contentsOf: $0) }

        let size = UInt16(8 + payload.count)
        let header = WaylandHeader(objectId: registryId, opcode: 0, size: size) // wl_registry.global is opcode 0
        return WaylandMessage(header: header, payload: payload)
    }

    public static func shmFormatEvent(shmId: UInt32, format: UInt32) -> WaylandMessage {
        var payload = Data()
        var fmt = format
        withUnsafeBytes(of: &fmt) { payload.append(contentsOf: $0) }
        let size = UInt16(8 + payload.count)
        let header = WaylandHeader(objectId: shmId, opcode: 0, size: size) // wl_shm.format is opcode 0
        return WaylandMessage(header: header, payload: payload)
    }

    public static func xdgSurfaceConfigureEvent(xdgSurfaceId: UInt32, serial: UInt32) -> WaylandMessage {
        var payload = Data()
        var ser = serial
        withUnsafeBytes(of: &ser) { payload.append(contentsOf: $0) }
        let size = UInt16(8 + payload.count)
        let header = WaylandHeader(objectId: xdgSurfaceId, opcode: 0, size: size) // xdg_surface.configure is opcode 0
        return WaylandMessage(header: header, payload: payload)
    }

    public static func callbackDoneEvent(callbackId: UInt32, serial: UInt32 = 0) -> WaylandMessage {
        var payload = Data()
        var ser = serial
        withUnsafeBytes(of: &ser) { payload.append(contentsOf: $0) }
        let size = UInt16(8 + payload.count)
        let header = WaylandHeader(objectId: callbackId, opcode: 0, size: size) // wl_callback.done is opcode 0
        return WaylandMessage(header: header, payload: payload)
    }

    public static func seatCapabilitiesEvent(seatId: UInt32, capabilities: UInt32) -> WaylandMessage {
        var payload = Data()
        var caps = capabilities
        withUnsafeBytes(of: &caps) { payload.append(contentsOf: $0) }
        let size = UInt16(8 + payload.count)
        let header = WaylandHeader(objectId: seatId, opcode: 0, size: size) // wl_seat.capabilities is opcode 0
        return WaylandMessage(header: header, payload: payload)
    }

    public static func seatNameEvent(seatId: UInt32, name: String) -> WaylandMessage {
        let payload = encodeString(name)
        let size = UInt16(8 + payload.count)
        let header = WaylandHeader(objectId: seatId, opcode: 1, size: size) // wl_seat.name is opcode 1
        return WaylandMessage(header: header, payload: payload)
    }

    public static func outputGeometryEvent(
        outputId: UInt32,
        x: Int32,
        y: Int32,
        physicalWidth: Int32,
        physicalHeight: Int32,
        subpixel: Int32 = 0,
        make: String,
        model: String,
        transform: Int32 = 0
    ) -> WaylandMessage {
        var payload = Data()
        var px = x, py = y, pw = physicalWidth, ph = physicalHeight, sp = subpixel, tr = transform
        withUnsafeBytes(of: &px) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: &py) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: &pw) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: &ph) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: &sp) { payload.append(contentsOf: $0) }
        payload.append(encodeString(make))
        payload.append(encodeString(model))
        withUnsafeBytes(of: &tr) { payload.append(contentsOf: $0) }
        let size = UInt16(8 + payload.count)
        let header = WaylandHeader(objectId: outputId, opcode: 0, size: size) // wl_output.geometry is opcode 0
        return WaylandMessage(header: header, payload: payload)
    }

    public static func outputModeEvent(outputId: UInt32, flags: UInt32, width: Int32, height: Int32, refresh: Int32) -> WaylandMessage {
        var payload = Data()
        var fl = flags, w = width, h = height, ref = refresh
        withUnsafeBytes(of: &fl) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: &w) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: &h) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: &ref) { payload.append(contentsOf: $0) }
        let size = UInt16(8 + payload.count)
        let header = WaylandHeader(objectId: outputId, opcode: 1, size: size) // wl_output.mode is opcode 1
        return WaylandMessage(header: header, payload: payload)
    }

    public static func outputScaleEvent(outputId: UInt32, factor: Int32) -> WaylandMessage {
        var payload = Data()
        var fac = factor
        withUnsafeBytes(of: &fac) { payload.append(contentsOf: $0) }
        let size = UInt16(8 + payload.count)
        let header = WaylandHeader(objectId: outputId, opcode: 3, size: size) // wl_output.scale is opcode 3
        return WaylandMessage(header: header, payload: payload)
    }

    public static func outputDoneEvent(outputId: UInt32) -> WaylandMessage {
        let header = WaylandHeader(objectId: outputId, opcode: 2, size: 8) // wl_output.done is opcode 2
        return WaylandMessage(header: header, payload: Data())
    }

    public static func xdgToplevelConfigureEvent(toplevelId: UInt32, width: Int32, height: Int32, states: [UInt32] = []) -> WaylandMessage {
        var payload = Data()
        var w = width, h = height
        withUnsafeBytes(of: &w) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: &h) { payload.append(contentsOf: $0) }
        var arrayLen = UInt32(states.count * 4)
        withUnsafeBytes(of: &arrayLen) { payload.append(contentsOf: $0) }
        for var s in states {
            withUnsafeBytes(of: &s) { payload.append(contentsOf: $0) }
        }
        let size = UInt16(8 + payload.count)
        let header = WaylandHeader(objectId: toplevelId, opcode: 0, size: size) // xdg_toplevel.configure is opcode 0
        return WaylandMessage(header: header, payload: payload)
    }

    public static func xdgWmBasePingEvent(wmBaseId: UInt32, serial: UInt32) -> WaylandMessage {
        var payload = Data()
        var ser = serial
        withUnsafeBytes(of: &ser) { payload.append(contentsOf: $0) }
        let size = UInt16(8 + payload.count)
        let header = WaylandHeader(objectId: wmBaseId, opcode: 0, size: size) // xdg_wm_base.ping is opcode 0
        return WaylandMessage(header: header, payload: payload)
    }
}

public enum WaylandShmFormat: UInt32 {
    case argb8888 = 0
    case xrgb8888 = 1
    case abgr8888 = 2
    case xbgr8888 = 3
    case rgba8888 = 4
    case rgbx8888 = 5
}
