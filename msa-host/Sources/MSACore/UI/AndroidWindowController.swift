import AppKit

public final class AndroidWindowController: NSWindowController {
    public let surface: WaylandSurface
    public let appPackage: String?
    private var metalView: MetalSurfaceView!
    private var streamTask: Task<Void, Never>?
    private var currentAndroidWidth: Int = 540
    private var currentAndroidHeight: Int = 896
    private var captionOffset: Int = 64
    private var lastFrozenBuffer: WaylandBuffer?
    private var dragStart: (x: Double, y: Double)?
    private var dragStartTime: Date?
    private let cachedADBPath: String? = PackageInstaller.locateADB()
    public private(set) var lastGPUFrameTime: Date?

    public init(package: String, title: String) {
        self.appPackage = package
        self.surface = WaylandSurface(id: UInt32(bitPattern: Int32(truncatingIfNeeded: package.hashValue)))
        self.surface.appTitle = title
        self.surface.appId = package

        let defaultWidth: CGFloat = 440
        let defaultHeight: CGFloat = 780

        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: defaultWidth, height: defaultHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)

        window.title = title
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.center()

        let view = MetalSurfaceView(frame: window.contentView!.bounds)
        view.autoresizingMask = [.width, .height]
        self.metalView = view
        window.contentView = view
        window.delegate = self

