// swift-tools-version: 6.0
//
// libghostty for PrompTTY: the GhosttyKit xcframework and resource tree of libghostty-spm
// (sethdeckard/libghostty-spm, pinned in script/build-engine), built locally from its pinned
// Ghostty source with PrompTTY's engine patches in patches/ applied on top. Same products and
// module names as the package it replaces, so `import GhosttyKit` is unchanged.
//
// GhosttyKit.xcframework and Sources/GhosttyKitResources/Resources are build output of
// script/build-engine and not committed.

import PackageDescription

let package = Package(
    name: "Engine",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "GhosttyKit", targets: ["GhosttyKit"]),
        .library(name: "GhosttyKitResources", targets: ["GhosttyKitResources"]),
    ],
    targets: [
        .binaryTarget(name: "GhosttyKit", path: "GhosttyKit.xcframework"),
        // `.copy`: hundreds of theme files and compiled terminfo, shipped byte for byte.
        .target(name: "GhosttyKitResources", resources: [.copy("Resources")]),
    ]
)
