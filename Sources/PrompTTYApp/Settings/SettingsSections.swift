import AppKit
import PaneActivity
import Preferences
import SwiftUI

struct AppearanceSection: View {
    @Bindable var model: SettingsModel
    let swatches: ThemeSwatches
    let fontFamilies: [String]

    var body: some View {
        Form {
            Section("Font") {
                Picker("Family", selection: $model.settings.fontFamily) {
                    ForEach(fontFamilies, id: \.self) { family in
                        Text(family).font(.custom(family, size: 13)).tag(family)
                    }
                    if !fontFamilies.contains(model.settings.fontFamily) {
                        Text("\(model.settings.fontFamily) (missing)").tag(model.settings.fontFamily)
                    }
                }
                LabeledContent("Size") {
                    HStack(spacing: 8) {
                        Text("\(Int(model.settings.fontSize)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Stepper("Size", value: $model.settings.fontSize, in: Preferences.Settings.fontSizeRange, step: 1)
                            .labelsHidden()
                    }
                }
                Text("The quick brown fox → { } [ ] 0O 1lI")
                    .font(.custom(model.settings.fontFamily, size: model.settings.fontSize))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Font preview")
            }

            Section("Theme") {
                Toggle("Match system appearance", isOn: $model.settings.followSystemAppearance)
                if model.settings.followSystemAppearance {
                    ThemePicker(title: "Light", selection: $model.settings.lightTheme, swatches: swatches, prefersDark: false)
                    ThemePicker(title: "Dark", selection: $model.settings.darkTheme, swatches: swatches, prefersDark: true)
                } else {
                    ThemePicker(title: "Theme", selection: $model.settings.theme, swatches: swatches)
                }
            }

            Section("Panes") {
                Toggle("Translucent panes", isOn: $model.settings.translucentPanes)
                    .help("The desktop shows faintly through the panes, as through the rest of the window.")
                Picker("Pane headers", selection: $model.settings.paneHeaders) {
                    Text("Always").tag(PaneHeaders.always)
                    Text("In split tabs").tag(PaneHeaders.splits)
                    Text("Never").tag(PaneHeaders.never)
                }
            }

            Section("Cursor") {
                Picker("Style", selection: $model.settings.cursorStyle) {
                    Label("Block", systemImage: "rectangle.fill").tag(CursorStyle.block)
                    Label("Bar", systemImage: "line.3.horizontal.decrease").tag(CursorStyle.bar)
                    Label("Underline", systemImage: "underline").tag(CursorStyle.underline)
                }
                .pickerStyle(.segmented)
                Toggle("Blink", isOn: $model.settings.cursorBlink)
                CursorColorRow(color: $model.settings.cursorColor)
            }

            Section {
                Toggle("Keep ProMotion displays at 120 Hz", isOn: $model.settings.fullRefreshRate)
            } header: {
                Text("Display")
            } footer: {
                Text("While a PrompTTY window is in front, the display stays at its full refresh rate instead of slowing down when little changes, so typing shows up sooner. Uses more battery.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Frame color") {
                    HStack(spacing: 8) {
                        Text("Neutral").font(.system(size: 11)).foregroundStyle(.secondary)
                        Slider(value: $model.settings.tintStrength, in: 0...1)
                            .frame(maxWidth: 200)
                        Text("Theme").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Window")
            } footer: {
                Text("How much of the terminal theme's color the window frame takes on.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct TabsSection: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section("Tabs") {
                Picker("Show tabs in", selection: $model.settings.tabLayout) {
                    Label("Sidebar", systemImage: "sidebar.left").tag(TabLayoutSetting.sidebar)
                    Label("Tab strip", systemImage: "rectangle.topthird.inset.filled").tag(TabLayoutSetting.strip)
                }
                .pickerStyle(.segmented)
                if model.settings.tabLayout == .sidebar {
                    LabeledContent("Sidebar width") {
                        HStack(spacing: 8) {
                            Slider(value: $model.settings.sidebarWidth, in: Preferences.Settings.sidebarWidthRange, step: 10)
                                .frame(maxWidth: 200)
                            Text("\(Int(model.settings.sidebarWidth)) pt")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 48, alignment: .trailing)
                        }
                    }
                }
                Toggle("Hide the tab list", isOn: $model.settings.tabListHidden)
            }

            Section("New tabs") {
                Picker("Open new tabs in", selection: $model.settings.newTabDirectory) {
                    Text("The current pane's folder").tag(NewTabDirectory.currentPane)
                    Text("Home folder").tag(NewTabDirectory.home)
                }
            }

            Section("Windows") {
                Toggle("Reopen windows and tabs at launch", isOn: $model.settings.restoreSession)
                Toggle("Keep each tab's output when quitting", isOn: $model.settings.restoreScrollback)
                    .disabled(!model.settings.restoreSession)
                    .help("Reopened tabs show what they printed before, above a fresh prompt (zsh).")
                Toggle("Ask before closing a running process", isOn: $model.settings.confirmCloseRunning)
            }

            Section {
                if model.settings.savedCommands.isEmpty {
                    Text("None yet. Save a command from its block (the bookmark button, or right-click it).")
                        .foregroundStyle(.secondary)
                }
                ForEach($model.settings.savedCommands) { $saved in
                    HStack {
                        TextField("Name", text: $saved.name)
                            .frame(maxWidth: 160)
                        Text(saved.command)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer()
                        Button {
                            model.settings.savedCommands.removeAll { $0.id == saved.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Delete \(saved.name)")
                    }
                }
            } header: {
                Text("Saved commands")
            } footer: {
                Text("In ⌘K by name: Return runs one in the focused pane, ⌘Return in a new tab.")
            }

            Section {
                Toggle("Allow the promptty command to control the app", isOn: $model.settings.remoteControl)
            } header: {
                Text("Command line")
            } footer: {
                Text("Every terminal has `promptty` on its PATH: list tabs, open and split panes, type into them and read them from scripts and agents. Run `promptty help` in a pane.")
            }

            Section {
                Toggle("Mark tabs that printed while you looked elsewhere", isOn: $model.settings.markUnseenOutput)
                Toggle("Notify when a long command finishes", isOn: $model.settings.notifyCommands)
                Picker("Long means at least", selection: $model.settings.notifyAfterSeconds) {
                    ForEach([3.0, 5, 10, 30, 60, 300], id: \.self) { seconds in
                        Text(seconds < 60 ? "\(Int(seconds)) seconds" : "\(Int(seconds / 60)) min").tag(seconds)
                    }
                }
                .disabled(!model.settings.notifyCommands)
            } header: {
                Text("Notifications")
            } footer: {
                Text("Only for commands in a tab or window you are not looking at. Agents always tell you when they finish or need you.")
            }

            Section("Clipboard access by programs") {
                Picker("Reading the clipboard", selection: $model.settings.clipboardRead) {
                    Text("Ask").tag(ClipboardAccess.ask)
                    Text("Allow").tag(ClipboardAccess.allow)
                    Text("Deny").tag(ClipboardAccess.deny)
                }
                Picker("Writing to the clipboard", selection: $model.settings.clipboardWrite) {
                    Text("Ask").tag(ClipboardAccess.ask)
                    Text("Allow").tag(ClipboardAccess.allow)
                    Text("Deny").tag(ClipboardAccess.deny)
                }
                AllowedClipboardPrograms(title: "Always allowed to read", programs: $model.settings.clipboardReadPrograms)
                AllowedClipboardPrograms(title: "Always allowed to write", programs: $model.settings.clipboardWritePrograms)
            }
        }
        .formStyle(.grouped)
    }
}

/// The programs the clipboard banner's "Always allow for <program>" let through, each removable.
/// Shown only once there is one.
private struct AllowedClipboardPrograms: View {
    let title: String
    @Binding var programs: Set<String>

    var body: some View {
        if !programs.isEmpty {
            LabeledContent(title) {
                VStack(alignment: .trailing, spacing: 4) {
                    ForEach(programs.sorted(), id: \.self) { id in
                        HStack(spacing: 6) {
                            Text(ProgramCatalog.all.first { $0.id == id }?.name ?? id)
                            Button {
                                programs.remove(id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Ask again")
                        }
                    }
                }
            }
        }
    }
}

struct KeyboardSection: View {
    @Bindable var model: SettingsModel

    /// A rejected or conflicting recording, shown under its row.
    @State private var problem: (action: ShortcutAction, shortcut: Shortcut, error: ShortcutMap.ValidationError)?

    private var map: ShortcutMap { model.shortcuts }

    var body: some View {
        Form {
            Section {
                Picker("Option key acts as Alt", selection: $model.settings.optionAsAlt) {
                    Text("Both").tag(OptionAsAlt.both)
                    Text("Left only").tag(OptionAsAlt.left)
                    Text("Right only").tag(OptionAsAlt.right)
                    Text("Off").tag(OptionAsAlt.off)
                }
                Toggle("Vim-style navigation", isOn: $model.settings.vimNavigation)
                Toggle("Quick terminal drops down from any app", isOn: $model.settings.quickTerminal)
                    .help("Its shortcut is set below, under Window.")
            } header: {
                Text("Terminal")
            } footer: {
                Text("Vim-style navigation: ⌥H, ⌥J, ⌥K and ⌥L focus the pane in that direction, ⌥⇧J and ⌥⇧K go to the next and previous tab. Apart from those, PrompTTY only uses shortcuts with ⌘: every other ⌃, ⌥ and ⌃⇧ combination goes straight to the terminal and the programs in it, like Neovim. Turn Alt off to type characters such as å with ⌥.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            ForEach(ShortcutGroup.allCases, id: \.self) { group in
                Section(group.title) {
                    ForEach(ShortcutAction.allCases.filter { $0.group == group }, id: \.self) { action in
                        row(action)
                    }
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button("Restore Defaults") {
                        problem = nil
                        model.settings.shortcuts = [:]
                    }
                    .disabled(model.settings.shortcuts.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func row(_ action: ShortcutAction) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(action.title) {
                ShortcutRecorder(
                    shortcut: map.shortcut(for: action),
                    isDefault: map.shortcut(for: action) == ShortcutMap.defaults[action],
                    onCapture: { record($0, for: action) },
                    onReset: { apply(map.resetting(action)) }
                )
            }
            if let problem, problem.action == action {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                    Text(message(for: problem.error, shortcut: problem.shortcut))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if case .conflict = problem.error {
                        Button("Swap") {
                            apply(map.assigning(problem.shortcut, to: action))
                            self.problem = nil
                        }
                        .controlSize(.small)
                    }
                    Button("Dismiss") { self.problem = nil }
                        .controlSize(.small)
                }
            }
        }
    }

    private func record(_ shortcut: Shortcut, for action: ShortcutAction) {
        if let error = map.validate(shortcut, for: action) {
            problem = (action, shortcut, error)
            return
        }
        problem = nil
        apply(map.assigning(shortcut, to: action))
    }

    private func apply(_ newMap: ShortcutMap) {
        model.settings.shortcuts = newMap.overrides
    }

    private func message(for error: ShortcutMap.ValidationError, shortcut: Shortcut) -> String {
        switch error {
        case .missingCommand:
            return "\(shortcut.displayString) has no ⌘. Shortcuts need ⌘ so that keys like ⌃ and ⌥ always reach the terminal."
        case .missingModifier:
            return "\(shortcut.displayString) needs ⌘, ⌥, ⌃ or ⇧: it works in every app."
        case .reserved:
            return "\(shortcut.displayString) belongs to macOS or the app menu and can't be reassigned."
        case .conflict(let other):
            return "\(shortcut.displayString) is used by \(other.title)."
        }
    }
}

/// The cursor's color: the theme's, the system accent color, or a custom one from a color well.
private struct CursorColorRow: View {
    @Binding var color: CursorColor

    private enum Choice: Hashable { case theme, accent, custom }

    /// The last custom color, kept while Theme or Accent is chosen so switching back restores it.
    @State private var lastCustom: UInt32 = 0xFF9F0A
    /// The hex field's text while it is edited.
    @State private var hexDraft = ""
    @FocusState private var hexFocused: Bool

    private var hexIsValid: Bool { CursorColor.parseHex(hexDraft) != nil }

    private var choice: Binding<Choice> {
        Binding {
            switch color {
            case .theme: .theme
            case .accent: .accent
            case .custom: .custom
            }
        } set: { choice in
            switch choice {
            case .theme: color = .theme
            case .accent: color = .accent
            case .custom: color = .custom(lastCustom)
            }
        }
    }

    private var custom: Binding<Color> {
        Binding {
            guard case .custom(let rgb) = color else { return Self.swiftUIColor(lastCustom) }
            return Self.swiftUIColor(rgb)
        } set: { new in
            guard let rgb = Self.rgb(new) else { return }
            lastCustom = rgb
            color = .custom(rgb)
        }
    }

    var body: some View {
        LabeledContent("Color") {
            HStack(spacing: 8) {
                Picker("Color", selection: choice) {
                    Text("Theme").tag(Choice.theme)
                    Text("Accent").tag(Choice.accent)
                    Text("Custom").tag(Choice.custom)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                if case .custom = color {
                    TextField("Hex", text: $hexDraft, prompt: Text("#RRGGBB"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 76)
                        .focused($hexFocused)
                        .onSubmit(commitHex)
                        // An unreadable value is marked while typed, and dropped when left.
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(Color.red.opacity(hexIsValid || hexDraft.isEmpty ? 0 : 0.8), lineWidth: 1)
                                .allowsHitTesting(false)
                        )
                        .onChange(of: hexFocused) { _, focused in if !focused { commitHex() } }
                        .accessibilityLabel("Cursor color hex code")
                    ColorPicker("Cursor color", selection: custom, supportsOpacity: false)
                        .labelsHidden()
                }
            }
        }
        .onAppear {
            if case .custom(let rgb) = color { lastCustom = rgb }
            syncHex()
        }
        // The color well or the segments changed it: the field follows, unless it is being typed in.
        .onChange(of: color) { _, _ in if !hexFocused { syncHex() } }
    }

    private func syncHex() {
        if case .custom(let rgb) = color { hexDraft = CursorColor.formatHex(rgb) }
    }

    /// ⏎ or leaving the field: a readable hex code becomes the color (shown as `#RRGGBB`); anything
    /// else goes back to the current color.
    private func commitHex() {
        if let rgb = CursorColor.parseHex(hexDraft) {
            lastCustom = rgb
            color = .custom(rgb)
        }
        syncHex()
    }

    private static func swiftUIColor(_ rgb: UInt32) -> Color {
        Color(.sRGB, red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }

    private static func rgb(_ color: Color) -> UInt32? {
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        func byte(_ v: CGFloat) -> UInt32 { UInt32((min(max(v, 0), 1) * 255).rounded()) }
        return byte(c.redComponent) << 16 | byte(c.greenComponent) << 8 | byte(c.blueComponent)
    }
}
