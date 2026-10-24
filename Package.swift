// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PrompTTY",
    // iOS for the portable modules the iPhone app shares (docs/DEVELOPMENT.md lists them); their
    // Mac-only parts are behind `#if os(macOS)`. GhosttyBridge and the executables are macOS only;
    // GhosttyMirror is the iPhone's libghostty (empty on macOS).
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "WorkspaceModel", targets: ["WorkspaceModel"]),
        .library(name: "GhosttyBridge", targets: ["GhosttyBridge"]),
        // The iPhone's terminal: a libghostty surface fed a pane's bytes from the Mac.
        .library(name: "GhosttyMirror", targets: ["GhosttyMirror"]),
        .library(name: "Preferences", targets: ["Preferences"]),
        .library(name: "CommandEditing", targets: ["CommandEditing"]),
        .library(name: "PaneActivity", targets: ["PaneActivity"]),
        .library(name: "CommandBlocks", targets: ["CommandBlocks"]),
        .library(name: "AgentHooks", targets: ["AgentHooks"]),
        // The SwiftUI chrome the Mac app and the iPhone app share: program tiles, activity, rows.
        .library(name: "PrompTTYChrome", targets: ["PrompTTYChrome"]),
        // Claude Code's (and Codex's) hooks run it to tell the app what the agent does; the app
        // bundle carries its own copy (project.yml).
        .executable(name: "promptty-hook", targets: ["promptty-hook"]),
        .library(name: "RemoteControl", targets: ["RemoteControl"]),
        // The messages the Mac's remote API and the iPhone app send each other.
        .library(name: "RemoteProtocol", targets: ["RemoteProtocol"]),
        .library(name: "RemoteServer", targets: ["RemoteServer"]),
        // The iPhone app's side of the remote API.
        .library(name: "RemoteClient", targets: ["RemoteClient"]),
        // `promptty`, the command line every pane has on its PATH; the app bundle carries its own
        // copy (project.yml).
        .executable(name: "promptty", targets: ["promptty"]),
        // What the app and prompttyd say to each other.
        .library(name: "SessionProtocol", targets: ["SessionProtocol"]),
        // prompttyd, which runs the panes' programs on ptys of its own so they outlive the app
        // (PTY-77); the app bundle carries it (project.yml).
        .executable(name: "prompttyd", targets: ["prompttyd"]),
        .library(name: "SessionDaemonCore", targets: ["SessionDaemonCore"]),
    ],
    dependencies: [
        // libghostty's GhosttyKit, built locally with PrompTTY's engine patches
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
        .target(name: "AgentHooks"),
        .target(name: "PrompTTYChrome", dependencies: ["PaneActivity"], resources: [.process("ProgramLogos.xcassets")]),
        .executableTarget(name: "promptty-hook", dependencies: ["AgentHooks"]),
        // Depends on the helper so `swift test` builds it: the tests run it.
        .testTarget(name: "AgentHooksTests", dependencies: ["AgentHooks", "promptty-hook"]),
        .testTarget(name: "PreferencesTests", dependencies: ["Preferences"]),
        .target(name: "RemoteControl", dependencies: ["AgentHooks"]),
        .executableTarget(name: "promptty", dependencies: ["RemoteControl"]),
        .testTarget(name: "RemoteControlTests", dependencies: ["RemoteControl"]),
        .target(name: "RemoteProtocol", dependencies: ["RemoteControl"]),
        // The remote API's server, in the Mac app only (Network.framework, the `tailscale` command).
        .target(name: "RemoteServer", dependencies: ["RemoteProtocol", "RemoteControl"]),
        .testTarget(name: "RemoteServerTests", dependencies: ["RemoteServer", "RemoteClient"]),
        .target(name: "RemoteClient", dependencies: ["RemoteProtocol"]),
        .target(name: "SessionProtocol"),
        // forkpty and what the child does before exec, in C: the daemon has threads.
        .target(name: "CPtySpawn"),
        // The daemon itself; `prompttyd` is its main.
        .target(
            name: "SessionDaemonCore",
            dependencies: [
                "SessionProtocol",
                "CPtySpawn",
                .product(name: "GhosttyVt", package: "Engine"),
            ],
            linkerSettings: [.linkedLibrary("c++")]
        ),
        .executableTarget(name: "prompttyd", dependencies: ["SessionDaemonCore"]),
        .testTarget(name: "RemoteProtocolTests", dependencies: ["RemoteProtocol"], resources: [.copy("Fixtures")]),
        .target(
            name: "GhosttyBridge",
            dependencies: [
                "CommandBlocks",
                "PaneActivity",
                .product(name: "GhosttyKit", package: "Engine"),
                .product(name: "GhosttyKitResources", package: "Engine"),
            ],
            linkerSettings: [
                // The GhosttyKit static library carries no autolink directives.
                .linkedLibrary("c++"),
                .linkedFramework("Carbon"),
            ]
        ),
        // Imports GhosttyKit too (its iOS slices: script/build-engine --ios); nothing else does.
        .target(
            name: "GhosttyMirror",
            // Not GhosttyKitResources: a mirrored surface starts no shell (no terminfo or shell
            // integration), and its theme comes inline in the config.
            dependencies: [.product(name: "GhosttyKit", package: "Engine")],
            linkerSettings: [
                .linkedLibrary("c++", .when(platforms: [.iOS])),
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
