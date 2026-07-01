// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CompanionServer",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "CompanionServer", targets: ["CompanionServer"]),
        .executable(name: "TestClient", targets: ["TestClient"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-configuration", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "CompanionEnv",
            dependencies: [
                .product(name: "Configuration", package: "swift-configuration"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .executableTarget(
            name: "CompanionServer",
            dependencies: [
                "CompanionEnv",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .executableTarget(
            name: "TestClient",
            dependencies: [
                "CompanionEnv",
                .product(name: "Logging", package: "swift-log"),
            ],
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/TestClient/Info.plist",
                ], .when(platforms: [.macOS])),
            ]
        ),
        .testTarget(
            name: "CompanionServerTests",
            dependencies: ["CompanionServer", "TestClient"]
        ),
    ]
)