        surface.observer = self
        setupInputHandling()
        configureDisplayIfNeeded()
        startLiveStream()
    }

    public convenience init(surface: WaylandSurface) {
        let pkg = surface.appId ?? "com.android.app"
        let ttl = surface.appTitle ?? "Android App"
        self.init(package: pkg, title: ttl)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureDisplayIfNeeded() {
        DispatchQueue.global(qos: .userInitiated).async { [adbPath = self.cachedADBPath] in
            guard let adb = adbPath else { return }
            let cmds = [
                "settings put global policy_control immersive.full=*",
                "setprop debug.sf.nobootanimation 1",
                "setprop dalvik.vm.boot-dex2oat-threads 8",
                "setprop dalvik.vm.dex2oat-threads 8",
                "setprop dalvik.vm.image-dex2oat-threads 8",
                "setprop persist.device_config.runtime_native.usap_pool_enabled true",
                "settings put global window_animation_scale 0.5",
                "settings put global transition_animation_scale 0.5",
                "settings put global animator_duration_scale 0.5",
                "wm size 540x960",
                "wm density 240"
            ]
            let script = cmds.joined(separator: " && ")
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: adb)
            proc.arguments = ["shell", script]
            try? proc.run()
            proc.waitUntilExit()
        }
    }

    public func startLiveStream() {
        guard streamTask == nil else { return }
        streamTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let adb = PackageInstaller.locateADB() else { return }
            while !Task.isCancelled {
                guard let targetPkg = await self?.appPackage else { break }
                let focused = await AppWindowManager.shared.currentFocusedPackage

                if focused == targetPkg {
                    // If high-speed Metal GPU bridge stream is active, yield CPU and avoid redundant screencap
                    if let lastGPU = await self?.lastGPUFrameTime, Date().timeIntervalSince(lastGPU) < 0.5 {
                        try? await Task.sleep(nanoseconds: 30_000_000)
                        continue
                    }

                    // Fallback screencap pipeline
                    let proc = Process()
                    proc.executableURL = URL(fileURLWithPath: adb)
                    proc.arguments = ["exec-out", "screencap"]
                    let pipe = Pipe()
                    proc.standardOutput = pipe
                    do {
                        try proc.run()
                        let data = pipe.fileHandleForReading.readDataToEndOfFile()
                        proc.waitUntilExit()

                        // Verify this package is STILL foreground before committing frame
                        let stillFocused = await AppWindowManager.shared.currentFocusedPackage
                        if stillFocused == targetPkg && data.count > 16 {
                            let w = Int(data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) })
                            let h = Int(data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) })
                            let rowBytes = w * 4

                            let cropY = 64
                            let effectiveHeight = max(100, h - cropY)
                            let startOffset = 16 + (cropY * rowBytes)
                            let endOffset = startOffset + (effectiveHeight * rowBytes)

                            if startOffset < data.count && endOffset <= data.count {
                                let pixelData = data.subdata(in: startOffset..<endOffset)

                                await MainActor.run {
                                    self?.currentAndroidWidth = w
                                    self?.currentAndroidHeight = effectiveHeight
                                    self?.captionOffset = cropY
                                }

                                let buffer = WaylandBuffer(
                                    id: 1,
                                    width: w,
                                    height: effectiveHeight,
                                    stride: rowBytes,
                                    format: .xbgr8888,
                                    data: pixelData
                                )

                                await MainActor.run {
                                    self?.lastFrozenBuffer = buffer
                                    self?.surface.attach(buffer: buffer)
                                    self?.surface.commit()
                                }
                            }
                        }
                    } catch {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                    try? await Task.sleep(nanoseconds: 35_000_000)
                } else {
                    // Background window: do not run screencap; retain last frozen buffer
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
        }
    }

    public func didReceiveGPUFrame(_ packet: GPUFramePacket) {
        lastGPUFrameTime = Date()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.currentAndroidWidth = Int(packet.width)
            self.currentAndroidHeight = Int(packet.height)
            self.metalView.renderGPU(
                pixelData: packet.pixelData,
                width: Int(packet.width),
                height: Int(packet.height),
                stride: Int(packet.stride),
                format: packet.waylandFormat
            )
        }
    }

    private func setupInputHandling() {
        metalView.onMouseEvent = { [weak self] type, x, y, button in
            guard let self = self, let window = self.window else { return }
            self.surface.sendPointerEvent(type: type, x: x, y: y, button: button)

            // If user clicked an inactive window, bring its package to front in Android
            if case .buttonDown = type {
                if let pkg = self.appPackage {
                    Task { @MainActor in
                        if AppWindowManager.shared.currentFocusedPackage != pkg {
                            AppWindowManager.shared.bringToFront(package: pkg)
                        }
                    }
                }
            }

            let winWidth = window.contentView?.bounds.width ?? 1
            let winHeight = window.contentView?.bounds.height ?? 1
            let normX = max(0.0, min(1.0, x / Double(winWidth)))
            let normY = max(0.0, min(1.0, y / Double(winHeight)))

            let targetX = Int(normX * Double(self.currentAndroidWidth))
            let targetY = self.captionOffset + Int(normY * Double(self.currentAndroidHeight))

            if case .buttonDown = type {
                self.dragStart = (x: Double(targetX), y: Double(targetY))
                self.dragStartTime = Date()
            } else if case .buttonUp = type {
                if let start = self.dragStart {
                    let now = Date()
                    let elapsed = now.timeIntervalSince(self.dragStartTime ?? now)
                    let dx = abs(Double(targetX) - start.x)
                    let dy = abs(Double(targetY) - start.y)
                    let dist = hypot(dx, dy)

                    // A tap is any quick release (under 0.4s) or small movement (under 50px)
                    if dist < 50 || elapsed < 0.4 {
                        let tapX = Int(start.x)
                        let tapY = Int(start.y)
                        print("🖱️ [MSA] Tap at (\(tapX), \(tapY)) [dist=\(Int(dist)), elapsed=\(String(format: "%.2f", elapsed))s]")
                        DispatchQueue.global(qos: .userInteractive).async { [adbPath = self.cachedADBPath] in
                            guard let adb = adbPath else { return }
                            let tapProc = Process()
                            tapProc.executableURL = URL(fileURLWithPath: adb)
                            tapProc.arguments = ["shell", "input", "tap", "\(tapX)", "\(tapY)"]
                            try? tapProc.run()
                        }
                    } else {
                        // Genuine drag / swipe gesture
                        let startX = Int(start.x)
                        let startY = Int(start.y)
                        print("🖱️ [MSA] Drag from (\(startX), \(startY)) to (\(targetX), \(targetY))")
                        DispatchQueue.global(qos: .userInteractive).async { [adbPath = self.cachedADBPath] in
                            guard let adb = adbPath else { return }
                            let swipeProc = Process()
                            swipeProc.executableURL = URL(fileURLWithPath: adb)
                            swipeProc.arguments = ["shell", "input", "swipe", "\(startX)", "\(startY)", "\(targetX)", "\(targetY)", "250"]
                            try? swipeProc.run()
                        }
                    }
                    self.dragStart = nil
                    self.dragStartTime = nil
                }
            } else if case .scroll(_, let deltaY) = type {
                // Natural mouse/trackpad scrolling mapped to Android swipe
                if abs(deltaY) > 1.5 {
                    let sy = deltaY > 0 ? -160 : 160
                    DispatchQueue.global(qos: .userInteractive).async { [adbPath = self.cachedADBPath] in
                        guard let adb = adbPath else { return }
                        let swipeProc = Process()
                        swipeProc.executableURL = URL(fileURLWithPath: adb)
                        let endY = max(80, min(self.currentAndroidHeight - 50, targetY + sy))
                        swipeProc.arguments = ["shell", "input", "swipe", "\(targetX)", "\(targetY)", "\(targetX)", "\(endY)", "120"]
                        try? swipeProc.run()
                    }
                }
            }
        }

        metalView.onKeyEvent = { [weak self] keycode, isDown in
            guard let self = self else { return }
            self.surface.sendKeyboardEvent(keyCode: keycode, isDown: isDown)

            if isDown {
                var androidKey: Int?
                if keycode == 14 { androidKey = 67 }      // Delete -> KEYCODE_DEL
                else if keycode == 28 { androidKey = 66 } // Return -> KEYCODE_ENTER
                else if keycode == 1 { androidKey = 4 }   // Esc -> KEYCODE_BACK
                else if keycode == 15 { androidKey = 61 } // Tab -> KEYCODE_TAB
                else if keycode == 57 { androidKey = 62 } // Space -> KEYCODE_SPACE

                if let k = androidKey, let adb = self.cachedADBPath {
                    DispatchQueue.global(qos: .userInteractive).async {
                        let keyProc = Process()
                        keyProc.executableURL = URL(fileURLWithPath: adb)
                        keyProc.arguments = ["shell", "input", "keyevent", "\(k)"]
                        try? keyProc.run()
                    }
                }
            }
        }
    }
}

