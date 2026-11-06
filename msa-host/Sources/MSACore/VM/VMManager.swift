import Foundation
import Virtualization

public protocol VMManagerDelegate: AnyObject {
    func vmStateDidChange(to state: VZVirtualMachine.State)
    func vmDidStop(with error: Error?)
}

@MainActor
public final class VMManager: NSObject {
    public private(set) var virtualMachine: VZVirtualMachine?
    public weak var delegate: VMManagerDelegate?
    private let config: VMConfiguration

    public var consoleInPipe: Pipe?
    public var consoleOutPipe: Pipe?
    public var consoleSlaveHandle: FileHandle?
    public var consoleMasterFd: Int32 = -1

    public var state: VZVirtualMachine.State {
        return virtualMachine?.state ?? .stopped
    }

    public private(set) var socketDevice: VZVirtioSocketDevice?

    public init(config: VMConfiguration) {
        self.config = config
        super.init()
    }

    public func start() async throws {
        let vmConfig = try VMConfigurationBuilder.build(from: config, vmManager: self)
        let vm = VZVirtualMachine(configuration: vmConfig, queue: .main)
        vm.delegate = self
        self.virtualMachine = vm
        self.socketDevice = vm.socketDevices.first as? VZVirtioSocketDevice

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            vm.start { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func stop() async throws {
        guard let vm = virtualMachine, vm.state == .running else { return }

        if vm.canRequestStop {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                do {
                    try vm.requestStop()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } else {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                vm.stop { error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
    }

    public func pause() async throws {
        guard let vm = virtualMachine, vm.canPause else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            vm.pause { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func resume() async throws {
        guard let vm = virtualMachine, vm.canResume else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            vm.resume { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

extension VMManager: VZVirtualMachineDelegate {
    public nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        Task { @MainActor in
            delegate?.vmDidStop(with: nil)
        }
    }

    public nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        Task { @MainActor in
            delegate?.vmDidStop(with: error)
        }
    }
}
