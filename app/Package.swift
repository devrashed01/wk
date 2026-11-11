// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Wk",
    platforms: [.macOS(.v14)],
    targets: [
        // Models, the core client and view-model logic (unit tested).
        .target(name: "WkKit"),
        // The menu-bar app itself.
        .executableTarget(name: "Wk", dependencies: ["WkKit"]),
        .testTarget(name: "WkKitTests", dependencies: ["WkKit"]),
    ],
    swiftLanguageModes: [.v5]
)
