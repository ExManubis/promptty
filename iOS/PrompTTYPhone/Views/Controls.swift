import PaneActivity
import PrompTTYChrome
import SwiftUI

/// Under the pane, in glass: the tab's panes (its splits) to switch between, and the keys a phone's
/// keyboard lacks.
struct Controls: View {
    @Bindable var model: PhoneModel
    let tab: PhoneTab
    /// All the keys, where there is room (an open iPhone Duo); a phone's row keeps the arrows to ↑.
    var wide = false

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(spacing: 8) {
                PaneSwitcher(model: model, tab: tab)
                KeyRow(model: model, wide: wide)
            }
        }
    }
}

/// The tab's panes as their program tiles, the focused one on a thumb, and "+" for a split.
private struct PaneSwitcher: View {
    @Bindable var model: PhoneModel
    let tab: PhoneTab

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                ForEach(tab.panes) { pane in
                    let focused = pane.id == tab.focusedPane
                    Button { model.focus(pane.id, in: tab.id) } label: {
                        ProgramStack(cards: [ProgramStack.Card(id: pane.id, program: pane.program, display: pane.display)], scale: 1.1)
                            .frame(width: 44, height: 28)
                            .background {
                                if focused {
                                    Capsule().fill(Color.white.opacity(0.12))
                                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
                                }
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(pane.program?.name ?? "Terminal")
                }
            }
            .padding(3)
            .glassControl(Capsule(), interactive: false)
            Button {} label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 34, height: 34)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .glassControl(Circle())
            .accessibilityLabel("Split")
        }
    }
}

/// ⌘ in a glass circle, the keys, and the keyboard's toggle in a glass capsule, as Rex's.
private struct KeyRow: View {
    @Bindable var model: PhoneModel
    let wide: Bool

    private var keys: [String] {
        wide ? ["esc", "ctrl", "opt", "tab", "←", "↓", "↑", "→"] : ["esc", "ctrl", "opt", "tab", "↑"]
    }

    var body: some View {
        HStack(spacing: 4) {
            Button { model.toggleLatch("⌘") } label: {
                Image(systemName: "command")
                    .font(.system(size: 18, weight: .regular))
                    .frame(width: PhoneMetrics.control, height: PhoneMetrics.control)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.latched.contains("⌘") ? Color.accentColor : Color.primary)
            .glassControl(Circle())
            .accessibilityLabel("Command")
            .accessibilityValue(model.latched.contains("⌘") ? "on" : "off")
            .accessibilityIdentifier("key.command")
            HStack(spacing: 0) {
                ForEach(keys, id: \.self) { key in
                    let modifier = key == "ctrl" || key == "opt"
                    Button { if modifier { model.toggleLatch(key) } else { model.pressKey(key) } } label: {
                        Text(key)
                            .font(key.count > 1 ? .system(size: 15, design: .monospaced) : .system(size: 19))
                            .frame(maxWidth: .infinity, minHeight: PhoneMetrics.control)
                            .background {
                                if model.latched.contains(key) {
                                    Capsule().fill(Color.white.opacity(0.14)).padding(.vertical, 8)
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.primary.opacity(0.88))
                }
            }
            Button { model.toggleKeyboard() } label: {
                Image(systemName: "keyboard")
                    .font(.system(size: 18))
                    .frame(width: 60, height: PhoneMetrics.control)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .glassControl(Capsule())
            .accessibilityLabel("Keyboard")
        }
    }
}
