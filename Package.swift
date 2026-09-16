// swift-tools-version: 6.1

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
    dependencies: [
        // Pinned exactly: the notarization broker builds with
        // `--only-use-versions-from-resolved-file` against its own copy of Package.resolved.
        .package(url: "https://github.com/mxcl/AppUpdater.git", exact: "4.1.2"),
    ],
    targets: [
        .target(
            name: "OpenDefendrWatchrKit",
            dependencies: [.product(name: "AppUpdater", package: "AppUpdater")],
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
