// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacSubsystemForAndroid",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "MSACore", targets: ["MSACore"]),
        .executable(name: "msa", targets: ["MSAApp"]),
        .executable(name: "msa-cli", targets: ["MSACLI"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "MSACore",
            dependencies: [],
            path: "Sources/MSACore"
        ),
        .executableTarget(
            name: "MSAApp",
            dependencies: ["MSACore"],
            path: "Sources/MSAApp"
        ),
        .executableTarget(
            name: "MSACLI",
            dependencies: ["MSACore"],
            path: "Sources/MSACLI"
        ),
        .testTarget(
            name: "MSACoreTests",
            dependencies: ["MSACore"],
            path: "Tests/MSACoreTests"
        )
    ]
)
