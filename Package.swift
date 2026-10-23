// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Burn",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Burn",
            resources: [.copy("Resources")],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
    ]
)
