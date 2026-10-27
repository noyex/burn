// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Burn",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Burn",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(name: "BurnTests", dependencies: ["Burn"]),
    ]
)
