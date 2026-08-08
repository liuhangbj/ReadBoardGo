// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ReadBoardGo",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ReadBoardGoCore", targets: ["ReadBoardGoCore"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/liuhangbj/ReadBoard.git",
            branch: "codex/service-middleware-foundation"
        ),
    ],
    targets: [
        .target(
            name: "ReadBoardGoCore",
            dependencies: [
                .product(name: "ReadBoardContract", package: "ReadBoard"),
                .product(name: "ReadBoardRemote", package: "ReadBoard"),
            ]
        ),
        .testTarget(
            name: "ReadBoardGoCoreTests",
            dependencies: ["ReadBoardGoCore"]
        ),
    ]
)
