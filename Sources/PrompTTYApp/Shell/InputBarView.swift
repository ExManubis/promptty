import CommandEditing
import SwiftUI
import WorkspaceModel

/// The input bar at the bottom of a pane at a prompt: a Liquid Glass box, inset from the card's
/// edges, holding a header in place of the shell prompt and the editor below it.
struct InputBarView: View {
    let shell: PaneShell
    let dark: Bool

    static let cornerRadius: CGFloat = 12
    /// From the card's edges to the box.
    static let inset: CGFloat = 8
    static let minHeight: CGFloat = 88

    var body: some View {
        // The header sits near the top edge; the input is centered in the space below it.
        VStack(alignment: .leading, spacing: 0) {
            ShellHeaderView(shell: shell)
                .padding(.top, 9)
            Spacer(minLength: 6)
            LongLivedViewHost(view: shell.editor, dark: dark)
                .frame(height: shell.editorHeight)
                .opacity(shell.bar == .active ? 1 : 0.45)
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 14)
        // 88 pt for a one-line command; longer commands grow the box.
        .frame(maxWidth: .infinity, minHeight: Self.minHeight, alignment: .leading)
        // Its own height, not a share of the pane: the spacers only divide the box's inside.
        .fixedSize(horizontal: false, vertical: true)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .padding([.horizontal, .bottom], Self.inset)
        .padding(.top, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command input")
    }
}

/// Where the next command runs and how the last one ended, in place of the shell prompt.
struct ShellHeaderView: View {
    let shell: PaneShell

    var body: some View {
        HStack(spacing: 10) {
            FolderButton(shell: shell)
            if let git = shell.git {
                Label {
                    HStack(spacing: 3) {
                        Text(git.branch).lineLimit(1)
                        if git.dirty {
                            Circle().frame(width: 5, height: 5).accessibilityLabel("uncommitted changes")
                        }
                    }
                } icon: {
                    Image(systemName: "arrow.triangle.branch")
                }
            }
            Spacer(minLength: 0)
            if let exit = shell.state.lastExit {
                if exit.duration >= 1 {
                    Text(Self.duration(exit.duration))
                        .monospacedDigit()
                }
                if exit.code > 0 {
                    Label("\(exit.code)", systemImage: "xmark")
                        .foregroundStyle(.red)
                } else if exit.code == 0 {
                    Image(systemName: "checkmark")
                        .accessibilityLabel("succeeded")
                }
            }
        }
        .labelStyle(HeaderLabelStyle())
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return m < 60 ? "\(m)m \(s)s" : "\(m / 60)h \(m % 60)m"
    }
}

/// The header's folder: a button that opens the folder picker and changes to the folder chosen.
private struct FolderButton: View {
    let shell: PaneShell
    @State private var picking = false
    @State private var picker: FolderPickerModel?
    @State private var hovering = false

    var body: some View {
        Button {
            // One model per opening: it lists the folder once, however often the header redraws.
            picker = FolderPickerModel(directory: shell.directory)
            picking = true
        } label: {
            Label {
                Text(Tab.abbreviate(shell.directory))
                    .lineLimit(1)
                    .truncationMode(.head)
            } icon: {
                Image(systemName: "folder")
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background {
                if hovering || picking {
                    RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.08))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Flush with the editor's text below, as the plain label was.
        .padding(.horizontal, -5)
        .disabled(shell.bar != .active)
        .onHover { hovering = $0 }
        .help("Change Folder")
        .accessibilityLabel("Folder \(Tab.abbreviate(shell.directory))")
        .accessibilityHint("Opens a list of folders to change to")
        .popover(isPresented: $picking, arrowEdge: .top) {
            if let picker {
                FolderPickerView(model: picker, choose: { path in
                    close()
                    shell.changeDirectory(to: path)
                }, cancel: close)
            }
        }
    }

    /// Closed from the picker (⏎, ⎋, a click on a folder): the keys go back to the bar. Closed by a
    /// click elsewhere, the keys stay where that click put them.
    private func close() {
        picking = false
        DispatchQueue.main.async {
            let editor = shell.editor.textView
            editor.window?.makeFirstResponder(editor)
        }
    }
}

private struct HeaderLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}
