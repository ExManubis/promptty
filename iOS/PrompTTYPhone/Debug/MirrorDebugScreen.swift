#if DEBUG
import SwiftUI
import GhosttyMirror
import Preferences

/// The phone's libghostty on its own (PTY-82), until the Mac streams a pane (PTY-78): launched
/// with `-mirror claude` or `-mirror vim`, the app shows a terminal fed a recording of what Claude
/// Code or vim wrote to its pty on the Mac (`Debug/Recordings`), and under it every byte the terminal
/// sends back: what is typed, and its replies to the program's queries. The recordings were made
/// on a 54×40 pty, so the terminal is sized to that grid before they play: a live pane gets the
/// phone's grid instead (`onResize`, PTY-75).
enum MirrorDebug {
    static var recording: String? { UserDefaults.standard.string(forKey: "mirror") }
}

@MainActor
@Observable
final class MirrorDebugModel {
    let recording: String
    private(set) var surface: MirrorSurfaceView?
    private(set) var failure: String?
    /// Everything the terminal sent, escaped (`\e`, `\r`, `^C`).
    private(set) var written = ""
    private(set) var grid = ""
    /// The terminal's size for the recording's grid, once its cells are known.
    private(set) var fit: CGSize?
    static let recordedGrid = (columns: 54, rows: 40)
    private var played = false
    private var engine: MirrorEngine?
    private var playback: Task<Void, Never>?

    init(recording: String) {
        self.recording = recording
        do {
            // The Mac's terminal.conf with default settings, its theme inline (the phone has no
            // theme files), a size that fits the recording's 54 columns, and an opaque background
            // (no pane card draws one behind it here). `-mirrorFont` tries another family.
            let config = TerminalConfigWriter.render(Settings(), knownThemes: nil)
                .split(separator: "\n").filter { !$0.hasPrefix("theme =") }.joined(separator: "\n")
                + "\n" + DemoData.flexokiDark + "\nfont-size = 10\nbackground-opacity = 1\n"
                + (UserDefaults.standard.string(forKey: "mirrorFont").map { "font-family = \($0)\n" } ?? "")
            let engine = try MirrorEngine(configText: config)
            let surface = MirrorSurfaceView(engine: engine)
            surface.accessibilityIdentifier = "mirror.surface"
            surface.onWrite = { [weak self] data in self?.written += Self.escape(data) }
            surface.onResize = { [weak self] columns, rows in self?.resized(columns: columns, rows: rows) }
            self.engine = engine
            self.surface = surface
        } catch {
            failure = "\(error)"
        }
    }

    /// Shrinks the terminal to the recording's grid, then plays it once the grid matches.
    private func resized(columns: Int, rows: Int) {
        grid = "\(columns)×\(rows)"
        let target = Self.recordedGrid
        if columns == target.columns, rows == target.rows {
            if !played { played = true; play() }
            return
        }
        guard let cell = surface?.cellSize, cell.width > 0 else { return }
        // The config's window padding (10 by 8 on each side) around the cells, and half a cell
        // spare: the grid is what fits whole.
        fit = CGSize(width: 20 + (CGFloat(target.columns) + 0.5) * cell.width,
                     height: 16 + (CGFloat(target.rows) + 0.5) * cell.height)
    }

    /// Plays the recording from a reset terminal, in pty-sized chunks so it draws as it would
    /// arrive.
    func play() {
        guard let url = Bundle.main.url(forResource: recording, withExtension: "vt"),
              let bytes = try? Data(contentsOf: url) else {
            failure = "No recording \(recording).vt"
            return
        }
        playback?.cancel()
        written = ""
        surface?.feed(Data("\u{1B}c".utf8))
        playback = Task { [weak self] in
            var offset = 0
            while offset < bytes.count, !Task.isCancelled {
                let end = min(offset + 1024, bytes.count)
                self?.surface?.feed(bytes.subdata(in: offset..<end))
                offset = end
                try? await Task.sleep(for: .milliseconds(8))
            }
        }
    }

    static func escape(_ data: Data) -> String {
        var out = ""
        for byte in data {
            switch byte {
            case 0x1B: out += "\\e"
            case 0x0D: out += "\\r"
            case 0x0A: out += "\\n"
            case 0x09: out += "\\t"
            case 0x7F: out += "^?"
            case 0..<0x20: out += "^" + String(UnicodeScalar(byte + 0x40))
            default: out += String(UnicodeScalar(byte))
            }
        }
        return out
    }
}

struct MirrorDebugScreen: View {
    @State private var model: MirrorDebugModel

    init(recording: String) {
        _model = State(initialValue: MirrorDebugModel(recording: recording))
    }

    var body: some View {
        VStack(spacing: 8) {
            if let surface = model.surface {
                MirrorTerminal(view: surface)
                    .frame(width: model.fit?.width, height: model.fit?.height)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let failure = model.failure {
                Text(failure).foregroundStyle(.red).font(.footnote)
            }
            keys
            VStack(alignment: .leading, spacing: 2) {
                Text("\(model.recording) · \(model.grid)")
                    .accessibilityIdentifier("mirror.grid")
                Text(model.written.isEmpty ? "(nothing sent yet)" : String(model.written.suffix(160)))
                    .lineLimit(3)
                    .accessibilityIdentifier("mirror.written")
                    .accessibilityValue(model.written)
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .background(Color(red: 0.06, green: 0.06, blue: 0.06).ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private var keys: some View {
        HStack(spacing: 6) {
            key("esc") { model.surface?.send(.escape) }
            key("tab") { model.surface?.send(.tab) }
            key("^C", id: "ctrl-c") { model.surface?.send(.character("c"), modifiers: .control) }
            key("←", id: "left") { model.surface?.send(.left) }
            key("↓", id: "down") { model.surface?.send(.down) }
            key("↑", id: "up") { model.surface?.send(.up) }
            key("→", id: "right") { model.surface?.send(.right) }
            key("⏎", id: "return") { model.surface?.send(.return) }
            key("replay") { model.play() }
        }
        .font(.system(size: 13, weight: .medium, design: .monospaced))
    }

    private func key(_ title: String, id: String? = nil, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("mirror.key.\(id ?? title)")
    }
}

private struct MirrorTerminal: UIViewRepresentable {
    let view: MirrorSurfaceView
    func makeUIView(context: Context) -> MirrorSurfaceView { view }
    func updateUIView(_ uiView: MirrorSurfaceView, context: Context) {}
}
#endif
