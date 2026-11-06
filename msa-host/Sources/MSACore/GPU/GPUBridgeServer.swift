import Foundation
import Virtualization

public protocol GPUBridgeServerDelegate: AnyObject {
    func gpuBridgeServer(_ server: GPUBridgeServer, didReceiveFrame packet: GPUFramePacket)
}

public final class GPUBridgeServer: NSObject, @unchecked Sendable {
    public static let shared = GPUBridgeServer()
    public static let defaultPort: UInt32 = 5050

    public let port: UInt32
    private let socketListener = VZVirtioSocketListener()
    private var activeSessions: [GPUBridgeSession] = []
    private let sessionLock = NSLock()
    public weak var delegate: GPUBridgeServerDelegate?

    public private(set) var totalFramesReceived: UInt64 = 0
    public private(set) var currentFPS: Double = 0.0
    private var fpsCounter: UInt64 = 0
    private var lastFPSUpdateTime: Date = Date()

    public init(port: UInt32 = GPUBridgeServer.defaultPort) {
        self.port = port
        super.init()
        self.socketListener.delegate = self
    }

    public func attach(to socketDevice: VZVirtioSocketDevice) {
        socketDevice.setSocketListener(socketListener, forPort: port)
        print("⚡️ [GPUBridgeServer] Listening on vsock port \(port) for hardware-accelerated GPU stream")
    }

    fileprivate func didAcceptFrame(_ packet: GPUFramePacket) {
        totalFramesReceived += 1
        fpsCounter += 1

        let now = Date()
        let elapsed = now.timeIntervalSince(lastFPSUpdateTime)
        if elapsed >= 1.0 {
            currentFPS = Double(fpsCounter) / elapsed
            fpsCounter = 0
            lastFPSUpdateTime = now
        }

        delegate?.gpuBridgeServer(self, didReceiveFrame: packet)
    }

    fileprivate func removeSession(_ session: GPUBridgeSession) {
        sessionLock.lock()
        activeSessions.removeAll(where: { $0 === session })
        sessionLock.unlock()
    }
}

extension GPUBridgeServer: VZVirtioSocketListenerDelegate {
    public func listener(
        _ listener: VZVirtioSocketListener,
        shouldAcceptNewConnection connection: VZVirtioSocketConnection,
        from socketDevice: VZVirtioSocketDevice
    ) -> Bool {
        print("🎮 [GPUBridgeServer] Accepted high-speed GPU stream connection from guest VM")
        let channel = VsockChannel(connection: connection)
        let session = GPUBridgeSession(channel: channel, server: self)

        sessionLock.lock()
        activeSessions.append(session)
        sessionLock.unlock()

        channel.onDataReceived = { [weak session] data in
            session?.processIncoming(data: data)
        }

        channel.onClosed = { [weak self, weak session] in
            guard let self = self, let session = session else { return }
            print("🎮 [GPUBridgeServer] Guest GPU stream closed")
            self.removeSession(session)
        }

        channel.start()
        return true
    }
}

final class GPUBridgeSession: @unchecked Sendable {
    let channel: VsockChannel
    unowned let server: GPUBridgeServer
    private var incomingBuffer = Data()
    private let bufferLock = NSLock()

    init(channel: VsockChannel, server: GPUBridgeServer) {
        self.channel = channel
        self.server = server
    }

    func processIncoming(data: Data) {
        bufferLock.lock()
        incomingBuffer.append(data)

        while let packet = GPUFramePacket.parse(from: &incomingBuffer) {
            bufferLock.unlock()
            server.didAcceptFrame(packet)
            bufferLock.lock()
        }
        bufferLock.unlock()
    }
}
