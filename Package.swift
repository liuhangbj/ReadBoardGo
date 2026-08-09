// swift-tools-version:6.0
import Foundation
import PackageDescription

let configuredCorePath = ProcessInfo.processInfo.environment["READBOARD_CORE_PATH"]
    ?? "../readboard"
let hasLocalCore = FileManager.default.fileExists(
    atPath: URL(fileURLWithPath: configuredCorePath)
        .appendingPathComponent("Package.swift").path)
let readBoardDependency: Package.Dependency = hasLocalCore
    ? .package(path: configuredCorePath)
    : .package(url: "https://github.com/liuhangbj/ReadBoard.git", branch: "main")

let package = Package(
    name: "ReadBoardGo",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ReadBoardGoCore", targets: ["ReadBoardGoCore"]),
        .library(name: "ReadBoardSharedUI", targets: ["ReadBoardSharedUI"]),
        .library(name: "ReadBoardCoreSnapshot", targets: ["ReadBoardCoreSnapshot"]),
    ],
    dependencies: [readBoardDependency],
    targets: [
        .target(
            name: "ReadBoardCoreSnapshot",
            dependencies: [
                .product(name: "ReadBoardContract", package: "ReadBoard"),
                .product(name: "ReadBoardUI", package: "ReadBoard"),
                .product(name: "ReadBoardFeatures", package: "ReadBoard"),
                "ReadBoardSharedUI",
            ],
            path: "CoreSnapshot/Sources/ReadBoardCoreSnapshot",
            resources: [
                .copy("Resources/migrations"),
                .copy("Resources/engine"),
            ]
        ),
        .target(
            name: "ReadBoardSharedUI",
            dependencies: [
                .product(name: "ReadBoardContract", package: "ReadBoard"),
                .product(name: "ReadBoardUI", package: "ReadBoard"),
            ]
        ),
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
            ]
        ),
        .testTarget(
            name: "ReadBoardSharedUITests",
            dependencies: ["ReadBoardSharedUI"]
        ),
    ]
)
