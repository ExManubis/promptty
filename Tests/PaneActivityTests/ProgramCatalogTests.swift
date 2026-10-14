import PaneActivity
import XCTest

final class ProgramCatalogTests: XCTestCase {
    private func id(_ executable: String, _ args: String...) -> String? {
        ProgramCatalog.identify(executable: executable, arguments: [executable] + args)?.id
    }

    func testProgramsByName() {
        XCTAssertEqual(id("/opt/homebrew/bin/nvim", "notes.md"), "neovim")
        XCTAssertEqual(id("/usr/bin/vim"), "vim")
        XCTAssertEqual(id("/usr/bin/git", "log"), "git")
        XCTAssertEqual(id("/opt/homebrew/bin/lazygit"), "lazygit")
        XCTAssertEqual(id("/usr/local/bin/docker", "ps"), "docker")
        XCTAssertEqual(id("/opt/homebrew/bin/psql"), "postgresql")
        XCTAssertEqual(id("/Users/me/.cargo/bin/cargo", "build"), "rust")
        XCTAssertEqual(id("/usr/bin/ssh", "host"), "ssh")
        XCTAssertEqual(id("/Users/me/.local/bin/claude"), "claude")
        XCTAssertEqual(id("/opt/homebrew/bin/codex"), "codex")
    }

    func testUnknownProgramsAreNotIdentified() {
        XCTAssertNil(id("/bin/sleep", "5"))
        XCTAssertNil(id("/usr/bin/top"))
    }

    func testVersionedInterpretersAreTheirLanguage() {
        XCTAssertEqual(id("/opt/homebrew/bin/python3.12", "-m", "http.server"), "python")
        XCTAssertEqual(id("/usr/bin/python3"), "python")
        XCTAssertEqual(id("/opt/homebrew/bin/node"), "node")
        XCTAssertEqual(id("/Users/me/.bun/bin/bun", "run", "dev"), "bun")
    }

    /// Agents installed with npm run as node scripts.
    func testScriptsAreIdentifiedByWhatTheyRun() {
        XCTAssertEqual(id("node", "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"), "claude")
        XCTAssertEqual(id("/opt/homebrew/bin/node", "--no-warnings", "/opt/homebrew/bin/claude"), "claude")
        XCTAssertEqual(id("node", "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js"), "codex")
        XCTAssertEqual(id("node", "/usr/local/lib/node_modules/@google/gemini-cli/dist/index.js"), "gemini")
        XCTAssertEqual(id("node", "/usr/local/bin/copilot"), "copilot")
        XCTAssertEqual(id("node", "server.js"), "node")
        XCTAssertEqual(id("/opt/homebrew/bin/python3", "/opt/homebrew/bin/ansible-playbook", "site.yml"), "ansible")
    }

    /// A node CLI that sets `process.title` overwrites its whole argv with that title.
    func testAnInterpreterRetitledAsTheProgramIsThatProgram() {
        XCTAssertEqual(ProgramCatalog.identify(executable: "/opt/homebrew/bin/node", arguments: ["claude", ""])?.id, "claude")
        XCTAssertEqual(ProgramCatalog.identify(executable: "/opt/homebrew/bin/node", arguments: ["codex"])?.id, "codex")
    }

    /// Only programs distributed as scripts are recognised from a script's name: a project's
    /// own `git.js` or `docker.py` is just Node or Python.
    func testAScriptNamedLikeACompiledProgramIsItsInterpreter() {
        XCTAssertEqual(id("node", "git.js"), "node")
        XCTAssertEqual(id("python3", "docker.py"), "python")
        XCTAssertEqual(id("python3", "./go"), "python")
        XCTAssertEqual(id("node", "/Users/me/src/claude-code-router/index.js"), "node")
    }

