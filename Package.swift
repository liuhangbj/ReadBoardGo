// swift-tools-version:6.0
import Foundation
import PackageDescription

let configuredCorePath = ProcessInfo.processInfo.environment["READBOARD_CORE_PATH"]
let coreRevision = ProcessInfo.processInfo.environment["READBOARD_CORE_REF"]
    ?? "6aec0a0f1e692a8219d0543f7ab63e17007425fa"
let hasLocalCore = configuredCorePath.map { path in
    FileManager.default.fileExists(
        atPath: URL(fileURLWithPath: path)
            .appendingPathComponent("Package.swift").path)
} ?? false
let readBoardDependency: Package.Dependency = hasLocalCore
    ? .package(path: configuredCorePath!)
    : .package(url: "https://github.com/liuhangbj/ReadBoard.git", revision: coreRevision)

let package = Package(
    name: "ReadBoardGo",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ReadBoardGoCore", targets: ["ReadBoardGoCore"]),
    ],
    dependencies: [readBoardDependency],
    targets: [
        .target(
            name: "ReadBoardGoCore",
            dependencies: [
                .product(name: "ReadBoardContract", package: "ReadBoard"),
                .product(name: "ReadBoardRemote", package: "ReadBoard"),
                .product(name: "ReadBoardUI", package: "ReadBoard"),
                .product(name: "ReadBoardFeatures", package: "ReadBoard"),
            ]
        ),
        .testTarget(
            name: "ReadBoardGoCoreTests",
            dependencies: [
                "ReadBoardGoCore",
                .product(name: "ReadBoardRemote", package: "ReadBoard"),
            ],
            exclude: ["Fixtures"]
        ),
    ]
)
