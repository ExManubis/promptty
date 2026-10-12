import Foundation

/// A program PrompTTY recognises in a pane's foreground: shown with its logo in the tab and the
/// pane header.
public struct Program: Equatable, Hashable, Sendable {
    public let id: String
    public let name: String
    /// The logo's image name in the app's asset catalog; nil shows a generic terminal symbol.
    public let logo: String?
    /// The brand color, 0xRRGGBB.
    public let color: UInt32?
    public let isShell: Bool

    public init(id: String, name: String, logo: String? = nil, color: UInt32? = nil, isShell: Bool = false) {
        self.id = id
        self.name = name
        self.logo = logo
        self.color = color
        self.isShell = isShell
    }
}

/// Which program a process is, from its executable and arguments.
public enum ProgramCatalog {
    private struct Entry {
        let program: Program
        /// Executable names (the last path component).
        let executables: [String]
        /// Runs scripts: its own script argument may name another program (`node …/claude-code/cli.js`).
        var interpreter = false
        /// Text in a script's path that names this program.
        var scriptMarkers: [String] = []
        /// Distributed as a script (an npm package's bin): recognised from a script's name too.
        var scriptable = false
    }

    private static func entry(_ id: String, _ name: String, logo: String?, _ color: UInt32?, _ executables: [String],
                              interpreter: Bool = false, markers: [String] = [], scriptable: Bool = false,
                              shell: Bool = false) -> Entry {
        Entry(program: Program(id: id, name: name, logo: logo, color: color, isShell: shell),
              executables: executables, interpreter: interpreter, scriptMarkers: markers, scriptable: scriptable)
    }

    private static let entries: [Entry] = [
        // Agents
        entry("claude", "Claude Code", logo: "claude", 0xD97757, ["claude"], markers: ["@anthropic-ai/claude-code/"], scriptable: true),
        entry("codex", "Codex", logo: "codex", 0x000000, ["codex"], markers: ["@openai/codex/"], scriptable: true),
        entry("gemini", "Gemini CLI", logo: "googlegemini", 0x8E75B2, ["gemini"], markers: ["@google/gemini-cli/"], scriptable: true),
        entry("copilot", "Copilot", logo: "githubcopilot", 0x000000, ["copilot"], markers: ["@github/copilot/"], scriptable: true),
        entry("ollama", "Ollama", logo: "ollama", 0x000000, ["ollama"]),
        // Languages and runtimes
        entry("node", "Node.js", logo: "nodedotjs", 0x5FA04E, ["node", "nodejs"], interpreter: true),
        entry("bun", "Bun", logo: "bun", 0x000000, ["bun", "bunx"], interpreter: true),
        entry("deno", "Deno", logo: "deno", 0x000000, ["deno"], interpreter: true),
        entry("python", "Python", logo: "python", 0x3776AB, ["python", "ipython"], interpreter: true),
        entry("ruby", "Ruby", logo: "ruby", 0xCC342D, ["ruby", "irb"], interpreter: true),
        entry("go", "Go", logo: "go", 0x00ADD8, ["go"]),
        entry("rust", "Rust", logo: "rust", 0x000000, ["cargo", "rustc", "rustup"]),
        entry("swift", "Swift", logo: "swift", 0xF05138, ["swift", "swiftc", "swift-frontend"]),
        entry("lua", "Lua", logo: "lua", 0x000080, ["lua", "luajit"]),
        entry("php", "PHP", logo: "php", 0x777BB4, ["php"]),
        entry("elixir", "Elixir", logo: "elixir", 0x4B275F, ["elixir", "iex", "mix"]),
        entry("kotlin", "Kotlin", logo: "kotlin", 0x7F52FF, ["kotlin", "kotlinc"]),
        entry("gradle", "Gradle", logo: "gradle", 0x02303A, ["gradle", "gradlew"]),
        // Editors
        entry("neovim", "Neovim", logo: "neovim", 0x57A143, ["nvim"]),
        entry("vim", "Vim", logo: "vim", 0x019733, ["vim", "vi", "view", "vimdiff"]),
        entry("emacs", "Emacs", logo: "gnuemacs", 0x7F5AB6, ["emacs"]),
        entry("helix", "Helix", logo: "helix", 0x281733, ["hx", "helix"]),
        // Tools
        entry("git", "git", logo: "git", 0xF03C2E, ["git"]),
        entry("lazygit", "lazygit", logo: "git", 0xF03C2E, ["lazygit"]),
        entry("tmux", "tmux", logo: "tmux", 0x1BB91F, ["tmux"]),
        entry("docker", "Docker", logo: "docker", 0x2496ED, ["docker", "docker-compose"]),
        entry("kubernetes", "Kubernetes", logo: "kubernetes", 0x326CE5, ["kubectl", "k9s"]),
        entry("htop", "htop", logo: "htop", 0x009020, ["htop"]),
        entry("postgresql", "PostgreSQL", logo: "postgresql", 0x4169E1, ["psql", "postgres"]),
        entry("mysql", "MySQL", logo: "mysql", 0x4479A1, ["mysql"]),
        entry("redis", "Redis", logo: "redis", 0xFF4438, ["redis-cli", "redis-server"]),
        entry("sqlite", "SQLite", logo: "sqlite", 0x003B57, ["sqlite3"]),
        entry("terraform", "Terraform", logo: "terraform", 0x844FBA, ["terraform"]),
        entry("ansible", "Ansible", logo: "ansible", 0xEE0000, ["ansible", "ansible-playbook"], scriptable: true),
        entry("homebrew", "Homebrew", logo: "homebrew", 0xFBB040, ["brew"]),
        entry("npm", "npm", logo: "npm", 0xCB3837, ["npm", "npx"], markers: ["/npm/bin/npm-cli"], scriptable: true),
        entry("pnpm", "pnpm", logo: "pnpm", 0xF69220, ["pnpm"], scriptable: true),
        entry("yarn", "Yarn", logo: "yarn", 0x2C8EBB, ["yarn"], scriptable: true),
        entry("ssh", "SSH", logo: nil, nil, ["ssh", "mosh"]),
        // Shells: the plain terminal symbol, like a pane at its prompt.
        entry("zsh", "zsh", logo: nil, nil, ["zsh"], shell: true),
        entry("bash", "bash", logo: nil, nil, ["bash"], shell: true),
        entry("fish", "fish", logo: nil, nil, ["fish"], shell: true),
    ]

