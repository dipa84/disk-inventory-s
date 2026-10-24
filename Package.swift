// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DiskInventoryS",
    platforms: [.macOS(.v15)],
    targets: [
        // scanning, the tree, file kinds and the treemap: no user interface
        .target(name: "DiskInventoryCore"),
        // the app (AppKit)
        .executableTarget(name: "DiskInventoryS", dependencies: ["DiskInventoryCore"]),
        // command line: timings, the icon, and the helper that reads system folders as root
        .executableTarget(name: "dis-cli", dependencies: ["DiskInventoryCore"]),
        // the tests: without Xcode the Testing framework does not run them, hence an executable
        .executableTarget(name: "dis-tests", dependencies: ["DiskInventoryCore"]),
    ],
    swiftLanguageModes: [.v5]
)
