// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Seance",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Seance", targets: ["Seance"]),
        .executable(name: "SeanceCLI", targets: ["SeanceCLI"]),
        .library(name: "SeanceCore", targets: ["SeanceCore"]),
    ],
    targets: [
        .target(name: "SeanceCore"),
        .target(name: "SeanceIPC"),
        .target(name: "SeanceMCP", dependencies: ["SeanceCore", "SeanceIPC"]),
        .executableTarget(name: "SeanceCLI", dependencies: ["SeanceIPC"]),
        .testTarget(name: "SeanceMCPTests", dependencies: ["SeanceMCP", "SeanceCore", "SeanceCLI"]),
        .executableTarget(name: "Seance", dependencies: ["SeanceCore", "SeanceMCP"]),
        .testTarget(name: "SeanceCoreTests", dependencies: ["SeanceCore"]),
    ]
)
