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
        VStack(alignment: .leading, spacing: 8) {
            ShellHeaderView(shell: shell)
            LongLivedViewHost(view: shell.editor, dark: dark)
                .frame(height: shell.editorHeight)
                .opacity(shell.bar == .active ? 1 : 0.45)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        // 88 pt for a one-line command, the content centered; longer commands grow the box.
        .frame(maxWidth: .infinity, minHeight: Self.minHeight, alignment: .leading)
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
            Label {
                Text(Tab.abbreviate(shell.directory))
                    .lineLimit(1)
                    .truncationMode(.head)
            } icon: {
                Image(systemName: "folder")
            }
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

private struct HeaderLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}