    func testShellsAreShellsAndLoginShellsToo() {
        for shell in ["/bin/zsh", "-zsh", "zsh", "/bin/bash", "-bash", "/opt/homebrew/bin/fish"] {
            let program = ProgramCatalog.identify(executable: shell, arguments: [shell])
            XCTAssertEqual(program?.isShell, true, shell)
        }
        XCTAssertEqual(ProgramCatalog.identify(executable: "/usr/bin/git", arguments: ["git"])?.isShell, false)
        // `sh build.sh` is a script running, not a prompt.
        XCTAssertNil(ProgramCatalog.identify(executable: "/bin/sh", arguments: ["sh", "build.sh"]))
    }

    /// Programs with a logo have a tile in their brand's colors, the logo readable on it.
    func testBrandTiles() {
        let claude = ProgramCatalog.all.first { $0.id == "claude" }
        XCTAssertEqual(claude?.tile, Program.Tile(background: 0xD97757, foreground: 0xFFFFFF))
        XCTAssertEqual(ProgramCatalog.all.first { $0.id == "python" }?.tile, Program.Tile(background: 0x3776AB, foreground: 0xFFD43B))
        XCTAssertEqual(ProgramCatalog.all.first { $0.id == "bun" }?.tile, Program.Tile(background: 0xFBF0DF, foreground: 0x14151A))
        // A full-color logo is drawn in its own colors, not the tile's foreground: how it reads
        // on its tile is a design choice (claudewitz's purple), not this check's.
        for program in ProgramCatalog.all where program.logo != nil && !program.fullColorLogo {
            let tile = try! XCTUnwrap(program.tile, program.id)
            XCTAssertGreaterThanOrEqual(Program.Tile.contrast(tile.background, tile.foreground), 2.5, program.id)
        }
        // Shells and unknown programs: the default dark tile.
        XCTAssertNil(ProgramCatalog.all.first { $0.id == "zsh" }?.tile)
    }

    func testMoreCodingAgentsAreAgents() {
        let agents: [(String, [String], String)] = [
            ("/Users/me/.local/bin/cursor-agent", [], "cursor"),
            ("node", ["/Users/me/.local/share/cursor-agent/versions/2025.10.1/index.js"], "cursor"),
            ("/opt/homebrew/bin/opencode", [], "opencode"),
            ("node", ["/opt/homebrew/lib/node_modules/opencode-ai/bin/opencode"], "opencode"),
            ("node", ["/opt/homebrew/lib/node_modules/@sourcegraph/amp/dist/main.js"], "amp"),
            ("/opt/homebrew/bin/goose", ["session"], "goose"),
            ("node", ["/usr/local/lib/node_modules/cline/dist/cli.mjs"], "cline"),
            ("node", ["/opt/homebrew/lib/node_modules/@qwen-code/qwen-code/cli.js"], "qwen"),
            ("node", ["/opt/homebrew/bin/qwen"], "qwen"),
            ("/Users/me/.kilo/bin/kilo", [], "kilocode"),
            ("node", ["/opt/homebrew/lib/node_modules/@kilocode/cli/bin/kilo"], "kilocode"),
            ("/Users/me/.local/bin/kiro-cli", ["chat"], "kiro"),
            ("/Users/me/.local/share/uv/tools/kimi-cli/bin/python", ["/Users/me/.local/bin/kimi"], "kimi"),
            ("/Users/me/go/bin/claudewitz", ["-continue"], "claudewitz"),
        ]
        for (executable, arguments, expected) in agents {
            let program = ProgramCatalog.identify(executable: executable, arguments: [executable] + arguments)
            XCTAssertEqual(program?.id, expected, executable + " " + arguments.joined(separator: " "))
            XCTAssertEqual(program?.isAgent, true, expected)
        }
    }

