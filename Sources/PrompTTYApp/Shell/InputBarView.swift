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
                .popover(isPresented: Binding(get: { shell.historyPicker != nil },
                                              set: { if !$0 { shell.closeHistorySearch() } }), arrowEdge: .top) {
                    if let picker = shell.historyPicker {
                        HistoryPickerView(model: picker, choose: { shell.chooseHistoryCommand($0) },
                                          cancel: { shell.closeHistorySearch(returningKeys: true) })
                    }
                }
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
                BranchButton(shell: shell, git: git)
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
        .font(.system(size: 12, weight: .medium))
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
    static let maxWidth: CGFloat = 280
    @State private var picking = false
    @State private var picker: FolderPickerModel?

    var body: some View {
        Button {
            // One model per opening: it lists the folder once, however often the header redraws.
            picker = FolderPickerModel(directory: shell.directory)
            picking = true
        } label: {
            Label {
                // The last folders, cut at the front if they still do not fit.
                Text(FolderLabel.short(shell.directory, home: NSHomeDirectory()))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .capped(width: Self.maxWidth)
            } icon: {
                Image(systemName: "folder")
            }
        }
        .buttonStyle(HeaderChipStyle(open: picking, color: Color(nsColor: shell.folderColor)))
        .disabled(shell.bar != .active)
        .help("Change Folder")
        .accessibilityLabel("Folder \(Tab.abbreviate(shell.directory))")
        .accessibilityHint("Opens a list of folders to change to")
        .popover(isPresented: $picking, arrowEdge: .top) {
            if let picker {
                FolderPickerView(model: picker, choose: { path in
                    picking = false
                    shell.returnKeysToBar()
                    shell.changeDirectory(to: path)
                }, cancel: {
                    picking = false
                    shell.returnKeysToBar()
                })
            }
        }
    }
}

/// The header's branch: a button that opens the branch picker and switches to (or creates) the
/// branch chosen.
private struct BranchButton: View {
    let shell: PaneShell
    let git: GitStatus
    static let maxWidth: CGFloat = 200
    @State private var picking = false
    @State private var picker: BranchPickerModel?

    var body: some View {
        Button {
            picker = BranchPickerModel(git: git)
            picking = true
        } label: {
            Label {
                HStack(spacing: 3) {
                    // `…feature/long-name`: the end of a branch's name tells it apart.
                    Text(git.branch)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .capped(width: Self.maxWidth)
                    if git.dirty {
                        Circle().frame(width: 5, height: 5).accessibilityLabel("uncommitted changes")
                    }
                }
            } icon: {
                Image(systemName: "arrow.triangle.branch")
            }
        }
        .buttonStyle(HeaderChipStyle(open: picking, color: Color(nsColor: shell.branchColor)))
        .disabled(shell.bar != .active)
        .help("Switch Branch")
        .accessibilityLabel("Branch \(git.branch)\(git.dirty ? ", uncommitted changes" : "")")
        .accessibilityHint("Opens a list of branches to switch to")
        .popover(isPresented: $picking, arrowEdge: .top) {
            if let picker {
                BranchPickerView(model: picker, shell: shell, choose: { row in
                    picking = false
                    shell.returnKeysToBar()
                    shell.switchBranch(row)
                }, cancel: {
                    picking = false
                    shell.returnKeysToBar()
                })
            }
        }
    }
}

/// A header item that opens a picker: its text in the theme's color, in a hairline outline that
/// fills in under the pointer and while its picker is open.
private struct HeaderChipStyle: ButtonStyle {
    let open: Bool
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        HeaderChip(label: configuration.label, open: open, pressed: configuration.isPressed, color: color)
    }
}

private struct HeaderChip<Content: View>: View {
    let label: Content
    let open: Bool
    let pressed: Bool
    let color: Color
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        label
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background {
                if hovering || open || pressed {
                    shape.fill(Color.primary.opacity(pressed ? 0.12 : 0.07))
                }
            }
            .overlay(shape.strokeBorder(Color.primary.opacity(0.16), lineWidth: 1))
            .opacity(enabled ? 1 : 0.6)
            .contentShape(shape)
            .onHover { hovering = $0 }
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

/// Its natural width, but at most `width`, and less when the header has less room: a long name
/// truncates instead of widening the pane. (A `frame(maxWidth:)` would stretch a short one.)
private struct CappedWidth: Layout {
    let width: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        return child.sizeThatFits(ProposedViewSize(width: min(proposal.width ?? .infinity, width), height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

private extension View {
    func capped(width: CGFloat) -> some View {
        CappedWidth(width: width) { self }
    }
}
