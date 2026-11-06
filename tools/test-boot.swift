import Foundation
import Virtualization

let msaDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".msa")
let kernel = msaDir.appendingPathComponent("vmlinuz")
let disk = msaDir.appendingPathComponent("rootfs.img")

let vmConfig = VZVirtualMachineConfiguration()
let bootloader = VZLinuxBootLoader(kernelURL: kernel)
bootloader.commandLine = "console=hvc0 root=/dev/vda rw init=/init psi=1"
vmConfig.bootLoader = bootloader

vmConfig.cpuCount = 4
vmConfig.memorySize = 4 * 1024 * 1024 * 1024 // 4GB

var storageDevices: [VZStorageDeviceConfiguration] = []
let diskAttachment = try VZDiskImageStorageDeviceAttachment(url: disk, readOnly: false)
storageDevices.append(VZVirtioBlockDeviceConfiguration(attachment: diskAttachment))

let sysImg = msaDir.appendingPathComponent("waydroid/system.img")
let venImg = msaDir.appendingPathComponent("waydroid/vendor.img")
if FileManager.default.fileExists(atPath: sysImg.path) {
    let sysAttachment = try VZDiskImageStorageDeviceAttachment(url: sysImg, readOnly: true)
    storageDevices.append(VZVirtioBlockDeviceConfiguration(attachment: sysAttachment))
}
if FileManager.default.fileExists(atPath: venImg.path) {
    let venAttachment = try VZDiskImageStorageDeviceAttachment(url: venImg, readOnly: true)
    storageDevices.append(VZVirtioBlockDeviceConfiguration(attachment: venAttachment))
}
vmConfig.storageDevices = storageDevices

let socketDevice = VZVirtioSocketDeviceConfiguration()
vmConfig.socketDevices = [socketDevice]

let sharedDirURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
let sharedDir = VZSharedDirectory(url: sharedDirURL, readOnly: false)
let singleDirShare = VZSingleDirectoryShare(directory: sharedDir)
let fsConfig = VZVirtioFileSystemDeviceConfiguration(tag: "shared_storage")
fsConfig.share = singleDirShare
vmConfig.directorySharingDevices = [fsConfig]

let netDevice = VZVirtioNetworkDeviceConfiguration()
netDevice.attachment = VZNATNetworkDeviceAttachment()
vmConfig.networkDevices = [netDevice]

var masterFd: Int32 = 0
var slaveFd: Int32 = 0
openpty(&masterFd, &slaveFd, nil, nil, nil)

let slaveHandle = FileHandle(fileDescriptor: slaveFd, closeOnDealloc: false)
let serialPort = VZVirtioConsoleDeviceSerialPortConfiguration()
serialPort.attachment = VZFileHandleSerialPortAttachment(
    fileHandleForReading: slaveHandle,
    fileHandleForWriting: slaveHandle
)
vmConfig.serialPorts = [serialPort]

DispatchQueue.global().async {
    var buf = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(masterFd, &buf, buf.count)
        if n > 0 {
            let str = String(bytes: buf[0..<n], encoding: .utf8) ?? String(bytes: buf[0..<n], encoding: .isoLatin1) ?? ""
            print(str, terminator: "")
            fflush(stdout)
        } else {
            break
        }
    }
}

try vmConfig.validate()

let vm = VZVirtualMachine(configuration: vmConfig, queue: .main)

final class Delegate: NSObject, VZVirtualMachineDelegate {
    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        print("Guest did stop!")
        exit(0)
    }
    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        print("VM stopped with error:", error)
        exit(1)
    }
}

let delegate = Delegate()
vm.delegate = delegate

Task { @MainActor in
    do {
        try await vm.start()
    } catch {
        print("Start failed:", error)
        exit(1)
    }
}

let extraCommand = CommandLine.arguments.dropFirst().joined(separator: " ")
if !extraCommand.isEmpty {
    DispatchQueue.main.asyncAfter(deadline: .now() + 18) {
        print("\n>>> EXECUTING IN GUEST: \(extraCommand)\n")
        let cmd = extraCommand + "\n"
        let data = cmd.data(using: .utf8)!
        data.withUnsafeBytes { rawPtr in
            _ = write(masterFd, rawPtr.baseAddress!, data.count)
        }
    }
}

DispatchQueue.main.asyncAfter(deadline: .now() + 40) {
    print("\nDone waiting. Final VM state:", vm.state.rawValue)
    exit(0)
}

RunLoop.main.run()
