import Foundation

public struct GPUFramePacket: Sendable {
    public static let magic: UInt32 = 0x4D534147 // "MSAG"
    public static let headerSize: Int = 36

    public let version: UInt16
    public let flags: UInt16
    public let width: UInt32
    public let height: UInt32
    public let stride: UInt32
    public let format: UInt32
    public let timestamp: UInt64
    public let payloadLength: UInt32
    public let pixelData: Data

    public init(
        version: UInt16 = 1,
        flags: UInt16 = 0,
        width: UInt32,
        height: UInt32,
        stride: UInt32,
        format: UInt32,
        timestamp: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000),
        pixelData: Data
    ) {
        self.version = version
        self.flags = flags
        self.width = width
        self.height = height
        self.stride = stride
        self.format = format
        self.timestamp = timestamp
        self.payloadLength = UInt32(pixelData.count)
        self.pixelData = pixelData
    }

    public func serialize() -> Data {
        var data = Data(capacity: GPUFramePacket.headerSize + pixelData.count)
        var m = GPUFramePacket.magic.bigEndian
        var v = version.bigEndian
        var f = flags.bigEndian
        var w = width.bigEndian
        var h = height.bigEndian
        var s = stride.bigEndian
        var fmt = format.bigEndian
        var t = timestamp.bigEndian
        var len = payloadLength.bigEndian

        Swift.withUnsafeBytes(of: &m) { data.append(contentsOf: $0) }
        Swift.withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        Swift.withUnsafeBytes(of: &f) { data.append(contentsOf: $0) }
        Swift.withUnsafeBytes(of: &w) { data.append(contentsOf: $0) }
        Swift.withUnsafeBytes(of: &h) { data.append(contentsOf: $0) }
        Swift.withUnsafeBytes(of: &s) { data.append(contentsOf: $0) }
        Swift.withUnsafeBytes(of: &fmt) { data.append(contentsOf: $0) }
        Swift.withUnsafeBytes(of: &t) { data.append(contentsOf: $0) }
        Swift.withUnsafeBytes(of: &len) { data.append(contentsOf: $0) }
        data.append(pixelData)
        return data
    }

    public static func parse(from buffer: inout Data) -> GPUFramePacket? {
        guard buffer.count >= headerSize else { return nil }

        let m = buffer.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }.bigEndian
        guard m == magic else {
            // Drop invalid byte until sync header is found
            buffer.removeFirst(1)
            return nil
        }

        let len = buffer.withUnsafeBytes { $0.load(fromByteOffset: 32, as: UInt32.self) }.bigEndian
        let totalSize = headerSize + Int(len)
        guard buffer.count >= totalSize else {
            // Buffer waiting for complete frame payload
            return nil
        }

        let v = buffer.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt16.self) }.bigEndian
        let f = buffer.withUnsafeBytes { $0.load(fromByteOffset: 6, as: UInt16.self) }.bigEndian
        let w = buffer.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self) }.bigEndian
        let h = buffer.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt32.self) }.bigEndian
        let s = buffer.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt32.self) }.bigEndian
        let fmt = buffer.withUnsafeBytes { $0.load(fromByteOffset: 20, as: UInt32.self) }.bigEndian
        let t = buffer.withUnsafeBytes { $0.load(fromByteOffset: 24, as: UInt64.self) }.bigEndian

        let pixelPayload = buffer.subdata(in: headerSize..<totalSize)
        buffer.removeSubrange(0..<totalSize)

        return GPUFramePacket(
            version: v,
            flags: f,
            width: w,
            height: h,
            stride: s,
            format: fmt,
            timestamp: t,
            pixelData: pixelPayload
        )
    }

    public var waylandFormat: WaylandShmFormat {
        // Android HAL_PIXEL_FORMAT_RGBA_8888 = 1, RGBX_8888 = 2
        switch format {
        case 0: return .argb8888
        case 1, 2: return .rgba8888
        case 3: return .abgr8888
        case 4: return .rgba8888
        default: return .rgba8888
        }
    }
}
