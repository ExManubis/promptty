import Foundation
import GhosttyKit
import GhosttyKitResources

/// Process-wide libghostty setup: resources directory and `ghostty_init`, exactly once.
public enum GhosttyLibrary {
    private static let initialization: Result<URL, GhosttyRuntimeError> = {
        // libghostty expects GHOSTTY_RESOURCES_DIR to be the `share/ghostty` equivalent: it reads
        // `{dir}/shell-integration` and themes from there and sets TERMINFO to `dirname(dir)/terminfo`.
        let root = GhosttyKitResources.directoryURL
        let resources = root.appendingPathComponent("ghostty")
        let terminfoEntry = root.appendingPathComponent("terminfo/78/xterm-ghostty")
        let shellIntegration = resources.appendingPathComponent("shell-integration")
        let fm = FileManager.default
        guard fm.fileExists(atPath: terminfoEntry.path), fm.fileExists(atPath: shellIntegration.path) else {
            return .failure(GhosttyRuntimeError(message: "libghostty resources missing (checked \(terminfoEntry.path) and \(shellIntegration.path)); this is a packaging bug"))
        }
        setenv("GHOSTTY_RESOURCES_DIR", resources.path, 1)
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == 0 else {
            return .failure(GhosttyRuntimeError(message: "ghostty_init failed"))
        }
        return .success(resources)
    }()

    /// Returns the `share/ghostty` resources directory.
    @discardableResult
    static func initialize() throws -> URL {
        try initialization.get()
    }

    /// The bundled theme files, one per theme, named after the theme.
    public static func themesDirectory() throws -> URL {
        try initialize().appendingPathComponent("themes", isDirectory: true)
    }
}

/// Loading a config file the way the runtime does, for validation.
public enum GhosttyConfigFile {
    /// libghostty's diagnostics for the config in `url` (empty when it is clean).
    public static func diagnostics(forFileAt url: URL) throws -> [String] {
        try GhosttyLibrary.initialize()
        let (cfg, diags) = load(url)
        ghostty_config_free(cfg)
        return diags
    }

    /// A finalized config loaded only from `url`; the caller owns and frees it.
    static func load(_ url: URL) -> (UnsafeMutableRawPointer, [String]) {
        let cfg = ghostty_config_new()!
        url.path.withCString { ghostty_config_load_file(cfg, $0) }
        ghostty_config_finalize(cfg)
        var diags: [String] = []
        let count = ghostty_config_diagnostics_count(cfg)
        for i in 0..<count {
            let d = ghostty_config_get_diagnostic(cfg, i)
            if let m = d.message { diags.append(String(cString: m)) }
        }
        return (cfg, diags)
    }
}
