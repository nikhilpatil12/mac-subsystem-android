import Foundation

public enum PackageInstallError: Error, LocalizedError {
    case fileNotFound(String)
    case invalidAPKFormat
    case adbNotFound
    case subsystemOffline
    case adbFailed(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "APK file not found at: \(path)"
        case .invalidAPKFormat:
            return "File does not appear to be a valid Android APK."
        case .adbNotFound:
            return "Android Debug Bridge (adb) was not found. Install it via `brew install android-platform-tools`."
        case .subsystemOffline:
            return "The Android subsystem is not running or ADB is not connected. Start it with `msa-cli start` in another terminal or launch the MSA menu bar app."
        case .adbFailed(let reason):
            return "Installation failed: \(reason)"
        }
    }
}

public struct PackageInstaller {
    public static func locateADB() -> String? {
        let candidates = [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Android/sdk/platform-tools/adb").path
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["adb"]
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return str.isEmpty ? nil : str
    }

    public static func install(apkURL: URL, adbPath: String? = nil) async throws {
        guard FileManager.default.fileExists(atPath: apkURL.path) else {
            throw PackageInstallError.fileNotFound(apkURL.path)
        }

        guard apkURL.pathExtension.lowercased() == "apk" else {
            throw PackageInstallError.invalidAPKFormat
        }

        guard let adb = adbPath ?? locateADB() else {
            throw PackageInstallError.adbNotFound
        }

        // 1. Automatically connect to subsystem adb port
        let connectProcess = Process()
        connectProcess.executableURL = URL(fileURLWithPath: adb)
        connectProcess.arguments = ["connect", "127.0.0.1:5555"]
        try? connectProcess.run()
        connectProcess.waitUntilExit()

        // 2. Run adb install
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: adb)
        process.arguments = ["install", "-r", apkURL.path]
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        if output.contains("no devices/emulators found") || output.contains("device offline") {
            throw PackageInstallError.subsystemOffline
        }

        guard process.terminationStatus == 0 && output.contains("Success") else {
            throw PackageInstallError.adbFailed(output)
        }
    }
}
