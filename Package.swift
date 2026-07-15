// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AppleMusicBar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "AppleMusicBar", targets: ["AppleMusicBar"])
    ],
    targets: [
        .executableTarget(
            name: "AppleMusicBar",
            path: "Sources/AppleMusicBar",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "AppleMusicBarTests",
            dependencies: ["AppleMusicBar"],
            path: "Tests/AppleMusicBarTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
