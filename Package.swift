// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "GitIsland",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "GitIsland", targets: ["GitIsland"])
    ],
    targets: [
        .executableTarget(
            name: "GitIsland",
            path: "Sources/GitIsland",
            exclude: ["Support/README.md"]
        ),
        .testTarget(
            name: "GitIslandTests",
            dependencies: ["GitIsland"],
            path: "Tests/GitIslandTests"
        )
    ]
)
