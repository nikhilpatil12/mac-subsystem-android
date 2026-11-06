import Foundation
import Virtualization

public struct VMConfiguration {
    public var kernelURL: URL
    public var initrdURL: URL?
    public var diskImageURL: URL
    public var sharedDirURL: URL
    public var cpuCount: Int
    public var memoryBytes: UInt64
    public var kernelCommandLine: String

    public init(
        kernelURL: URL,
        initrdURL: URL? = nil,
        diskImageURL: URL,
        sharedDirURL: URL,
        cpuCount: Int = max(4, min(8, ProcessInfo.processInfo.processorCount - 2)),
        memoryBytes: UInt64 = 6 * 1024 * 1024 * 1024, // 6GB optimized for Apple Silicon
        kernelCommandLine: String = "console=hvc0 root=/dev/vda rw panic=-1 init=/init psi=1 quiet loglevel=2 mitigations=off androidboot.nobootanimation=1 androidboot.redroid_fps=60 androidboot.redroid_width=540 androidboot.redroid_height=960 androidboot.redroid_dpi=240"
    ) {
        self.kernelURL = kernelURL
        self.initrdURL = initrdURL
        self.diskImageURL = diskImageURL
        self.sharedDirURL = sharedDirURL
        self.cpuCount = cpuCount
        self.memoryBytes = memoryBytes
        self.kernelCommandLine = kernelCommandLine
    }
}

public enum VMConfigurationError: Error, LocalizedError {
    case invalidCPUCount(Int)
    case invalidMemorySize(UInt64)
    case fileNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCPUCount(let count):
            return "Invalid CPU count \(count). Must be between \(VZVirtualMachineConfiguration.minimumAllowedCPUCount) and \(VZVirtualMachineConfiguration.maximumAllowedCPUCount)."
        case .invalidMemorySize(let bytes):
            return "Invalid memory size \(bytes) bytes. Must be between \(VZVirtualMachineConfiguration.minimumAllowedMemorySize) and \(VZVirtualMachineConfiguration.maximumAllowedMemorySize)."
        case .fileNotFound(let path):
            return "Required file not found at: \(path)"
        }
    }
}

public struct VMConfigurationBuilder {
    @MainActor
    public static func build(from config: VMConfiguration, vmManager: VMManager? = nil) throws -> VZVirtualMachineConfiguration {
        // Validation
        let minCPU = VZVirtualMachineConfiguration.minimumAllowedCPUCount
        let maxCPU = VZVirtualMachineConfiguration.maximumAllowedCPUCount
        guard config.cpuCount >= minCPU && config.cpuCount <= maxCPU else {
            throw VMConfigurationError.invalidCPUCount(config.cpuCount)
        }

        let minMem = VZVirtualMachineConfiguration.minimumAllowedMemorySize
        let maxMem = VZVirtualMachineConfiguration.maximumAllowedMemorySize
        guard config.memoryBytes >= minMem && config.memoryBytes <= maxMem else {
            throw VMConfigurationError.invalidMemorySize(config.memoryBytes)
        }

        guard FileManager.default.fileExists(atPath: config.kernelURL.path) else {
            throw VMConfigurationError.fileNotFound(config.kernelURL.path)
        }

        let vmConfig = VZVirtualMachineConfiguration()

        // 1. Linux Bootloader
        let bootloader = VZLinuxBootLoader(kernelURL: config.kernelURL)
        if let initrd = config.initrdURL, FileManager.default.fileExists(atPath: initrd.path) {
            bootloader.initialRamdiskURL = initrd
        }
        bootloader.commandLine = config.kernelCommandLine
        vmConfig.bootLoader = bootloader

        // 2. Compute configuration
        vmConfig.cpuCount = config.cpuCount
        vmConfig.memorySize = config.memoryBytes

        // 3. Storage configuration (virtio-blk)
        var storageDevices: [VZStorageDeviceConfiguration] = []
        if FileManager.default.fileExists(atPath: config.diskImageURL.path) {
            let diskAttachment = try VZDiskImageStorageDeviceAttachment(
                url: config.diskImageURL,
                readOnly: false
            )
            let blockDevice = VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)
            storageDevices.append(blockDevice)
        }

        // Auto-attach Waydroid system and vendor images if present
        let waydroidDir = config.diskImageURL.deletingLastPathComponent().appendingPathComponent("waydroid")
        let sysImg = waydroidDir.appendingPathComponent("system.img")
        let venImg = waydroidDir.appendingPathComponent("vendor.img")

        if FileManager.default.fileExists(atPath: sysImg.path) {
            let sysAttachment = try VZDiskImageStorageDeviceAttachment(url: sysImg, readOnly: true)
            storageDevices.append(VZVirtioBlockDeviceConfiguration(attachment: sysAttachment))
        }

        if FileManager.default.fileExists(atPath: venImg.path) {
            let venAttachment = try VZDiskImageStorageDeviceAttachment(url: venImg, readOnly: true)
            storageDevices.append(VZVirtioBlockDeviceConfiguration(attachment: venAttachment))
        }

        vmConfig.storageDevices = storageDevices

        // 4. Vsock configuration for Wayland & guest IPC
        let socketDevice = VZVirtioSocketDeviceConfiguration()
        vmConfig.socketDevices = [socketDevice]

        // 5. Shared Directory (virtiofs)
        if FileManager.default.fileExists(atPath: config.sharedDirURL.path) {
            let sharedDir = VZSharedDirectory(url: config.sharedDirURL, readOnly: false)
            let singleDirShare = VZSingleDirectoryShare(directory: sharedDir)
            let fsConfig = VZVirtioFileSystemDeviceConfiguration(tag: "shared_storage")
            fsConfig.share = singleDirShare
            vmConfig.directorySharingDevices = [fsConfig]
        }

        // 6. Network configuration (NAT)
        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        networkDevice.attachment = VZNATNetworkDeviceAttachment()
        vmConfig.networkDevices = [networkDevice]

        // 7. Console device using Pipes
        let inPipe = Pipe()
        let outPipe = Pipe()
        vmManager?.consoleInPipe = inPipe
        vmManager?.consoleOutPipe = outPipe

        let serialPort = VZVirtioConsoleDeviceSerialPortConfiguration()
        serialPort.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: inPipe.fileHandleForReading,
            fileHandleForWriting: outPipe.fileHandleForWriting
        )
        vmConfig.serialPorts = [serialPort]

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                FileHandle.standardOutput.write(data)
            }
        }

        FileHandle.standardInput.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                inPipe.fileHandleForWriting.write(data)
            }
        }

        // 8. Memory Ballooning
        let balloon = VZVirtioTraditionalMemoryBalloonDeviceConfiguration()
        vmConfig.memoryBalloonDevices = [balloon]

        try vmConfig.validate()
        return vmConfig
    }
}
