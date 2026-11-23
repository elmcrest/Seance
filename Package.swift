// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Seance",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Seance", targets: ["Seance"]),
        .library(name: "SeanceCore", targets: ["SeanceCore"]),
    ],
    targets: [
        .target(name: "SeanceCore"),
        .executableTarget(name: "Seance", dependencies: ["SeanceCore"]),
        .testTarget(name: "SeanceCoreTests", dependencies: ["SeanceCore"]),
    ]
)
