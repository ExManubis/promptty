import AppKit
import Preferences
import SwiftUI

/// A shortcut field: shows the current shortcut; click it, then press the new combination.
/// Escape cancels; Delete restores the default.
struct ShortcutRecorder: View {
    let shortcut: Shortcut
    let isDefault: Bool
    let onCapture: (Shortcut) -> Void
    let onReset: () -> Void

    @State private var recording = false
    @State private var liveModifiers: NSEvent.ModifierFlags = []

    var body: some View {
        HStack(spacing: 4) {
            Button {
                recording.toggle()
            } label: {
                Text(recording ? (liveModifiers.isEmpty ? "Type shortcut…" : Self.symbols(liveModifiers)) : shortcut.displayString)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(recording ? Color.accentColor : Color.primary)
                    .frame(minWidth: 96)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(recording ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(recording ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: recording ? 1.5 : 0.5)
                    )
            }
            .buttonStyle(.plain)
            .background {
                if recording {
                    KeyCapture(
                        onModifiers: { liveModifiers = $0 },
                        onKey: { event in
                            recording = false
                            liveModifiers = []
                            if let s = Self.shortcut(from: event) { onCapture(s) }
                        },
                        onEscape: { recording = false; liveModifiers = [] },
                        onDelete: { recording = false; liveModifiers = []; onReset() },
                        onResign: { recording = false; liveModifiers = [] }
                    )
                    .frame(width: 1, height: 1)
                }
            }
            .accessibilityLabel(recording ? "Recording shortcut" : "Shortcut \(shortcut.displayString)")
            .accessibilityHint("Click, then press the new key combination. Escape cancels; Delete restores the default.")

            Button(action: onReset) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .opacity(isDefault ? 0 : 1)
            .disabled(isDefault)
            .help("Restore default")
            .accessibilityLabel("Restore default shortcut")
        }
    }

    static func symbols(_ flags: NSEvent.ModifierFlags) -> String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s
    }

    /// The pressed combination as a `Shortcut`: named keys by key code, everything else by the
    /// character the key produces without modifiers (so ⇧⌘] records as ⇧⌘], not ⌘}).
    static func shortcut(from event: NSEvent) -> Shortcut? {
        let named: [UInt16: String] = [
            123: "left", 124: "right", 125: "down", 126: "up",
            36: "return", 76: "return", 48: "tab", 51: "delete", 53: "escape", 49: "space",
        ]
        var mods: Shortcut.Modifiers = []
        let flags = event.modifierFlags
        if flags.contains(.command) { mods.insert(.command) }
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.control) { mods.insert(.control) }
        if let name = named[event.keyCode] { return Shortcut(key: name, modifiers: mods) }
        // Events made in code (the debug driver's) have no layout to apply modifiers through.
        guard let base = (event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers)?.lowercased(),
              base.count == 1 else { return nil }
        return Shortcut(key: base, modifiers: mods)
    }
}

/// Invisible first responder that captures one key combination, ⌘ keys included, before the
/// menu bar sees it.
private struct KeyCapture: NSViewRepresentable {
    let onModifiers: (NSEvent.ModifierFlags) -> Void
    let onKey: (NSEvent) -> Void
    let onEscape: () -> Void
    let onDelete: () -> Void
    let onResign: () -> Void

    func makeNSView(context: Context) -> KeyCaptureView { KeyCaptureView() }

    func updateNSView(_ view: KeyCaptureView, context: Context) {
        view.onModifiers = onModifiers
        view.onKey = onKey
        view.onEscape = onEscape
        view.onDelete = onDelete
        view.onResign = onResign
    }
}

final class KeyCaptureView: NSView {
    var onModifiers: ((NSEvent.ModifierFlags) -> Void)?
    var onKey: ((NSEvent) -> Void)?
    var onEscape: (() -> Void)?
    var onDelete: (() -> Void)?
    var onResign: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onResign?() }
        return ok
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown else { return false }
        handle(event)
        return true
    }

    override func keyDown(with event: NSEvent) { handle(event) }

    override func flagsChanged(with event: NSEvent) {
        onModifiers?(event.modifierFlags.intersection([.command, .shift, .option, .control]))
    }

    private func handle(_ event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if event.keyCode == 53, mods.isEmpty { onEscape?(); return }
        if event.keyCode == 51 || event.keyCode == 117, mods.isEmpty { onDelete?(); return }
        onKey?(event)
    }
}
