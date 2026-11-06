import Foundation

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

        // 1. Info.plist
        let bundleIdentifier = "com.msa.app.\(app.packageName)"
        let infoPlist: [String: Any] = [
            "CFBundleExecutable": "launcher",
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleName": app.appName,
            "CFBundleDisplayName": app.appName,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "LSUIElement": false,
            "NSHighResolutionCapable": true
        ]

        let plistData = try PropertyListSerialization.data(fromPropertyList: infoPlist, format: .xml, options: 0)
        try plistData.write(to: contentsURL.appendingPathComponent("Info.plist"))

        // 2. Executable launcher script
        let launcherScriptURL = macOSURL.appendingPathComponent("launcher")
        let targetActivity = app.activityName ?? ""
        let scriptContent = """
        #!/bin/sh
        # Mac Subsystem for Android Application Launcher
        PACKAGE="\(app.packageName)"
        ACTIVITY="\(targetActivity)"
        
        # Request host daemon to launch app
        if command -v msa-cli >/dev/null 2>&1; then
            msa-cli launch "$PACKAGE" "$ACTIVITY"
        elif [ -x "$HOME/.msa/bin/msa-cli" ]; then
            "$HOME/.msa/bin/msa-cli" launch "$PACKAGE" "$ACTIVITY"
        elif [ -x "/usr/local/bin/msa-cli" ]; then
            /usr/local/bin/msa-cli launch "$PACKAGE" "$ACTIVITY"
        else
            adb shell monkey -p "$PACKAGE" -c android.intent.category.LAUNCHER 1
        fi
        """
        try scriptContent.write(to: launcherScriptURL, atomically: true, encoding: .utf8)

        // Make executable (chmod +x)
        let attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o755]
        try fileManager.setAttributes(attributes, ofItemAtPath: launcherScriptURL.path)

        return appBundleURL
    }
}
