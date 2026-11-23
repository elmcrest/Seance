// swift-tools-version: 6.0
import Foundation
import PackageDescription

let package = Package(
    name: "Seance",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SeanceCore", targets: ["SeanceCore"]),
    ],
    targets: [
        .target(name: "SeanceCore"),
        .testTarget(name: "SeanceCoreTests", dependencies: ["SeanceCore"]),
    ]
)

// Core tests can run in a fresh checkout. The app target becomes available
// once scripts/prepare-ghostty has built the pinned native framework.
let framework = ".build/vendor/ghostty/macos/GhosttyKit.xcframework"
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
if FileManager.default.fileExists(atPath: root.appendingPathComponent(framework).path) {
    package.products.append(.executable(name: "Seance", targets: ["Seance"]))
    package.targets.append(.binaryTarget(name: "GhosttyKit", path: framework))
    package.targets.append(.executableTarget(
        name: "Seance",
        dependencies: ["SeanceCore", "GhosttyKit"],
        linkerSettings: [
            .linkedLibrary("c++"), .linkedFramework("Carbon"),
            .linkedFramework("CoreText"), .linkedFramework("CoreVideo"),
            .linkedFramework("IOSurface"), .linkedFramework("Metal"),
            .linkedFramework("QuartzCore"),
        ]
    ))
}
