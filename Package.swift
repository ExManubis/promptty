// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PrompTTY",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "WorkspaceModel", targets: ["WorkspaceModel"]),
        .library(name: "GhosttyBridge", targets: ["GhosttyBridge"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sethdeckard/libghostty-spm", exact: "0.2.0"),
    ],
    targets: [
        .target(name: "WorkspaceModel"),
        .target(
            name: "GhosttyBridge",
            dependencies: [
                .product(name: "GhosttyKit", package: "libghostty-spm"),
                .product(name: "GhosttyKitResources", package: "libghostty-spm"),
            ],
            linkerSettings: [
                // The GhosttyKit static library carries no autolink directives.
                .linkedLibrary("c++"),
                .linkedFramework("Carbon"),
            ]
        ),
        .testTarget(name: "WorkspaceModelTests", dependencies: ["WorkspaceModel"]),
        .testTarget(
            name: "GhosttyBridgeTests",
            dependencies: [
                "GhosttyBridge",
                .product(name: "GhosttyKit", package: "libghostty-spm"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
