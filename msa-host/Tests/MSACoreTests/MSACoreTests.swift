import XCTest
import CoreGraphics
@testable import MSACore

final class MSACoreTests: XCTestCase {
    func testWaylandHeaderSerialization() {
        let original = WaylandHeader(objectId: 42, opcode: 3, size: 24)
        let data = original.serialize()
        XCTAssertEqual(data.count, 8)

        let parsed = WaylandHeader.parse(from: data)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.objectId, 42)
        XCTAssertEqual(parsed?.opcode, 3)
        XCTAssertEqual(parsed?.size, 24)
    }

    func testWaylandProtocolStringEncoding() {
        let string = "wl_compositor"
        let encoded = WaylandMessage.encodeString(string)
        // 4 bytes length + 13 chars + 1 null + 2 bytes padding = 20 bytes (aligned to 4)
        XCTAssertEqual(encoded.count % 4, 0)
        let length = encoded.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
        XCTAssertEqual(length, UInt32(string.utf8.count + 1))
    }

    func testWaylandGlobalEventSerialization() {
        let event = WaylandMessage.globalEvent(registryId: 2, name: 1, interface: "wl_compositor", version: 4)
        let data = event.serialize()
        XCTAssertGreaterThan(data.count, 8)
        let header = WaylandHeader.parse(from: data)
        XCTAssertEqual(header?.objectId, 2)
        XCTAssertEqual(header?.opcode, 0)
    }

    func testADBLocator() {
        let adb = PackageInstaller.locateADB()
        XCTAssertNotNil(adb, "Should discover adb installed on macOS (e.g. Homebrew or Android SDK)")
    }

    func testWaylandBufferCGImageCreation() {
        // Create 2x2 ARGB pixel data (4 pixels * 4 bytes = 16 bytes)
        var pixels: [UInt32] = [
            0xFFFF0000, 0xFF00FF00,
            0xFF0000FF, 0xFFFFFFFF
        ]
        let data = Data(bytes: &pixels, count: pixels.count * 4)

        let buffer = WaylandBuffer(
            id: 1,
            width: 2,
            height: 2,
            stride: 8,
            format: .argb8888,
            data: data
        )

        let cgImage = buffer.createCGImage()
        XCTAssertNotNil(cgImage)
        XCTAssertEqual(cgImage?.width, 2)
        XCTAssertEqual(cgImage?.height, 2)
    }

    func testInputBridgeTranslation() {
        // Test key translations
        XCTAssertEqual(InputBridge.linuxKeycode(from: 0), 30) // A -> KEY_A
        XCTAssertEqual(InputBridge.linuxKeycode(from: 36), 28) // Return -> KEY_ENTER
        XCTAssertEqual(InputBridge.linuxKeycode(from: 49), 57) // Space -> KEY_SPACE
        XCTAssertEqual(InputBridge.linuxKeycode(from: 53), 1)  // Esc -> KEY_ESC

        // Test button constants
        XCTAssertEqual(InputBridge.BTN_LEFT, 0x110)
        XCTAssertEqual(InputBridge.BTN_RIGHT, 0x111)
        XCTAssertEqual(InputBridge.BTN_MIDDLE, 0x112)
    }

    func testAppShimGeneration() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let meta = AppShimMetadata(
            appName: "TestCalculator",
            packageName: "com.android.calculator2",
            activityName: "com.android.calculator2.Calculator"
        )

        let shimURL = try AppShimGenerator.createShim(for: meta, in: tempDir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: shimURL.path))

        let infoPlistURL = shimURL.appendingPathComponent("Contents/Info.plist")
        XCTAssertTrue(FileManager.default.fileExists(atPath: infoPlistURL.path))

        let launcherURL = shimURL.appendingPathComponent("Contents/MacOS/launcher")
        XCTAssertTrue(FileManager.default.fileExists(atPath: launcherURL.path))

        let script = try String(contentsOf: launcherURL, encoding: .utf8)
        XCTAssertTrue(script.contains("com.android.calculator2"))
    }

    @MainActor
    func testVMConfigurationValidation() {
        let dummyKernel = URL(fileURLWithPath: "/nonexistent/vmlinuz")
        let dummyDisk = URL(fileURLWithPath: "/nonexistent/rootfs.img")
        let dummyShared = URL(fileURLWithPath: "/nonexistent/shared")

        let config = VMConfiguration(
            kernelURL: dummyKernel,
            diskImageURL: dummyDisk,
            sharedDirURL: dummyShared,
            cpuCount: 1, // Will fail validation if below minAllowed
            memoryBytes: 512 * 1024 * 1024 // 512MB
        )

        XCTAssertThrowsError(try VMConfigurationBuilder.build(from: config)) { error in
            XCTAssertTrue(error is VMConfigurationError)
        }
    }
}
