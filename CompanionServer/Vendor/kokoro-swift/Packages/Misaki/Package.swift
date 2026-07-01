// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Misaki",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(
            name: "Misaki",
            targets: ["Misaki"]
        ),
    ],
    targets: [
        .target(
            name: "Misaki",
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "MisakiTests",
            dependencies: ["Misaki"]
        ),
    ]
)
