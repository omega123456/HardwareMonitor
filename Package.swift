// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "HardwareMonitor",
    platforms: [.macOS("26.0")],
    dependencies: [
        // Tests only (snapshot tests need XCTest, i.e. Xcode: run them with scripts/test.sh). NFR-5.
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.19.6"),
    ],
    targets: [
        .executableTarget(
            name: "HardwareMonitor",
            path: "Sources/HardwareMonitor",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("IOReport")] // the system libIOReport (DD-7)
        ),
        .testTarget(
            name: "HardwareMonitorTests",
            dependencies: ["HardwareMonitor", .product(name: "SnapshotTesting", package: "swift-snapshot-testing")],
            path: "Tests/HardwareMonitorTests",
            exclude: ["__Snapshots__"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
