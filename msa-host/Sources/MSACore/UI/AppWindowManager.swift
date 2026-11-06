import AppKit

@MainActor
public final class AppWindowManager {
    public static let shared = AppWindowManager()
    
    private var windows: [String: AndroidWindowController] = [:] // packageName -> windowController
    public private(set) var currentFocusedPackage: String?
    private var activityCache: [String: String] = [:] // packageName -> full activity component
    private var monitorTask: Task<Void, Never>?
    private var windowOffsetIndex: Int = 0

    private init() {
        startFocusMonitor()
        GPUBridgeServer.shared.delegate = self
    }

    public func getOrCreateWindow(for packageName: String, title: String? = nil) -> AndroidWindowController {
        if let existing = windows[packageName] {
            existing.window?.makeKeyAndOrderFront(nil)
            return existing
        }

        let resolvedTitle = title ?? friendlyName(for: packageName)
        let controller = AndroidWindowController(package: packageName, title: resolvedTitle)
        windows[packageName] = controller

        // Cascade new windows with an offset so they don't completely overlap
        if let win = controller.window {
            windowOffsetIndex += 1
            let offset = CGFloat((windowOffsetIndex % 6) * 40)
            let baseFrame = win.frame
            win.setFrameOrigin(NSPoint(x: baseFrame.origin.x + offset, y: baseFrame.origin.y - offset))
        }

        controller.showWindow(nil)
        return controller
    }

    public func removeWindow(for packageName: String) {
        windows.removeValue(forKey: packageName)
    }

    public func window(for packageName: String) -> AndroidWindowController? {
        return windows[packageName]
    }

    public var allWindows: [AndroidWindowController] {
        return Array(windows.values)
    }

    public func bringToFront(package: String) {
        currentFocusedPackage = package
        try? package.write(toFile: "/tmp/msa_current_focus", atomically: true, encoding: .utf8)
        guard let adb = PackageInstaller.locateADB() else { return }

        DispatchQueue.global(qos: .userInteractive).async {
            // If we have a cached component, start it directly for near-instant switching
            if let cached = self.activityCache[package] {
                let amProc = Process()
                amProc.executableURL = URL(fileURLWithPath: adb)
                amProc.arguments = ["shell", "am", "start", "-n", cached]
                try? amProc.run()
                amProc.waitUntilExit()
            } else {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: adb)
                proc.arguments = ["shell", "cmd", "package", "resolve-activity", "--brief", package]
                let pipe = Pipe()
                proc.standardOutput = pipe
                if (try? proc.run()) != nil {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    proc.waitUntilExit()
                    let out = String(data: data, encoding: .utf8) ?? ""
                    for line in out.split(separator: "\n").reversed() {
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.contains("/") && !trimmed.contains(" ") {
                            let amTask = Process()
                            amTask.executableURL = URL(fileURLWithPath: adb)
                            amTask.arguments = ["shell", "am", "start", "-n", trimmed]
                            try? amTask.run()
                            amTask.waitUntilExit()
                            Task { @MainActor [weak self] in
                                self?.activityCache[package] = trimmed
                            }
                            break
                        }
                    }
                }
            }

            // Ensure top task bounds fill full screen
            let resizeCmd = "for t in $(dumpsys activity | grep -E \"Task\\{[a-f0-9]+ #[0-9]+.*\(package)\" | grep -o '#[0-9]*' | tr -d '#'); do am task resize $t 0 0 540 960; done"
            let rz = Process()
            rz.executableURL = URL(fileURLWithPath: adb)
            rz.arguments = ["shell", resizeCmd]
            try? rz.run()
        }
    }

    private func startFocusMonitor() {
        guard monitorTask == nil else { return }
        monitorTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let adb = PackageInstaller.locateADB() else { return }
            while !Task.isCancelled {
                // Fast path: immediate focus switch signaled via IPC file
                if let fastPkg = try? String(contentsOfFile: "/tmp/msa_current_focus", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !fastPkg.isEmpty {
                    await MainActor.run {
                        guard let self = self else { return }
                        if self.currentFocusedPackage != fastPkg {
                            self.currentFocusedPackage = fastPkg
                            _ = self.getOrCreateWindow(for: fastPkg)
                        }
                    }
                }

                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: adb)
                proc.arguments = ["shell", "dumpsys window | grep mCurrentFocus"]
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = Pipe()
                if (try? proc.run()) != nil {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    proc.waitUntilExit()
                    let outStr = String(data: data, encoding: .utf8) ?? ""
                    for line in outStr.split(separator: "\n") {
                        if line.contains("mCurrentFocus") {
                            // Extract package: e.g. "mCurrentFocus=Window{... u0 com.facebook.lite/com.facebook.lite.MainActivity}"
                            let components = line.split(separator: " ")
                            if let slashPart = components.last(where: { $0.contains("/") }) {
                                let trimmedSlash = slashPart.trimmingCharacters(in: CharacterSet(charactersIn: "} \r\n"))
                                let subparts = trimmedSlash.split(separator: "/")
                                let pkg = String(subparts.first ?? "")
                                if !pkg.isEmpty && !pkg.contains("settings") && !pkg.contains("systemui") && !pkg.contains("launcher") {
                                    let comp = trimmedSlash
                                    await MainActor.run {
                                        guard let self = self else { return }
                                        self.activityCache[pkg] = comp
                                        if self.currentFocusedPackage != pkg {
                                            self.currentFocusedPackage = pkg
                                        }
                                        _ = self.getOrCreateWindow(for: pkg)
                                    }
                                }
                            }
                            break
                        }
                    }
                }
                try? await Task.sleep(nanoseconds: 100_000_000) // Poll every 100ms
            }
        }
    }

    public func friendlyName(for package: String) -> String {
        if package.contains("aurora.store") { return "Aurora Store" }
        if package.contains("facebook.lite") { return "Facebook Lite" }
        if package.contains("instagram") { return "Instagram" }
        if package.contains("twitter") || package.contains("x.android") { return "X" }
        if package.contains("whatsapp") { return "WhatsApp" }
        if package.contains("telegram") { return "Telegram" }
        if package.contains("spotify") { return "Spotify" }
        if package.contains("reddit") { return "Reddit" }
        if package.contains("tiktok") { return "TikTok" }
        if package.contains("youtube") { return "YouTube" }
        let last = package.split(separator: ".").last ?? Substring(package)
        return last.capitalized
    }
}

extension AppWindowManager: GPUBridgeServerDelegate {
    public nonisolated func gpuBridgeServer(_ server: GPUBridgeServer, didReceiveFrame packet: GPUFramePacket) {
        Task { @MainActor in
            if let pkg = self.currentFocusedPackage, let win = self.windows[pkg] {
                win.didReceiveGPUFrame(packet)
            }
        }
    }
}
