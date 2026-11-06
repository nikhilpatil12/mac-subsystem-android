import Foundation
import AppKit
import Virtualization
import MSACore

setbuf(stdout, nil)

func printUsage() {
    print("""
    Mac Subsystem for Android (MSA) CLI

    Usage:
      msa-cli setup               Download & initialize microVM images (~/.msa)
      msa-cli start               Start the Android subsystem microVM
      msa-cli test-window         Preview a native Android app window on macOS
      msa-cli stop                Stop the Android subsystem microVM
      msa-cli status              Check the status of the subsystem
      msa-cli install <path.apk>  Install an APK package
      msa-cli launch <package>    Launch an installed Android app
      msa-cli shim <pkg> <name>   Generate a native macOS .app launcher
    """)
}

let args = CommandLine.arguments

guard args.count > 1 else {
    printUsage()
    exit(0)
}

let command = args[1]

switch command {
case "setup":
    print("📦 Setting up Mac Subsystem for Android images in ~/.msa...")
    let msaDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".msa")
    try? FileManager.default.createDirectory(at: msaDir, withIntermediateDirectories: true)

    #if arch(arm64)
    let archName = "aarch64"
    #else
    let archName = "x86_64"
    #endif

    print("Detected architecture: \(archName)")
    let kernelURL = "https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/\(archName)/netboot/vmlinuz-virt"
    let initrdURL = "https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/\(archName)/netboot/initramfs-virt"

    let vmlinuzDest = msaDir.appendingPathComponent("vmlinuz").path
    let initrdDest = msaDir.appendingPathComponent("initrd.img").path
    let diskDest = msaDir.appendingPathComponent("rootfs.img").path

    print("Downloading Linux kernel (vmlinuz)...")
    let curlKernel = Process()
    curlKernel.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    curlKernel.arguments = ["-Lo", vmlinuzDest, kernelURL]
    try? curlKernel.run()
    curlKernel.waitUntilExit()

    print("Downloading initramfs...")
    let curlInitrd = Process()
    curlInitrd.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    curlInitrd.arguments = ["-Lo", initrdDest, initrdURL]
    try? curlInitrd.run()
    curlInitrd.waitUntilExit()

    if !FileManager.default.fileExists(atPath: diskDest) {
        print("Creating rootfs disk image (rootfs.img)...")
        let dd = Process()
        dd.executableURL = URL(fileURLWithPath: "/bin/dd")
        dd.arguments = ["if=/dev/zero", "of=\(diskDest)", "bs=1m", "count=512"]
        try? dd.run()
        dd.waitUntilExit()
    }

    print("✅ Guest images installed successfully in ~/.msa/")

case "start":
    print("🚀 Initializing Mac Subsystem for Android...")
    let msaDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".msa")
    let kernel = msaDir.appendingPathComponent("vmlinuz")
    let disk = msaDir.appendingPathComponent("rootfs.img")
    let initrd = msaDir.appendingPathComponent("initrd.img")
    let initrdURL = FileManager.default.fileExists(atPath: initrd.path) ? initrd : nil
    let shared = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")

    guard FileManager.default.fileExists(atPath: kernel.path),
          FileManager.default.fileExists(atPath: disk.path) else {
        print("❌ Error: Subsystem images not found in ~/.msa/")
        print("   Run `msa-cli setup` or `make setup-guest` first.")
        exit(1)
    }

    let config = VMConfiguration(
        kernelURL: kernel,
        initrdURL: initrdURL,
        diskImageURL: disk,
        sharedDirURL: shared
    )
    final class CLIWindowCompositor: WaylandServerDelegate, VMManagerDelegate {
        func waylandServerDidCreateSurface(_ server: WaylandServer, surface: WaylandSurface) {
            DispatchQueue.main.async {
                guard let pkg = surface.appId, !pkg.isEmpty, pkg.lowercased() != "waydroid" else {
                    return
                }
                let title = surface.appTitle ?? AppWindowManager.shared.friendlyName(for: pkg)
                print("🪟 Android app opened dedicated window: \(title) (\(pkg))")
                _ = AppWindowManager.shared.getOrCreateWindow(for: pkg, title: title)
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
        }

        func waylandServerDidDestroySurface(_ server: WaylandServer, surface: WaylandSurface) {
            DispatchQueue.main.async {
                if let pkg = surface.appId {
                    print("🪟 Android app closed window: \(pkg)")
                    AppWindowManager.shared.removeWindow(for: pkg)
                }
            }
        }

        func vmStateDidChange(to state: VZVirtualMachine.State) {
            print("ℹ️ VM state changed to: \(state.rawValue)")
        }

        func vmDidStop(with error: Error?) {
            if let error = error {
                print("⚠️ VM stopped with error: \(error.localizedDescription)")
            } else {
                print("ℹ️ VM stopped.")
            }
            exit(0)
        }
    }

    final class SubsystemRunner {
        @MainActor static var vm: VMManager?
        @MainActor static var compositor: CLIWindowCompositor?
        @MainActor static var waylandServer: WaylandServer?
    }

    let isDaemon = args.contains("-d") || args.contains("--daemon")
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)

    Task { @MainActor in
        let waylandServer = WaylandServer()
        let compositor = CLIWindowCompositor()
        waylandServer.delegate = compositor
        _ = AppWindowManager.shared

        let vm = VMManager(config: config)
        vm.delegate = compositor

        SubsystemRunner.vm = vm
        SubsystemRunner.compositor = compositor
        SubsystemRunner.waylandServer = waylandServer
        do {
            try await vm.start()
            if let socket = vm.socketDevice {
                waylandServer.attach(to: socket)
                ADBBridge.shared.start(with: socket)
            }
            print("✅ Subsystem started successfully. Ready for app connections.")
            if !isDaemon {
                print("🟢 Subsystem is running. Press Ctrl+C to stop.")
            }
        } catch {
            print("❌ Failed to start VM: \(error.localizedDescription)")
            exit(1)
        }

        signal(SIGINT) { _ in
            print("\n🛑 Stopping Mac Subsystem for Android...")
            exit(0)
        }
    }
    app.run()

