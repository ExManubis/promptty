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

    func testShellsAreShellsAndLoginShellsToo() {
        for shell in ["/bin/zsh", "-zsh", "zsh", "/bin/bash", "-bash", "/opt/homebrew/bin/fish"] {
            let program = ProgramCatalog.identify(executable: shell, arguments: [shell])
            XCTAssertEqual(program?.isShell, true, shell)
        }
        XCTAssertEqual(ProgramCatalog.identify(executable: "/usr/bin/git", arguments: ["git"])?.isShell, false)
        // `sh build.sh` is a script running, not a prompt.
        XCTAssertNil(ProgramCatalog.identify(executable: "/bin/sh", arguments: ["sh", "build.sh"]))
    }

    func testEveryLogoHasAColor() {
        for program in ProgramCatalog.all where program.logo != nil {
            XCTAssertNotNil(program.color, program.id)
        }
    }
}
