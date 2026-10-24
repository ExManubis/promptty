import AppKit
import PrompTTYChrome
import SwiftUI

/// Over the top of a terminal scrolled back into a command's output: the command, and how it
/// ended. A click scrolls back to the command.
struct StickyHeader: View {
    struct Model: Equatable {
        var command = ""
        var exitCode: Int?
        var running = false
        var dark = true
        var font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    }

    let model: Model
    var onTap: () -> Void = {}

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(model.command.split(separator: "\n").first.map(String.init) ?? "")
                    .font(Font(model.font.withSize(min(model.font.pointSize, 13)) as CTFont))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                status
            }
            .padding(.horizontal, 8)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(FlatSurface(cornerRadius: 6))
        .environment(\.colorScheme, model.dark ? .dark : .light)
        .help("Scroll to the command")
        .accessibilityLabel("Scroll to \(model.command)")
    }

    @ViewBuilder private var status: some View {
        if model.running {
            Text("running")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        } else if let code = model.exitCode, code != 0 {
            Label("\(code)", systemImage: "xmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.red)
        }
    }
}

/// On the block under the pointer: copy its output, its command, or both as Markdown; rerun it;
/// save it for the palette.
struct BlockButtons: View {
    struct Actions {
        /// Each copy says whether it copied: then its button shows a ✓ for a moment.
        var copyOutput: () -> Bool = { false }
        var copyCommand: () -> Bool = { false }
        var copyMarkdown: () -> Bool = { false }
        var rerun: () -> Void = {}
        var save: () -> Void = {}
    }

    let actions: Actions
    /// The copy button that just copied, showing a ✓.
    @State private var copied: String?
    @State private var reset: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 0) {
            copyButton("doc.on.doc", help: "Copy Output", action: actions.copyOutput)
            copyButton("chevron.forward.square", help: "Copy Command", action: actions.copyCommand)
            copyButton("text.badge.checkmark", help: "Copy as Markdown", action: actions.copyMarkdown)
            HeaderButton(symbol: "arrow.clockwise", help: "Rerun in the input bar", action: actions.rerun)
            HeaderButton(symbol: "bookmark", help: "Save Command to the palette", action: actions.save)
        }
        .padding(.horizontal, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FlatSurface(cornerRadius: 7))
    }

    private func copyButton(_ symbol: String, help: String, action: @escaping () -> Bool) -> some View {
        HeaderButton(symbol: copied == symbol ? "checkmark" : symbol, help: help) {
            guard action() else { return }
            copied = symbol
            reset?.cancel()
            reset = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.2))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.15)) { copied = nil }
            }
        }
        .contentTransition(.symbolEffect(.replace))
    }
}

/// Over a scrolled-back terminal that printed more below: how much, and a way down to it.
struct NewOutputPill: View {
    /// Changes as lines arrive; the view stays.
    @MainActor @Observable final class Model {
        var count = 0
    }

    let model: Model
    let action: () -> Void

    var body: some View {
        let count = model.count
        return Button(action: action) {
            Label(Self.label(count), systemImage: "arrow.down")
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .help("Scroll to the newest output")
        .accessibilityLabel("\(Self.label(count)) below. Scroll to the newest output.")
    }

    static func label(_ count: Int) -> String { count == 1 ? "1 new line" : "\(count) new lines" }
}