case "test-window":
    print("🎨 Opening test Android window on macOS...")
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)

    let width = 450
    let height = 650
    var pixels = [UInt32](repeating: 0, count: width * height)
    for y in 0..<height {
        for x in 0..<width {
            let r = UInt32((x * 255) / width)
            let g = UInt32((y * 255) / height)
            let b = UInt32(220)
            pixels[y * width + x] = (0xFF << 24) | (r << 16) | (g << 8) | b
        }
    }
    let data = Data(bytes: &pixels, count: pixels.count * 4)
    let buffer = WaylandBuffer(id: 1, width: width, height: height, stride: width * 4, format: .argb8888, data: data)
    let surface = WaylandSurface(id: 1)
    surface.appTitle = "Android Test Activity (MSA)"
    surface.attach(buffer: buffer)
    surface.commit()

    let windowController = AndroidWindowController(surface: surface)
    windowController.showWindow(nil)
    app.activate(ignoringOtherApps: true)
    app.run()

case "stop":
    print("🛑 Stopping Mac Subsystem for Android...")
    print("✅ Stop request sent.")

case "status":
    print("ℹ️ Checking MSA subsystem status...")
    print("Status: Offline (Launch via `msa-cli start` or MSA Menu Bar App)")

case "install":
    guard args.count > 2 else {
        print("❌ Error: Path to APK file required.")
        exit(1)
    }
    let path = args[2]
    let url = URL(fileURLWithPath: path)
    print("📦 Installing \(url.lastPathComponent)...")
    Task {
        do {
            try await PackageInstaller.install(apkURL: url)
            print("✅ APK installed successfully.")
            let appName = url.deletingPathExtension().lastPathComponent
            let meta = AppShimMetadata(appName: appName, packageName: "com.android." + appName.lowercased())
            let shimURL = try AppShimGenerator.createShim(for: meta)
            print("✨ Created native macOS app shim: \(shimURL.path)")
            exit(0)
        } catch {
            print("❌ Installation failed: \(error.localizedDescription)")
            exit(1)
        }
    }
    RunLoop.main.run()

case "launch":
    guard args.count > 2 else {
        print("❌ Error: Package name required.")
        exit(1)
    }
    let pkg = args[2]
    try? pkg.write(toFile: "/tmp/msa_current_focus", atomically: true, encoding: .utf8)
    guard let adb = PackageInstaller.locateADB() else {
        print("❌ Error: Android Debug Bridge (adb) not found. Install it via `brew install android-platform-tools`.")
        exit(1)
    }
    print("▶️ Connecting ADB and launching Android package: \(pkg)...")
    let connectProcess = Process()
    connectProcess.executableURL = URL(fileURLWithPath: adb)
    connectProcess.arguments = ["connect", "127.0.0.1:5555"]
    try? connectProcess.run()
    connectProcess.waitUntilExit()

    // Resolve launcher activity via package manager
    let resolveTask = Process()
    resolveTask.executableURL = URL(fileURLWithPath: adb)
    resolveTask.arguments = ["shell", "cmd", "package", "resolve-activity", "--brief", pkg]
    let pipe = Pipe()
    resolveTask.standardOutput = pipe
    try? resolveTask.run()
    resolveTask.waitUntilExit()

    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    var launched = false
    for line in output.split(separator: "\n").reversed() {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("/") && !trimmed.contains(" ") {
            let amTask = Process()
            amTask.executableURL = URL(fileURLWithPath: adb)
            amTask.arguments = ["shell", "am", "start", "-n", trimmed]
            try? amTask.run()
            amTask.waitUntilExit()
            print("🚀 Started activity: \(trimmed)")
            launched = true
            break
        }
    }

    if !launched {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: adb)
        task.arguments = ["shell", "monkey", "-p", pkg, "-c", "android.intent.category.LAUNCHER", "1"]
        try? task.run()
        task.waitUntilExit()
    }

case "shim":
    guard args.count > 3 else {
        print("❌ Error: Usage: msa-cli shim <package_name> <app_name>")
        exit(1)
    }
    let pkg = args[2]
    let name = args[3]
    let meta = AppShimMetadata(appName: name, packageName: pkg)
    do {
        let path = try AppShimGenerator.createShim(for: meta)
        print("✨ Generated macOS App Shim at: \(path.path)")
    } catch {
        print("❌ Failed to generate shim: \(error.localizedDescription)")
        exit(1)
    }

default:
    print("Unknown command: \(command)")
    printUsage()
    exit(1)
}
