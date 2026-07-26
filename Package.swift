// swift-tools-version: 6.0

import Foundation
import PackageDescription

let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let embeddedInfoPlistPath = packageDirectory
    .appendingPathComponent("Resources/EmbeddedInfo.plist")
    .path

let package = Package(
    name: "AppleMusicBar",
    platforms: [
        .macOS(.v14)
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
            ],
            linkerSettings: [
                // Xcode runs SwiftPM executables without an app bundle. Embed only
                // the AutoFill preference; app-bundle metadata breaks that launch mode.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", embeddedInfoPlistPath
                ])
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
