// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MazeSaver",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "MazeCore",
            path: "Sources/MazeCore"
        ),
        .executableTarget(
            name: "MazeSaverApp",
            dependencies: ["MazeCore"],
            path: "Sources/MazeSaverApp"
        )
    ]
)
