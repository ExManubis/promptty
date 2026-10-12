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
    ],
    dependencies: [
        .package(url: "https://github.com/sethdeckard/libghostty-spm", exact: "0.2.0"),
    ],
    targets: [
        .target(name: "WorkspaceModel"),
        .target(name: "Preferences"),
        .target(name: "CommandEditing"),
        .testTarget(name: "CommandEditingTests", dependencies: ["CommandEditing"]),
        .target(name: "PaneActivity"),
        .testTarget(name: "PaneActivityTests", dependencies: ["PaneActivity"]),
        .testTarget(name: "PreferencesTests", dependencies: ["Preferences"]),
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
                "Preferences",
                .product(name: "GhosttyKit", package: "libghostty-spm"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
