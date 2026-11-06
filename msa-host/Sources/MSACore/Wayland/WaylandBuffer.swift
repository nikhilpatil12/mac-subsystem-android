import Foundation
import CoreGraphics

public final class WaylandBuffer {
    public let id: UInt32
    public let width: Int
    public let height: Int
    public let stride: Int
    public let format: WaylandShmFormat
    public private(set) var pixelData: Data

    public init(id: UInt32, width: Int, height: Int, stride: Int, format: WaylandShmFormat, data: Data) {
        self.id = id
        self.width = width
        self.height = height
        self.stride = stride
        self.format = format
        self.pixelData = data
    }

    public func createCGImage() -> CGImage? {
        guard !pixelData.isEmpty, width > 0, height > 0 else { return nil }

        let bitsPerComponent = 8
        let bitsPerPixel = 32
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var bitmapInfo: CGBitmapInfo = []

        switch format {
        case .argb8888:
            bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        case .xrgb8888:
            bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        case .abgr8888:
            bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        case .xbgr8888:
            bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        case .rgba8888, .rgbx8888:
            bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        default:
            bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        }

        guard let provider = CGDataProvider(data: pixelData as CFData) else { return nil }

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bitsPerPixel: bitsPerPixel,
            bytesPerRow: stride,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
