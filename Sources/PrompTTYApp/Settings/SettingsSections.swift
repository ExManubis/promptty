import AppKit
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

            Section("Cursor") {
                Picker("Style", selection: $model.settings.cursorStyle) {
                    Label("Block", systemImage: "rectangle.fill").tag(CursorStyle.block)
                    Label("Bar", systemImage: "line.3.horizontal.decrease").tag(CursorStyle.bar)
                    Label("Underline", systemImage: "underline").tag(CursorStyle.underline)
                }
                .pickerStyle(.segmented)
                Toggle("Blink", isOn: $model.settings.cursorBlink)
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
                Toggle("Ask before closing a running process", isOn: $model.settings.confirmCloseRunning)
            }
        }
        .formStyle(.grouped)
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
        case .reserved:
            return "\(shortcut.displayString) belongs to macOS or the app menu and can't be reassigned."
        case .conflict(let other):
            return "\(shortcut.displayString) is used by \(other.title)."
        }
    }
}
