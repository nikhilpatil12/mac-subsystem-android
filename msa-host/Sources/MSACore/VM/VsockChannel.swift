import Foundation
import Virtualization

public final class VsockChannel {
    private let connection: VZVirtioSocketConnection
    private let queue = DispatchQueue(label: "com.msa.vsock.channel", qos: .userInteractive)
    private var isReading = false
    public var onDataReceived: ((Data) -> Void)?
    public var onClosed: (() -> Void)?

    public init(connection: VZVirtioSocketConnection) {
        self.connection = connection
    }

    public func start() {
        guard !isReading else { return }
        isReading = true
        readLoop()
    }

    private func readLoop() {
        queue.async { [weak self] in
            guard let self = self, self.isReading else { return }
            
            let fileDescriptor = self.connection.fileDescriptor
            var buffer = [UInt8](repeating: 0, count: 65536)
            
            let bytesRead = read(fileDescriptor, &buffer, buffer.count)
            if bytesRead > 0 {
                let data = Data(buffer[0..<bytesRead])
                self.onDataReceived?(data)
                self.readLoop()
            } else if bytesRead == 0 {
                // EOF
                self.isReading = false
                self.onClosed?()
            } else {
                // Error
                if errno == EAGAIN || errno == EINTR {
                    self.readLoop()
                } else {
                    self.isReading = false
                    self.onClosed?()
                }
            }
        }
    }

    public func send(data: Data) -> Bool {
        return data.withUnsafeBytes { rawBuffer in
            guard let ptr = rawBuffer.baseAddress else { return false }
            var totalSent = 0
            let count = rawBuffer.count
            
            while totalSent < count {
                let sent = write(connection.fileDescriptor, ptr.advanced(by: totalSent), count - totalSent)
                if sent > 0 {
                    totalSent += sent
                } else if sent < 0 && (errno == EAGAIN || errno == EINTR) {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    public func close() {
        isReading = false
        connection.close()
    }
}
