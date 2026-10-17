import AppKit
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
        var copyOutput: () -> Void = {}
        var copyCommand: () -> Void = {}
        var copyMarkdown: () -> Void = {}
        var rerun: () -> Void = {}
        var save: () -> Void = {}
    }

    let actions: Actions

    var body: some View {
        HStack(spacing: 0) {
            HeaderButton(symbol: "doc.on.doc", help: "Copy Output", action: actions.copyOutput)
            HeaderButton(symbol: "chevron.forward.square", help: "Copy Command", action: actions.copyCommand)
            HeaderButton(symbol: "text.badge.checkmark", help: "Copy as Markdown", action: actions.copyMarkdown)
            HeaderButton(symbol: "arrow.clockwise", help: "Rerun in the input bar", action: actions.rerun)
            HeaderButton(symbol: "bookmark", help: "Save Command to the palette", action: actions.save)
        }
        .padding(.horizontal, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FlatSurface(cornerRadius: 7))
    }
}
