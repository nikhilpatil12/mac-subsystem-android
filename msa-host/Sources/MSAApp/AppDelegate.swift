import AppKit
import MSACore
import Virtualization

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var vmManager: VMManager?
    private var waylandServer: WaylandServer!
    private var activeWindows: [UInt32: AndroidWindowController] = [:]
    private var clipboardBridge: ClipboardBridge!

    public func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        setupWaylandServer()
        setupClipboard()
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "🤖 MSA"
            button.toolTip = "Mac Subsystem for Android"
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Mac Subsystem for Android", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Start Subsystem", action: #selector(startSubsystem), keyEquivalent: "s"))
        menu.addItem(NSMenuItem(title: "Stop Subsystem", action: #selector(stopSubsystem), keyEquivalent: "x"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Install APK...", action: #selector(selectAndInstallAPK), keyEquivalent: "i"))
        menu.addItem(NSMenuItem(title: "Open Android Apps Folder", action: #selector(openAppsFolder), keyEquivalent: "o"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private func setupWaylandServer() {
        waylandServer = WaylandServer()
        waylandServer.delegate = self
    }

    private func setupClipboard() {
        clipboardBridge = ClipboardBridge()
        clipboardBridge.onHostClipboardChanged = { text in
            // Forward host clipboard change to guest Android
        }
        clipboardBridge.startMonitoring()
    }

    @objc private func startSubsystem() {
        let msaDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".msa")
        let kernel = msaDir.appendingPathComponent("vmlinuz")
        let disk = msaDir.appendingPathComponent("rootfs.img")
        let initrd = msaDir.appendingPathComponent("initrd.img")
        let initrdURL = FileManager.default.fileExists(atPath: initrd.path) ? initrd : nil
        let shared = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")

        let config = VMConfiguration(
            kernelURL: kernel,
            initrdURL: initrdURL,
            diskImageURL: disk,
            sharedDirURL: shared
        )

        let manager = VMManager(config: config)
        self.vmManager = manager

        Task {
            do {
                try await manager.start()
                if let socket = manager.socketDevice {
                    self.waylandServer.attach(to: socket)
                    GPUBridgeServer.shared.attach(to: socket)
                    ADBBridge.shared.start(with: socket)
                }
            } catch {
                await MainActor.run {
                    let alert = NSAlert(error: error)
                    alert.runModal()
                }
            }
        }
    }

    @objc private func stopSubsystem() {
        Task {
            try? await vmManager?.stop()
        }
    }

    @objc private func selectAndInstallAPK() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Select an APK to install into Mac Subsystem for Android"

        if panel.runModal() == .OK, let url = panel.url {
            Task {
                do {
                    try await PackageInstaller.install(apkURL: url)
                    let appName = url.deletingPathExtension().lastPathComponent
                    let meta = AppShimMetadata(appName: appName, packageName: "com.example." + appName.lowercased())
                    _ = try AppShimGenerator.createShim(for: meta)
                } catch {
                    await MainActor.run {
                        let alert = NSAlert(error: error)
                        alert.runModal()
                    }
                }
            }
        }
    }

    @objc private func openAppsFolder() {
        let dir = AppShimGenerator.defaultAppsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

extension AppDelegate: @preconcurrency WaylandServerDelegate {
    public func waylandServerDidCreateSurface(_ server: WaylandServer, surface: WaylandSurface) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let windowController = AndroidWindowController(surface: surface)
            self.activeWindows[surface.id] = windowController
            windowController.showWindow(nil)
        }
    }

    public func waylandServerDidDestroySurface(_ server: WaylandServer, surface: WaylandSurface) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let windowController = self.activeWindows.removeValue(forKey: surface.id) {
                windowController.close()
            }
        }
    }
}