extension AndroidWindowController: WaylandSurfaceObserver {
    public func surfaceDidUpdateFrame(_ surface: WaylandSurface, buffer: WaylandBuffer) {
        DispatchQueue.main.async { [weak self] in
            self?.metalView.render(buffer: buffer)
        }
    }

    public func surfaceDidUpdateTitle(_ surface: WaylandSurface, title: String) {
        DispatchQueue.main.async { [weak self] in
            // Protect native window title: ignore empty or generic "waydroid" titles
            if !title.isEmpty && title.lowercased() != "waydroid" {
                self?.window?.title = title
            }
        }
    }

    public func surfaceDidClose(_ surface: WaylandSurface) {
        DispatchQueue.main.async { [weak self] in
            self?.streamTask?.cancel()
            self?.close()
        }
    }
}

extension AndroidWindowController: NSWindowDelegate {
    public func windowWillClose(_ notification: Notification) {
        streamTask?.cancel()
        surface.close()
        if let pkg = appPackage {
            Task { @MainActor in
                AppWindowManager.shared.removeWindow(for: pkg)
            }
            if let adb = cachedADBPath {
                DispatchQueue.global(qos: .userInitiated).async {
                    let killProc = Process()
                    killProc.executableURL = URL(fileURLWithPath: adb)
                    killProc.arguments = ["shell", "am", "force-stop", pkg]
                    try? killProc.run()
                }
            }
        }
    }

    public func windowDidBecomeKey(_ notification: Notification) {
        if let pkg = appPackage {
            Task { @MainActor in
                if AppWindowManager.shared.currentFocusedPackage != pkg {
                    AppWindowManager.shared.bringToFront(package: pkg)
                }
            }
        }
    }

    public func windowDidResize(_ notification: Notification) {
        guard let size = window?.contentView?.bounds.size else { return }
        surface.requestResize(width: Int32(size.width), height: Int32(size.height))

        let targetW = max(360, (Int(size.width * 1.5) / 2) * 2)
        let targetH = max(480, (Int(size.height * 1.5) / 2) * 2)

        DispatchQueue.global(qos: .userInitiated).async { [adbPath = self.cachedADBPath] in
            guard let adb = adbPath else { return }
            let resizeProc = Process()
            resizeProc.executableURL = URL(fileURLWithPath: adb)
            resizeProc.arguments = ["shell", "wm", "size", "\(targetW)x\(targetH)"]
            try? resizeProc.run()
        }
    }
}
