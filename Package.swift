// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "OpenDefendrWatchr",
    platforms: [.macOS(.v14)],
    products: [
        .library(
            name: "OpenDefendrWatchrKit",
            targets: ["OpenDefendrWatchrKit"]
        ),
        .executable(
            name: "OpenDefendrWatchr",
            targets: ["OpenDefendrWatchrApp"]
        ),
    ],
    targets: [
        .target(
            name: "OpenDefendrWatchrKit",
            path: "Sources/OpenDefendrWatchr",
            exclude: ["Info.plist"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "OpenDefendrWatchrApp",
            dependencies: ["OpenDefendrWatchrKit"],
            path: "Sources/OpenDefendrWatchrApp",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "OpenDefendrWatchrTests",
            dependencies: ["OpenDefendrWatchrKit"],
            path: "Tests/OpenDefendrWatchrTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