    func testDeveloperToolsAndPlatformCLIs() {
        XCTAssertEqual(id("/Users/me/.local/bin/uv", "run", "app.py"), "uv")
        XCTAssertEqual(id("/Users/me/.local/bin/uvx", "ruff"), "uv")
        XCTAssertEqual(id("/opt/homebrew/bin/ruff", "check"), "ruff")
        XCTAssertEqual(id("/Users/me/src/app/.venv/bin/python", "/Users/me/src/app/.venv/bin/pytest", "-x"), "pytest")
        XCTAssertEqual(id("python3", "-m", "pytest"), "pytest")
        XCTAssertEqual(id("python3", "/opt/homebrew/bin/jupyter-lab"), "jupyter")
        XCTAssertEqual(id("node", "/Users/me/src/web/node_modules/vite/bin/vite.js"), "vite")
        XCTAssertEqual(id("node", "/Users/me/src/web/node_modules/vitest/vitest.mjs", "run"), "vitest")
        XCTAssertEqual(id("node", "/Users/me/src/web/node_modules/jest/bin/jest.js"), "jest")
        XCTAssertEqual(id("node", "/Users/me/src/web/node_modules/next/dist/bin/next", "dev"), "next")
        XCTAssertEqual(id("/Users/me/src/web/node_modules/turbo-darwin-arm64/bin/turbo", "dev"), "turbo")
        XCTAssertEqual(id("/opt/homebrew/bin/gh", "pr", "view"), "github")
        XCTAssertEqual(id("/opt/homebrew/bin/glab", "mr", "list"), "gitlab")
        XCTAssertEqual(id("node", "/opt/homebrew/lib/node_modules/vercel/dist/vc.js", "dev"), "vercel")
        XCTAssertEqual(id("node", "/opt/homebrew/lib/node_modules/netlify-cli/bin/run.js", "dev"), "netlify")
        XCTAssertEqual(id("/opt/homebrew/bin/flyctl", "deploy"), "fly")
        XCTAssertEqual(id("/Users/me/.fly/bin/fly", "logs"), "fly")
        XCTAssertEqual(id("node", "/Users/me/src/worker/node_modules/wrangler/bin/wrangler.js", "dev"), "cloudflare")
        XCTAssertEqual(id("/opt/homebrew/bin/supabase", "start"), "supabase")
        XCTAssertEqual(id("node", "/opt/homebrew/lib/node_modules/firebase-tools/lib/bin/firebase.js", "deploy"), "firebase")
        XCTAssertEqual(id("/opt/homebrew/bin/stripe", "listen"), "stripe")
        XCTAssertEqual(id("/opt/homebrew/bin/ngrok", "http", "3000"), "ngrok")
        XCTAssertEqual(id("/Applications/Tailscale.app/Contents/MacOS/tailscale", "status"), "tailscale")
        XCTAssertEqual(id("/opt/homebrew/bin/btop"), "btop")
        // A project's own `vite.config.js` or `next.js` script is just Node.
        XCTAssertEqual(id("node", "vite.config.js"), "node")
        XCTAssertEqual(id("node", "next.js"), "node")
    }

    /// btop's logo keeps its own red stripes, on the dark tile.
    func testBtopShowsItsOwnColors() {
        let btop = ProgramCatalog.all.first { $0.id == "btop" }
        XCTAssertEqual(btop?.logo, "btop")
        XCTAssertEqual(btop?.fullColorLogo, true)
        XCTAssertEqual(ProgramCatalog.all.filter(\.fullColorLogo).map(\.id), ["claudewitz", "btop"])
    }

    /// claudewitz's pixel C keeps its own colors, on a dark purple square.
    func testClaudewitzShowsItsOwnColors() {
        let claudewitz = ProgramCatalog.all.first { $0.id == "claudewitz" }
        XCTAssertEqual(claudewitz?.logo, "claudewitz")
        XCTAssertEqual(claudewitz?.fullColorLogo, true)
        XCTAssertEqual(claudewitz?.tile?.background, 0x5A3DB5)
    }

    func testEveryLogoHasAColor() {
        for program in ProgramCatalog.all where program.logo != nil {
            XCTAssertNotNil(program.color, program.id)
        }
    }
}
