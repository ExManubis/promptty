import PaneActivity
import Preferences
import PrompTTYChrome
import SwiftUI

/// The tabs as the Mac's strip shows them: pills in one smoked-glass track, the selected one on a
/// glass thumb that slides, a sidebar button before them.
struct TabStrip: View {
    @Bindable var model: PhoneModel
    @Namespace private var thumb
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            Button { model.paneOpen = false } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 17))
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Tabs")
            .accessibilityIdentifier("sidebar")
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 2) {
                        ForEach(model.allTabs) { tab in
                            pill(tab).id(tab.id)
                        }
                    }
                    .padding(3)
                }
                .scrollIndicators(.never)
                .smokedGlass(Capsule(), panel: Color(model.theme.background))
                .onAppear { proxy.scrollTo(model.selectedTab, anchor: .center) }
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, PhoneMetrics.inset)
        .frame(height: 52)
        .animation(reduceMotion ? nil : .spring(duration: 0.32, bounce: 0.18), value: model.selectedTab)
    }

    private func pill(_ tab: PhoneTab) -> some View {
        let selected = tab.id == model.selectedTab
        return Button { model.select(tab.id) } label: {
            HStack(spacing: 8) {
                ProgramStack(cards: cards(tab), scale: 1.2)
                Text(tab.title)
                    .font(.system(size: 15, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.8))
                if let folder = tab.folder ?? (tab.isAgent ? nil : tab.lead.folder) {
                    Text(folder)
                        .font(.system(size: 15))
                        .foregroundStyle(.tertiary)
                        .truncationMode(.head)
                        .frame(maxWidth: 110)
                }
                if tab.permission != nil {
                    ActivityIndicator(display: .permission)
                } else if !selected, tab.unseen {
                    ActivityIndicator(display: .idle, newOutput: true)
                }
            }
            .lineLimit(1)
            .padding(.leading, 8)
            .padding(.trailing, 12)
            .frame(height: 34)
            .background { if selected { selectionThumb } }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// The Mac strip's thumb: lit smoked glass on the smoked track.
    private var selectionThumb: some View {
        Capsule()
            .fill(Color.white.opacity(0.09))
            .overlay(Capsule().strokeBorder(LinearGradient(colors: [Color.white.opacity(0.35), Color.white.opacity(0.04)],
                                                           startPoint: .top, endPoint: .bottom), lineWidth: 0.75))
            .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
            .matchedGeometryEffect(id: "thumb", in: thumb)
    }
}

/// The selected tab: what waits for the user above its pane, the pane, the glass controls below.
struct PaneColumn: View {
    @Bindable var model: PhoneModel
    let tab: PhoneTab
    /// All the keys on the key row, where there is room.
    var wideControls = false

    var body: some View {
        VStack(spacing: PhoneMetrics.inset) {
            if let request = tab.permission {
                PermissionBanner(model: model, tab: tab, request: request)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            PaneCard(model: model, tab: tab, pane: tab.focused)
            Controls(model: model, tab: tab, wide: wideControls)
        }
        .animation(.easeOut(duration: 0.2), value: tab.permission)
    }
}

/// The Mac's banner above the panes, asking for the agent's permission.
struct PermissionBanner: View {
    let model: PhoneModel
    let tab: PhoneTab
    let request: PermissionRequest

    var body: some View {
        if model.isRemote {
            remoteBanner
        } else {
            demoBanner
        }
    }

    /// A real Mac's prompt: its choices, each pressing its digit there; Return and Escape (its
    /// selected choice, and no) when they couldn't be read off its screen.
    private var remoteBanner: some View {
        let choices = request.choices.isEmpty
            ? [PermissionRequest.Choice(key: "return", label: "Yes"), PermissionRequest.Choice(key: "escape", label: "No")]
            : request.choices
        let first = choices[0]
        return BannerView(content: BannerContent(
            message: "\(request.agent) wants to run \(request.command)",
            actionTitle: first.shortLabel, action: { model.answer(key: first.key, tab: tab.id) },
            symbol: "exclamationmark.shield.fill",
            extraActions: choices.dropFirst().map { choice in (choice.shortLabel, { model.answer(key: choice.key, tab: tab.id) }) }))
            .accessibilityIdentifier("permission")
    }

    private var demoBanner: some View {
        BannerView(content: BannerContent(
            message: "\(request.agent) wants to run \(request.command)",
            actionTitle: "Yes", action: { model.answer(.yes, tab: tab.id) },
            symbol: "exclamationmark.shield.fill",
            extraActions: [("No…", { model.answer(.no, tab: tab.id) }), ("Always", { model.answer(.always, tab: tab.id) })]))
            .accessibilityIdentifier("permission")
    }
}

/// One pane in a card of smoked glass, as the Mac's dark panes: its header, its screen, and at a
/// prompt the input bar.
struct PaneCard: View {
    @Bindable var model: PhoneModel
    let tab: PhoneTab
    let pane: PhonePane

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PhoneMetrics.paneCornerRadius, style: .continuous)
        VStack(spacing: 0) {
            PaneHeaderRow(pane: pane)
            TerminalScreen(lines: pane.screen, theme: model.theme)
            if let shell = pane.shell, pane.permission == nil, pane.display != .working {
                PhoneInputBar(model: model, tab: tab, pane: pane, shell: shell)
            }
        }
        .smokedGlass(shape, panel: Color(model.theme.background), edges: true)
        .clipShape(shape)
    }
}