    public static var all: [Program] { entries.map(\.program) }

    /// `arguments` is the full argv, the program's own name first.
    public static func identify(executable: String, arguments: [String]) -> Program? {
        guard let found = entry(forExecutable: executable) else { return nil }
        guard found.interpreter else { return found.program }
        // A node CLI that set `process.title` shows its own name as argv[0].
        if let first = arguments.first, let retitled = scriptable(named: name(first)) { return retitled.program }
        if let script = script(in: arguments.dropFirst()), let ran = entry(forScript: script) { return ran.program }
        return found.program
    }

    private static func name(_ path: String) -> String {
        var name = (path as NSString).lastPathComponent.lowercased()
        // A login shell's argv[0] is `-zsh`.
        if name.hasPrefix("-") { name.removeFirst() }
        return name
    }

    private static func entry(forExecutable executable: String) -> Entry? {
        let name = name(executable)
        if let exact = entries.first(where: { $0.executables.contains(name) }) { return exact }
        // `python3.12`, `node22`, `lua5.4`.
        let bare = String(name.reversed().drop { $0.isNumber || $0 == "." }.reversed())
        guard bare != name, !bare.isEmpty else { return nil }
        return entries.first { $0.executables.contains(bare) }
    }

    /// The script an interpreter runs: its first argument that is not an option (`-m module` for
    /// Python is the module).
    private static func script(in arguments: ArraySlice<String>) -> String? {
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            if argument == "-m" { return iterator.next() }
            if argument.hasPrefix("-") { continue }
            // `bun run dev`: the subcommand is not a script.
            if ["run", "x", "exec"].contains(argument) { continue }
            return argument
        }
        return nil
    }

    private static func entry(forScript script: String) -> Entry? {
        let lower = script.lowercased()
        if let marked = entries.first(where: { entry in entry.scriptMarkers.contains { lower.contains($0) } }) {
            return marked
        }
        return scriptable(named: ((lower as NSString).lastPathComponent as NSString).deletingPathExtension)
    }

    /// Only programs distributed as scripts: a project's own `git.js` is just Node.
    private static func scriptable(named name: String) -> Entry? {
        entries.first { $0.scriptable && $0.executables.contains(name) }
    }
}
