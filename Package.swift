// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PrompTTY",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "WorkspaceModel", targets: ["WorkspaceModel"]),
        .library(name: "GhosttyBridge", targets: ["GhosttyBridge"]),
        .library(name: "Preferences", targets: ["Preferences"]),
        .library(name: "CommandEditing", targets: ["CommandEditing"]),
        .library(name: "PaneActivity", targets: ["PaneActivity"]),
        .library(name: "CommandBlocks", targets: ["CommandBlocks"]),
    ],
    dependencies: [
        // libghostty-spm's GhosttyKit, built locally with PrompTTY's engine patches
        // (Engine/patches; script/build-engine).
        .package(path: "Engine"),
    ],
    targets: [
        .target(name: "WorkspaceModel"),
        .target(name: "Preferences"),
        .target(name: "CommandEditing"),
        .testTarget(name: "CommandEditingTests", dependencies: ["CommandEditing"]),
        .target(name: "PaneActivity"),
        .testTarget(name: "PaneActivityTests", dependencies: ["PaneActivity"]),
        .target(name: "CommandBlocks"),
        .testTarget(name: "CommandBlocksTests", dependencies: ["CommandBlocks"]),
        .testTarget(name: "PreferencesTests", dependencies: ["Preferences"]),
        .target(
            name: "GhosttyBridge",
            dependencies: [
                "CommandBlocks",
                .product(name: "GhosttyKit", package: "Engine"),
                .product(name: "GhosttyKitResources", package: "Engine"),
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
                "Preferences",
                .product(name: "GhosttyKit", package: "Engine"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
