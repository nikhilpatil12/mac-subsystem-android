import AppKit
import Foundation

public final class IconManager {
    public static let shared = IconManager()

    private let cacheDir: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".msa/icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private var memoryCache: [String: NSImage] = [:]

    private init() {}

    public func icon(for package: String, title: String? = nil) -> NSImage {
        if let cached = memoryCache[package] {
            return cached
        }

        let fileURL = cacheDir.appendingPathComponent("\(package).png")
        if let diskImage = NSImage(contentsOf: fileURL) {
            memoryCache[package] = diskImage
            return diskImage
        }

        // Try to extract or generate
        let resolvedTitle = title ?? package
        let generated = generateIcon(for: package, title: resolvedTitle)
        memoryCache[package] = generated

        // Save to cache dir
        if let tiff = generated.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let pngData = rep.representation(using: .png, properties: [:]) {
            try? pngData.write(to: fileURL)
        }

        return generated
    }

    public func generateIcon(for package: String, title: String) -> NSImage {
        // 1. Check if we can extract an authentic icon from a local APK or via ADB
        if let extracted = tryExtractIcon(for: package) {
            return makeSquircleIcon(innerImage: extracted, colors: brandColors(for: package))
        }

        // 2. Generate a branded squircle icon
        let colors = brandColors(for: package)
        let symbol = brandSymbol(for: package, title: title)
        return makeSquircleIcon(colors: colors, symbol: symbol)
    }

    private func tryExtractIcon(for package: String) -> NSImage? {
        let fileManager = FileManager.default

        // A. Search common download/temp locations for an APK matching package
        let searchDirs = [
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Downloads"),
            URL(fileURLWithPath: "/tmp")
        ]

        var candidateAPKs: [URL] = []
        for dir in searchDirs {
            if let files = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                for file in files where file.pathExtension.lowercased() == "apk" {
                    if file.lastPathComponent.lowercased().contains(package.lowercased()) ||
                       (package.contains("aurora") && file.lastPathComponent.lowercased().contains("aurora")) ||
                       (package.contains("facebook") && file.lastPathComponent.lowercased().contains("fb")) {
                        candidateAPKs.append(file)
                    }
                }
            }
        }

        for apk in candidateAPKs {
            if let img = extractIcon(fromAPK: apk) {
                return img
            }
        }

