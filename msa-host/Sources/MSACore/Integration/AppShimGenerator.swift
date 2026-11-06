import Foundation
import AppKit

public struct AppShimMetadata {
    public let appName: String
    public let packageName: String
    public let activityName: String?
    public let iconData: Data?

    public init(appName: String, packageName: String, activityName: String? = nil, iconData: Data? = nil) {
        self.appName = appName
        self.packageName = packageName
        self.activityName = activityName
        self.iconData = iconData
    }
}

public struct AppShimGenerator {
    public static let defaultAppsDirectory: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Applications/Android Apps", isDirectory: true)
    }()

    public static func createShim(for app: AppShimMetadata, in directory: URL = defaultAppsDirectory) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let appBundleURL = directory.appendingPathComponent("\(app.appName).app", isDirectory: true)
        let contentsURL = appBundleURL.appendingPathComponent("Contents", isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)

        try fileManager.createDirectory(at: macOSURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: resourcesURL, withIntermediateDirectories: true)

        // 1. Info.plist with native CFBundleIconFile
        let bundleIdentifier = "com.msa.app.\(app.packageName)"
        let infoPlist: [String: Any] = [
            "CFBundleExecutable": "launcher",
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleName": app.appName,
            "CFBundleDisplayName": app.appName,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleIconFile": "AppIcon",
            "LSUIElement": false,
            "NSHighResolutionCapable": true
        ]

        let plistData = try PropertyListSerialization.data(fromPropertyList: infoPlist, format: .xml, options: 0)
        try plistData.write(to: contentsURL.appendingPathComponent("Info.plist"))

        // 2. Install native AppIcon.icns
        IconManager.shared.installIcon(for: app.packageName, appName: app.appName, in: appBundleURL)

        // 3. Executable launcher script that preserves Dock presence while app runs
        let launcherScriptURL = macOSURL.appendingPathComponent("launcher")
        let targetActivity = app.activityName ?? ""
        let scriptContent = """
        #!/bin/sh
        # Mac Subsystem for Android Application Launcher
        PACKAGE="\(app.packageName)"
        ACTIVITY="\(targetActivity)"

        ADB_BIN="adb"
        if [ -x "$HOME/Library/Android/sdk/platform-tools/adb" ]; then
            ADB_BIN="$HOME/Library/Android/sdk/platform-tools/adb"
        elif [ -x "/opt/homebrew/bin/adb" ]; then
            ADB_BIN="/opt/homebrew/bin/adb"
        elif [ -x "/usr/local/bin/adb" ]; then
            ADB_BIN="/usr/local/bin/adb"
        fi

        # On quit / interrupt, cleanly force stop the Android package
        cleanup() {
            "$ADB_BIN" shell am force-stop "$PACKAGE" >/dev/null 2>&1
            exit 0
        }
        trap cleanup TERM INT HUP

        # Request host daemon to launch app
        if command -v msa-cli >/dev/null 2>&1; then
            msa-cli launch "$PACKAGE" "$ACTIVITY"
        elif [ -x "$HOME/.msa/bin/msa-cli" ]; then
            "$HOME/.msa/bin/msa-cli" launch "$PACKAGE" "$ACTIVITY"
        elif [ -x "/usr/local/bin/msa-cli" ]; then
            /usr/local/bin/msa-cli launch "$PACKAGE" "$ACTIVITY"
        else
            "$ADB_BIN" shell monkey -p "$PACKAGE" -c android.intent.category.LAUNCHER 1
        fi

        # Keep shim alive in macOS Dock while the app process is running
        sleep 2
        while "$ADB_BIN" shell "pidof $PACKAGE" >/dev/null 2>&1; do
            sleep 1
        done
        """
        try scriptContent.write(to: launcherScriptURL, atomically: true, encoding: .utf8)

        // Make executable (chmod +x)
        let attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o755]
        try fileManager.setAttributes(attributes, ofItemAtPath: launcherScriptURL.path)

        // Invalidate LaunchServices cache
        let touch = Process()
        touch.executableURL = URL(fileURLWithPath: "/usr/bin/touch")
        touch.arguments = [appBundleURL.path]
        try? touch.run()
        touch.waitUntilExit()

        return appBundleURL
    }

    public static func refreshAllShims(in directory: URL = defaultAppsDirectory) {
        let fileManager = FileManager.default
        guard let items = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return
        }

        for item in items where item.pathExtension == "app" {
            let appName = item.deletingPathExtension().lastPathComponent
            let plistURL = item.appendingPathComponent("Contents/Info.plist")
            var pkgName = "com.android." + appName.lowercased().replacingOccurrences(of: " ", with: "")
            if let data = try? Data(contentsOf: plistURL),
               let dict = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
               let ident = dict["CFBundleIdentifier"] as? String, ident.hasPrefix("com.msa.app.") {
                pkgName = String(ident.dropFirst("com.msa.app.".count))
            } else if appName.lowercased().contains("aurora") {
                pkgName = "com.aurora.store"
            } else if appName.lowercased().contains("facebook") {
                pkgName = "com.facebook.lite"
            } else if appName.lowercased().contains("settings") {
                pkgName = "com.android.settings"
            }

            let meta = AppShimMetadata(appName: appName, packageName: pkgName)
            _ = try? createShim(for: meta, in: directory)
        }
    }
}
