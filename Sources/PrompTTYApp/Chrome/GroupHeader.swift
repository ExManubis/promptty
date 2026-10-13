import PaneActivity
import SwiftUI
import WorkspaceModel

/// A group's header in the sidebar: a sidebar project (above its tabs, and above its agents in the
/// Agents section) or, in the Agents section, a repository. A click folds it; folded, it shows how
/// many it holds. Menus, drops and the icon picker are the caller's.
struct GroupHeader: View {
    enum Symbol {
        /// A repository's group: no symbol.
        case none
        /// A project without an icon of its own.
        case folder
        case icon(PinIcon)
    }

    let title: String
    /// The tooltip: the folder.
    let help: String
    var symbol: Symbol = .none
    /// The project's folder is gone.
    var missing = false
    let count: Int
    /// What "count" counts, for VoiceOver: "agent", "tab".
    let noun: String
    /// The most urgent activity inside, shown while folded (the Agents section's headers only).
    var display: PaneActivity.Display?
    let folded: Bool
    /// Folded over the selected tab or the focused agent.
    var selected = false
    /// A tab dragged over it would join the project.
    var dropTarget = false
    /// A "+" on hover: a new tab in the project.
    var onAdd: (() -> Void)?
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 2) {
            Button(action: toggle) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(folded ? 0 : 90))
                        .frame(width: 10)
                    symbolView
                    Text(title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if missing {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                            .help("Folder not found: \(help)")
                    }
                    if folded {
                        Text("\(count)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Spacer(minLength: 2)
                    // Folded, the header stands for its agents.
                    if folded, let display { ActivityIndicator(display: display) }
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help)
            .accessibilityLabel("\(title), \(count) \(count == 1 ? noun : noun + "s")")
            .accessibilityValue(folded ? (selected ? "Collapsed, holds the selected item" : "Collapsed") : "Expanded")
            .accessibilityHint(folded ? "Shows its \(noun)s" : "Hides its \(noun)s")
            if let onAdd {
                Button(action: onAdd) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .opacity(hovering ? 1 : 0)
                .help("New Tab in \(title)")
                .accessibilityLabel("New tab in \(title)")
            }
        }
        .foregroundStyle(Color.primary.opacity(0.8))
        .padding(.leading, 6)
        .padding(.trailing, 6)
        .frame(height: 24)
        .background { RowBackground(selected: selected, hovering: hovering, dropTarget: dropTarget) }
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var symbolView: some View {
        switch symbol {
        case .none:
            EmptyView()
        case .folder:
            Image(systemName: "folder")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        case .icon(let icon):
            Image(systemName: icon.symbol)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(icon.color == .dark ? Color.secondary : PinIconChoices.colors(for: icon.color).background)
        }
    }
}

extension GroupHeader.Symbol {
    @MainActor
    init(_ project: Project) {
        self = project.icon.map(Self.icon) ?? .folder
    }
}
