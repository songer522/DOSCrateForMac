// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DOSCrateKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LibraryKit", targets: ["LibraryKit"]),
        .library(name: "ConfigKit", targets: ["ConfigKit"]),
        .library(name: "ImportKit", targets: ["ImportKit"]),
        .library(name: "LauncherKit", targets: ["LauncherKit"]),
        .library(name: "MetadataKit", targets: ["MetadataKit"]),
    ],
    targets: [
        .target(name: "LibraryKit", dependencies: []),
        .testTarget(
            name: "LibraryKitTests",
            dependencies: ["LibraryKit"],
            swiftSettings: [.unsafeFlags(["-warnings-as-errors"])]
        ),
        .target(name: "ConfigKit", dependencies: ["LibraryKit"]),
        .testTarget(
            name: "ConfigKitTests",
            dependencies: ["ConfigKit"],
            swiftSettings: [.unsafeFlags(["-warnings-as-errors"])]
        ),
        .target(name: "ImportKit", dependencies: ["LibraryKit"]),
        .testTarget(
            name: "ImportKitTests",
            dependencies: ["ImportKit"],
            swiftSettings: [.unsafeFlags(["-warnings-as-errors"])]
        ),
        .target(name: "LauncherKit", dependencies: ["ConfigKit", "LibraryKit"]),
        .testTarget(
            name: "LauncherKitTests",
            dependencies: ["LauncherKit"],
            swiftSettings: [.unsafeFlags(["-warnings-as-errors"])]
        ),
        .target(name: "MetadataKit", dependencies: ["LibraryKit"]),
        .testTarget(
            name: "MetadataKitTests",
            dependencies: ["MetadataKit"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.unsafeFlags(["-warnings-as-errors"])]
        ),
    ]
)