/// The pane's header, as the Mac's: its program's glyph in one color, its title, its folder dimmed.
private struct PaneHeaderRow: View {
    let pane: PhonePane

    var body: some View {
        HStack(spacing: 9) {
            ProgramIcon(program: pane.program, size: 16, fallbackSymbol: "apple.terminal", tint: Color.primary.opacity(0.75), monochrome: true)
                .frame(width: 20)
            Text(pane.title)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .layoutPriority(1)
            Text(pane.folder)
                .font(.system(size: 15))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
    }
}

/// The pane's screen. A stand-in for the live terminal (PTY-78): the lines, in the Mac's theme.
private struct TerminalScreen: View {
    let lines: [TerminalLine]
    let theme: ThemeSwatch

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                // No gap between lines, as in a terminal, so box drawing joins up.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        text(line).id(line.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.never)
            .defaultScrollAnchor(.bottom)
            .onChange(of: lines.count) { _, _ in
                withAnimation { proxy.scrollTo(lines.last?.id, anchor: .bottom) }
            }
        }
        .font(.system(size: 12, design: .monospaced))
    }

    private func text(_ line: TerminalLine) -> Text {
        var text = AttributedString(line.runs.isEmpty ? " " : "")
        for run in line.runs {
            var part = AttributedString(run.text)
            part.foregroundColor = theme.color(run.color)
            if run.bold { part.font = .system(size: 12, weight: .bold, design: .monospaced) }
            text += part
        }
        return Text(text)
    }
}

/// The Mac's input bar on the pane's own surface: where the next command runs and how the last one
/// ended (the Mac's header chips), then the prompt mark and the command.
private struct PhoneInputBar: View {
    @Bindable var model: PhoneModel
    let tab: PhoneTab
    let pane: PhonePane
    let shell: ShellState
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button {} label: {
                    Label { Text(shortFolder).lineLimit(1).truncationMode(.head) } icon: { Image(systemName: "folder") }
                }
                .buttonStyle(HeaderChipStyle(open: false, color: model.theme.color(6)))
                if let branch = shell.branch {
                    Button {} label: {
                        Label {
                            HStack(spacing: 3) {
                                Text(branch).lineLimit(1).truncationMode(.head)
                                if shell.dirty { Circle().frame(width: 5, height: 5) }
                            }
                        } icon: { Image(systemName: "arrow.triangle.branch") }
                    }
                    .buttonStyle(HeaderChipStyle(open: false, color: model.theme.color(5)))
                }
                Spacer(minLength: 0)
                if let exit = shell.lastExit {
                    if exit.duration >= 1 { Text(Self.duration(exit.duration)).monospacedDigit() }
                    if exit.code > 0 {
                        Label("\(exit.code)", systemImage: "xmark").foregroundStyle(.red)
                    } else {
                        Image(systemName: "checkmark")
                    }
                }
            }
            .labelStyle(HeaderLabelStyle())
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.secondary)
            HStack(spacing: 9) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(model.theme.color(2))
                TextField("", text: Binding(get: { shell.draft }, set: { model.setDraft($0, tab: tab.id, pane: pane.id) }))
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundStyle(Color(model.theme.foreground))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .submitLabel(.go)
                    .onSubmit { model.run(shell.draft, tab: tab.id, pane: pane.id) }
                    .accessibilityIdentifier("command")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.primary.opacity(0.09)).frame(height: 1).padding(.horizontal, 12)
        }
    }

    /// The last folders of the path, as the Mac's chip shows them.
    private var shortFolder: String {
        let parts = shell.folder.split(separator: "/")
        return parts.count > 1 ? String(parts.last!) : shell.folder
    }

    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return m < 60 ? "\(m)m \(s)s" : "\(m / 60)h \(m % 60)m"
    }
}
