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
    /// A coding agent: PrompTTY tells when it works and when it waits for the user.
    public let isAgent: Bool
    /// The tab tile in the brand's colors; nil for the default dark tile.
    public let tile: Tile?
    /// The logo is drawn in its own colors (btop's red stripes), not tinted with one.
    public let fullColorLogo: Bool

    /// A tile's colors, 0xRRGGBB.
    public struct Tile: Equatable, Hashable, Sendable {
        public let background: UInt32
        public let foreground: UInt32

        public init(background: UInt32, foreground: UInt32) {
            self.background = background
            self.foreground = foreground
        }

        /// The WCAG contrast ratio of two colors.
        public static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
            let la = luminance(a), lb = luminance(b)
            return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
        }

        public static func luminance(_ hex: UInt32) -> Double {
            func linear(_ c: UInt32) -> Double {
                let v = Double(c) / 255
                return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear((hex >> 16) & 0xFF) + 0.7152 * linear((hex >> 8) & 0xFF) + 0.0722 * linear(hex & 0xFF)
        }
    }

    public init(id: String, name: String, logo: String? = nil, color: UInt32? = nil, isShell: Bool = false, isAgent: Bool = false,
                tile: Tile? = nil, fullColorLogo: Bool = false) {
        self.id = id
        self.name = name
        self.logo = logo
        self.color = color
        self.isShell = isShell
        self.isAgent = isAgent
        self.tile = tile
        self.fullColorLogo = fullColorLogo
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
                              shell: Bool = false, agent: Bool = false, fullColor: Bool = false) -> Entry {
        Entry(program: Program(id: id, name: name, logo: logo, color: color, isShell: shell, isAgent: agent, tile: tiles[id],
                               fullColorLogo: fullColor),
              executables: executables, interpreter: interpreter, scriptMarkers: markers, scriptable: scriptable)
    }

    private static let white: UInt32 = 0xFFFFFF

    /// Each logo's tile: the brand's own color behind the logo in white, or the brand's pairing
    /// where it has one (Python's yellow on blue, Bun on its cream).
    private static let tiles: [String: Program.Tile] = [
        "claude": .init(background: 0xD97757, foreground: white),
        "codex": .init(background: 0x000000, foreground: white),
        "gemini": .init(background: 0x8E75B2, foreground: white),
        "copilot": .init(background: 0x000000, foreground: white),
        "cursor": .init(background: 0x000000, foreground: white),
        "opencode": .init(background: 0x000000, foreground: white),
        "amp": .init(background: 0xF34E3F, foreground: white),
        "goose": .init(background: 0x000000, foreground: white),
        "cline": .init(background: 0x18181B, foreground: white),
        "qwen": .init(background: 0x6950EF, foreground: white),
        "kilocode": .init(background: 0xFFDD00, foreground: 0x000000),
        "kiro": .init(background: 0x9046FF, foreground: white),
        "kimi": .init(background: 0x1783FF, foreground: white),
        // The foreground stands for the π's own coral, which it is drawn in with its blue and yellow.
        "pi": .init(background: 0x000000, foreground: 0xE48A7A),
        "ollama": .init(background: 0x000000, foreground: white),
        // The foreground stands for the C's own orange, which it is drawn in.
        "claudewitz": .init(background: 0x5A3DB5, foreground: 0xDA7756),
        "node": .init(background: 0x5FA04E, foreground: white),
        "bun": .init(background: 0xFBF0DF, foreground: 0x14151A),
        "deno": .init(background: 0x000000, foreground: white),
        "python": .init(background: 0x3776AB, foreground: 0xFFD43B),
        "ruby": .init(background: 0xCC342D, foreground: white),
        "go": .init(background: 0x00ADD8, foreground: white),
        "rust": .init(background: 0xB7410E, foreground: white),
        "swift": .init(background: 0xF05138, foreground: white),
        "lua": .init(background: 0x000080, foreground: white),
        "php": .init(background: 0x777BB4, foreground: white),
        "elixir": .init(background: 0x4B275F, foreground: white),
        "kotlin": .init(background: 0x7F52FF, foreground: white),
        "gradle": .init(background: 0x02303A, foreground: white),
        "neovim": .init(background: 0x57A143, foreground: white),
        "vim": .init(background: 0x019733, foreground: white),
        "emacs": .init(background: 0x7F5AB6, foreground: white),
        "helix": .init(background: 0x281733, foreground: white),
        "git": .init(background: 0xF03C2E, foreground: white),
        "lazygit": .init(background: 0xF03C2E, foreground: white),
        "tmux": .init(background: 0x1BB91F, foreground: white),
        "docker": .init(background: 0x2496ED, foreground: white),
        "kubernetes": .init(background: 0x326CE5, foreground: white),
        "htop": .init(background: 0x009020, foreground: white),
        "postgresql": .init(background: 0x4169E1, foreground: white),
        "mysql": .init(background: 0x4479A1, foreground: white),
        "redis": .init(background: 0xFF4438, foreground: white),
        "sqlite": .init(background: 0x003B57, foreground: white),
        "terraform": .init(background: 0x844FBA, foreground: white),
        "ansible": .init(background: 0xEE0000, foreground: white),
        "homebrew": .init(background: 0xFBB040, foreground: 0x2E2A24),
        "npm": .init(background: 0xCB3837, foreground: white),
        "pnpm": .init(background: 0xF69220, foreground: 0x2B2B2B),
        "yarn": .init(background: 0x2C8EBB, foreground: white),
        // Astral's tools in their colors on Astral's dark purple.
        "uv": .init(background: 0x261230, foreground: 0xDE5FE9),
        "ruff": .init(background: 0x261230, foreground: 0xD7FF64),
        "pytest": .init(background: 0x0A9EDC, foreground: white),
        "jupyter": .init(background: 0xF37626, foreground: white),
        "vite": .init(background: 0x9135FF, foreground: white),
        "vitest": .init(background: 0x1B1B1F, foreground: 0x00FF74),
        "jest": .init(background: 0xC21325, foreground: white),
        "turbo": .init(background: 0xFF1E56, foreground: white),
        "next": .init(background: 0x000000, foreground: white),
        "github": .init(background: 0x181717, foreground: white),
        "gitlab": .init(background: 0xFC6D26, foreground: white),
        "vercel": .init(background: 0x000000, foreground: white),
        "netlify": .init(background: 0x0E1E25, foreground: 0x00C7B7),
        "fly": .init(background: 0x24175B, foreground: white),
        "cloudflare": .init(background: 0xF38020, foreground: white),
        "supabase": .init(background: 0x1C1C1C, foreground: 0x3FCF8E),
        "firebase": .init(background: 0xDD2C00, foreground: white),
        "stripe": .init(background: 0x635BFF, foreground: white),
        "ngrok": .init(background: 0x1F1E37, foreground: white),
        "tailscale": .init(background: 0x242424, foreground: white),
        // The foreground stands for the logo's own red, which it is drawn in.
        "btop": .init(background: 0x1A1A1A, foreground: 0xFF0000),
    ]

    private static let entries: [Entry] = [
        // Agents
        entry("claude", "Claude Code", logo: "claude", 0xD97757, ["claude"], markers: ["@anthropic-ai/claude-code/"], scriptable: true, agent: true),
        entry("codex", "Codex", logo: "codex", 0x000000, ["codex"], markers: ["@openai/codex/"], scriptable: true, agent: true),
        entry("gemini", "Gemini CLI", logo: "googlegemini", 0x8E75B2, ["gemini"], markers: ["@google/gemini-cli/"], scriptable: true, agent: true),
        entry("copilot", "Copilot", logo: "githubcopilot", 0x000000, ["copilot"], markers: ["@github/copilot/"], scriptable: true, agent: true),
        entry("cursor", "Cursor", logo: "cursor", 0x000000, ["cursor-agent"], markers: ["/cursor-agent/"], scriptable: true, agent: true),
        entry("opencode", "OpenCode", logo: "opencode", 0x000000, ["opencode"], markers: ["/opencode-ai/"], scriptable: true, agent: true),
        entry("amp", "Amp", logo: "amp", 0xF34E3F, ["amp"], markers: ["@sourcegraph/amp/"], scriptable: true, agent: true),
        entry("goose", "Goose", logo: "goose", 0x000000, ["goose"], agent: true),
        entry("cline", "Cline", logo: "cline", 0x18181B, ["cline"], markers: ["/node_modules/cline/"], scriptable: true, agent: true),
        entry("qwen", "Qwen Code", logo: "qwen", 0x6950EF, ["qwen"], markers: ["@qwen-code/"], scriptable: true, agent: true),
        entry("kilocode", "Kilo Code", logo: "kilocode", 0xFFDD00, ["kilo", "kilocode"], markers: ["@kilocode/cli/"], scriptable: true, agent: true),
        entry("kiro", "Kiro", logo: "kiro", 0x9046FF, ["kiro-cli"], agent: true),
        entry("kimi", "Kimi", logo: "kimi", 0x1783FF, ["kimi"], markers: ["/kimi-cli/"], scriptable: true, agent: true),
        entry("pi", "Pi", logo: "pi", 0xE48A7A, ["pi"], markers: ["/pi-coding-agent/"], scriptable: true, agent: true,
              fullColor: true),
        // Claude Code behind its own TUI: the `claude` it drives runs in the background.
        entry("claudewitz", "claudewitz", logo: "claudewitz", 0xDA7756, ["claudewitz"], agent: true, fullColor: true),
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
        // Python tools.
        entry("uv", "uv", logo: "uv", 0xDE5FE9, ["uv", "uvx"]),
        entry("ruff", "Ruff", logo: "ruff", 0xD7FF64, ["ruff"], scriptable: true),
        entry("pytest", "pytest", logo: "pytest", 0x0A9EDC, ["pytest", "py.test"], scriptable: true),
        entry("jupyter", "Jupyter", logo: "jupyter", 0xF37626, ["jupyter", "jupyter-lab", "jupyter-notebook"], scriptable: true),
        // JavaScript tools, run from a project's node_modules: known by their package's path only,
        // so a project's own `vite.config.js` or `next.js` stays Node. Vitest before Vite, whose
        // `.bin/vite` is the start of `.bin/vitest`.
        entry("vitest", "Vitest", logo: "vitest", 0x00FF74, [], markers: ["/vitest/vitest.mjs", "/.bin/vitest"]),
        entry("vite", "Vite", logo: "vite", 0x9135FF, [], markers: ["/vite/bin/", "/.bin/vite"]),
        entry("jest", "Jest", logo: "jest", 0xC21325, [], markers: ["/jest/bin/", "/jest-cli/bin/", "/.bin/jest"]),
        entry("next", "Next.js", logo: "nextdotjs", 0x000000, [], markers: ["/next/dist/bin/", "/.bin/next"]),
        entry("turbo", "Turborepo", logo: "turborepo", 0xFF1E56, ["turbo"], scriptable: true),
        // Platforms' CLIs.
        entry("github", "GitHub CLI", logo: "github", 0x181717, ["gh"]),
        entry("gitlab", "GitLab CLI", logo: "gitlab", 0xFC6D26, ["glab"]),
        entry("vercel", "Vercel", logo: "vercel", 0x000000, ["vercel", "vc"], markers: ["/node_modules/vercel/"], scriptable: true),
        entry("netlify", "Netlify", logo: "netlify", 0x00C7B7, ["netlify", "ntl"], markers: ["/netlify-cli/"], scriptable: true),
        entry("fly", "Fly.io", logo: "flydotio", 0x24175B, ["flyctl", "fly"]),
        entry("cloudflare", "Wrangler", logo: "cloudflare", 0xF38020, ["wrangler"], markers: ["/wrangler/bin/"], scriptable: true),
        entry("supabase", "Supabase", logo: "supabase", 0x3FCF8E, ["supabase"], scriptable: true),
        entry("firebase", "Firebase", logo: "firebase", 0xDD2C00, ["firebase"], markers: ["/firebase-tools/"], scriptable: true),
        entry("stripe", "Stripe", logo: "stripe", 0x635BFF, ["stripe"]),
        entry("ngrok", "ngrok", logo: "ngrok", 0x1F1E37, ["ngrok"]),
        entry("tailscale", "Tailscale", logo: "tailscale", 0x242424, ["tailscale"]),
        entry("btop", "btop", logo: "btop", 0xFF0000, ["btop"], fullColor: true),
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
