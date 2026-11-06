import Foundation
import Virtualization
import Darwin

public final class ADBBridge {
    public static let shared = ADBBridge()
    private var serverFd: Int32 = -1
    private var isRunning = false
    public let port: UInt16 = 5555
    private var socketDevice: VZVirtioSocketDevice?

    public init() {}

    public func start(with device: VZVirtioSocketDevice) {
        self.socketDevice = device
        guard !isRunning else { return }
        isRunning = true

        serverFd = socket(AF_INET, SOCK_STREAM, 0)
        guard serverFd >= 0 else {
            print("⚠️ [ADBBridge] Failed to create socket")
            return
        }

        var opt: Int32 = 1
        setsockopt(serverFd, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindRes = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverFd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindRes == 0 else {
            print("⚠️ [ADBBridge] Notice: 127.0.0.1:\(port) is in use; will use existing connection.")
            close(serverFd)
            serverFd = -1
            return
        }

        listen(serverFd, 16)
        print("🔌 [ADBBridge] Listening on 127.0.0.1:\(port) -> Bridging to Android VM vsock:5555")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.acceptLoop()
        }
    }

    private func acceptLoop() {
        while isRunning && serverFd >= 0 {
            var clientAddr = sockaddr_in()
            var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFd = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(serverFd, $0, &clientLen)
                }
            }
            guard clientFd >= 0 else {
                if !isRunning { break }
                continue
            }

            print("🔌 [ADBBridge] Accepted local ADB connection on FD \(clientFd)")
            fflush(stdout)

            guard let device = socketDevice else {
                print("⚠️ [ADBBridge] socketDevice is nil!")
                fflush(stdout)
                close(clientFd)
                continue
            }

            Task { @MainActor in
                do {
                    let connection = try await device.connect(toPort: 5555)
                    Task.detached(priority: .userInitiated) {
                        self.pump(clientFd: clientFd, vsockConnection: connection)
                    }
                } catch {
                    print("⚠️ [ADBBridge] Waiting for guest vsock:5555: \(error.localizedDescription)")
                    fflush(stdout)
                    close(clientFd)
                }
            }
        }
    }

    private func pump(clientFd: Int32, vsockConnection: VZVirtioSocketConnection) {
        let vsockFd = vsockConnection.fileDescriptor
        guard vsockFd >= 0 else {
            close(clientFd)
            return
        }

        print("🔌 [ADBBridge] Bridging client FD \(clientFd) <-> vsock FD \(vsockFd)")
        fflush(stdout)

        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { [vsockConnection] in
            defer {
                shutdown(vsockFd, SHUT_WR)
                group.leave()
            }
            var buf = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = read(clientFd, &buf, buf.count)
                if n <= 0 { break }
                var written = 0
                buf.withUnsafeBytes { rawPtr in
                    guard let base = rawPtr.baseAddress else { return }
                    while written < n {
                        let w = write(vsockFd, base + written, n - written)
                        if w <= 0 { break }
                        written += w
                    }
                }
                if written < n { break }
            }
        }

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { [vsockConnection] in
            defer {
                shutdown(clientFd, SHUT_WR)
                group.leave()
            }
            var buf = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = read(vsockFd, &buf, buf.count)
                if n <= 0 { break }
                var written = 0
                buf.withUnsafeBytes { rawPtr in
                    guard let base = rawPtr.baseAddress else { return }
                    while written < n {
                        let w = write(clientFd, base + written, n - written)
                        if w <= 0 { break }
                        written += w
                    }
                }
                if written < n { break }
            }
        }

        DispatchQueue.global(qos: .userInitiated).async { [vsockConnection] in
            group.wait()
            close(clientFd)
            vsockConnection.close()
        }
    }

    public func stop() {
        isRunning = false
        if serverFd >= 0 {
            close(serverFd)
            serverFd = -1
        }
    }
}