        return nil
    }

    public func extractIcon(fromAPK apkURL: URL) -> NSImage? {
        // Query APK zip entries for largest icon PNG
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-l", apkURL.path]
        let pipe = Pipe()
        unzip.standardOutput = pipe
        try? unzip.run()
        unzip.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let list = String(data: data, encoding: .utf8) else { return nil }

        var bestEntry: (path: String, size: Int)?
        for line in list.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0.isWhitespace })
            guard parts.count >= 4 else { continue }
            let sizeStr = parts[0]
            let path = String(parts[3...].joined(separator: " "))
            guard path.hasSuffix(".png"), !path.contains(".9.png") else { continue }

            let isLauncher = path.contains("ic_launcher") || path.contains("app_icon") || path.contains("icon")
            let size = Int(sizeStr) ?? 0

            if isLauncher && size > (bestEntry?.size ?? 0) {
                bestEntry = (path: path, size: size)
            }
        }

        // Fallback: if no launcher name found, look in res/ for common icon files
        if bestEntry == nil {
            for line in list.split(separator: "\n") {
                let parts = line.split(whereSeparator: { $0.isWhitespace })
                guard parts.count >= 4 else { continue }
                let sizeStr = parts[0]
                let path = String(parts[3...].joined(separator: " "))
                if path.hasSuffix(".png"), !path.contains(".9.png") {
                    let size = Int(sizeStr) ?? 0
                    // Heuristic: App icons are usually 15KB - 150KB
                    if size > 15000 && size < 250000 && size > (bestEntry?.size ?? 0) {
                        bestEntry = (path: path, size: size)
                    }
                }
            }
        }

        guard let target = bestEntry else { return nil }

        let extractProc = Process()
        extractProc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        extractProc.arguments = ["-p", apkURL.path, target.path]
        let outPipe = Pipe()
        extractProc.standardOutput = outPipe
        try? extractProc.run()
        extractProc.waitUntilExit()

        let pngData = outPipe.fileHandleForReading.readDataToEndOfFile()
        guard !pngData.isEmpty else { return nil }
        return NSImage(data: pngData)
    }

    private func brandColors(for package: String) -> [NSColor] {
        let pkg = package.lowercased()
        if pkg.contains("facebook") {
            return [
                NSColor(red: 0.05, green: 0.45, blue: 0.98, alpha: 1.0), // Authentic Facebook Blue #0866FE
                NSColor(red: 0.0, green: 0.32, blue: 0.88, alpha: 1.0)
            ]
        }
        if pkg.contains("aurora") {
            return [
                NSColor(red: 0.0, green: 0.75, blue: 0.65, alpha: 1.0),  // Teal / Cyan
                NSColor(red: 0.0, green: 0.52, blue: 0.82, alpha: 1.0)
            ]
        }
        if pkg.contains("settings") {
            return [
                NSColor(red: 0.55, green: 0.58, blue: 0.62, alpha: 1.0),
                NSColor(red: 0.38, green: 0.41, blue: 0.45, alpha: 1.0)
            ]
        }
        if pkg.contains("instagram") {
            return [
                NSColor(red: 0.51, green: 0.23, blue: 0.74, alpha: 1.0),
                NSColor(red: 0.96, green: 0.22, blue: 0.35, alpha: 1.0)
            ]
        }
        if pkg.contains("whatsapp") {
            return [
                NSColor(red: 0.15, green: 0.83, blue: 0.40, alpha: 1.0),
                NSColor(red: 0.07, green: 0.55, blue: 0.49, alpha: 1.0)
            ]
        }
        if pkg.contains("youtube") {
            return [
                NSColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0),
                NSColor(red: 0.80, green: 0.0, blue: 0.0, alpha: 1.0)
            ]
        }
        if pkg.contains("spotify") {
            return [
                NSColor(red: 0.12, green: 0.84, blue: 0.38, alpha: 1.0),
                NSColor(red: 0.08, green: 0.65, blue: 0.28, alpha: 1.0)
            ]
        }
        if pkg.contains("reddit") {
            return [
                NSColor(red: 1.0, green: 0.27, blue: 0.0, alpha: 1.0),
                NSColor(red: 0.85, green: 0.20, blue: 0.0, alpha: 1.0)
            ]
        }
        if pkg.contains("twitter") || pkg.contains("x.android") {
            return [
                NSColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1.0),
                NSColor(red: 0.02, green: 0.02, blue: 0.02, alpha: 1.0)
            ]
        }

        // Default: generate harmonious palette from package hash
        let hash = abs(package.hashValue)
        let hue = CGFloat(hash % 360) / 360.0
        let col1 = NSColor(hue: hue, saturation: 0.75, brightness: 0.88, alpha: 1.0)
        let col2 = NSColor(hue: hue, saturation: 0.85, brightness: 0.70, alpha: 1.0)
        return [col1, col2]
    }

    private func brandSymbol(for package: String, title: String) -> String {
        let pkg = package.lowercased()
        if pkg.contains("facebook") { return "f" }
        if pkg.contains("aurora") { return "A" }
        if pkg.contains("settings") { return "⚙" }
        if pkg.contains("instagram") { return "📸" }
        if pkg.contains("whatsapp") { return "💬" }
        if pkg.contains("youtube") { return "▶" }
        if pkg.contains("spotify") { return "♫" }
        if pkg.contains("reddit") { return "🤖" }
        if pkg.contains("twitter") || pkg.contains("x.android") { return "𝕏" }

        // First letter of title
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = clean.first {
            return String(first).uppercased()
        }
        return "A"
    }

    public func makeSquircleIcon(colors: [NSColor], symbol: String) -> NSImage {
        let size = NSSize(width: 512, height: 512)
        let image = NSImage(size: size)
        image.lockFocus()
        guard let ctx = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return image
        }

        // macOS Big Sur squircle container (approx 420x420 inside 512x512)
        let iconRect = NSRect(x: 46, y: 46, width: 420, height: 420)
        let cornerRadius: CGFloat = 94
        let path = NSBezierPath(roundedRect: iconRect, xRadius: cornerRadius, yRadius: cornerRadius)

        // Drop shadow
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowOffset = NSSize(width: 0, height: -14)
        shadow.shadowBlurRadius = 24
        shadow.set()

        // Background Gradient
        let cgColors = colors.map { $0.cgColor } as CFArray
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        if let gradient = CGGradient(colorsSpace: colorSpace, colors: cgColors, locations: [0.0, 1.0]) {
            ctx.saveGState()
            path.addClip()
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 256, y: 466), end: CGPoint(x: 256, y: 46), options: [])
            ctx.restoreGState()
        }

        // Inner border highlight
        ctx.saveGState()
        path.lineWidth = 1.5
        NSColor.white.withAlphaComponent(0.3).setStroke()
        path.stroke()
        ctx.restoreGState()

        // Foreground Symbol
        let fontSize: CGFloat = symbol.count == 1 ? 210 : 160
        let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        let textShadow = NSShadow()
        textShadow.shadowColor = NSColor.black.withAlphaComponent(0.20)
        textShadow.shadowOffset = NSSize(width: 0, height: -5)
        textShadow.shadowBlurRadius = 10

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .shadow: textShadow
        ]
        let str = NSAttributedString(string: symbol, attributes: attrs)
        let strSize = str.size()
        let textRect = NSRect(
            x: (512 - strSize.width) / 2,
            y: (512 - strSize.height) / 2 - 8,
            width: strSize.width,
            height: strSize.height
        )
        str.draw(in: textRect)

        image.unlockFocus()
        return image
    }

    public func makeSquircleIcon(innerImage: NSImage, colors: [NSColor]) -> NSImage {
        let size = NSSize(width: 512, height: 512)
        let image = NSImage(size: size)
        image.lockFocus()
        guard let ctx = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return image
        }

        let iconRect = NSRect(x: 46, y: 46, width: 420, height: 420)
        let cornerRadius: CGFloat = 94
        let path = NSBezierPath(roundedRect: iconRect, xRadius: cornerRadius, yRadius: cornerRadius)

        // Drop shadow
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowOffset = NSSize(width: 0, height: -14)
        shadow.shadowBlurRadius = 24
        shadow.set()

        // Background Gradient
        let cgColors = colors.map { $0.cgColor } as CFArray
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        if let gradient = CGGradient(colorsSpace: colorSpace, colors: cgColors, locations: [0.0, 1.0]) {
            ctx.saveGState()
            path.addClip()
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 256, y: 466), end: CGPoint(x: 256, y: 46), options: [])
            ctx.restoreGState()
        }

        // Inner border highlight
        ctx.saveGState()
        path.lineWidth = 1.5
        NSColor.white.withAlphaComponent(0.3).setStroke()
        path.stroke()
        ctx.restoreGState()

        // Draw inner authentic logo scaled to ~260x260 in center
        let innerSize: CGFloat = 260
        let innerRect = NSRect(
            x: (512 - innerSize) / 2,
            y: (512 - innerSize) / 2,
            width: innerSize,
            height: innerSize
        )
        innerImage.draw(in: innerRect, from: .zero, operation: .sourceOver, fraction: 1.0)

        image.unlockFocus()
        return image
    }

    public func createICNS(from image: NSImage, destinationURL: URL) throws {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let pngData = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "IconManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create PNG data"])
        }

        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let iconsetDir = tmpDir.appendingPathComponent("AppIcon.iconset")
        try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

        let srcPNG = tmpDir.appendingPathComponent("source.png")
        try pngData.write(to: srcPNG)

        let sizes = [16, 32, 64, 128, 256, 512]
        for s in sizes {
            let p1 = Process()
            p1.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
            p1.arguments = ["-z", "\(s)", "\(s)", srcPNG.path, "--out", iconsetDir.appendingPathComponent("icon_\(s)x\(s).png").path]
            try? p1.run()
            p1.waitUntilExit()

            let p2 = Process()
            p2.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
            let s2 = min(512, s * 2)
            p2.arguments = ["-z", "\(s2)", "\(s2)", srcPNG.path, "--out", iconsetDir.appendingPathComponent("icon_\(s)x\(s)@2x.png").path]
            try? p2.run()
            p2.waitUntilExit()
        }

        let iconutil = Process()
        iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        iconutil.arguments = ["-c", "icns", iconsetDir.path, "-o", destinationURL.path]
        try? iconutil.run()
        iconutil.waitUntilExit()

        try? FileManager.default.removeItem(at: tmpDir)
    }

    public func installIcon(for package: String, appName: String, in appBundleURL: URL) {
        let contentsURL = appBundleURL.appendingPathComponent("Contents", isDirectory: true)
        let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)
        let icnsURL = resourcesURL.appendingPathComponent("AppIcon.icns")

        let iconImage = icon(for: package, title: appName)
        try? createICNS(from: iconImage, destinationURL: icnsURL)

        // Ensure Info.plist specifies CFBundleIconFile
        let plistURL = contentsURL.appendingPathComponent("Info.plist")
        if var dict = (try? PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), options: [], format: nil)) as? [String: Any] {
            dict["CFBundleIconFile"] = "AppIcon"
            if let updatedData = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0) {
                try? updatedData.write(to: plistURL)
            }
        }

        // Invalidate LaunchServices cache
        let touch = Process()
        touch.executableURL = URL(fileURLWithPath: "/usr/bin/touch")
        touch.arguments = [appBundleURL.path]
        try? touch.run()
        touch.waitUntilExit()
    }
}
