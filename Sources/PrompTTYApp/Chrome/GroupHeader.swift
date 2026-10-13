import PaneActivity
import SwiftUI
import WorkspaceModel

/// A project's header in the sidebar, above its tabs. A click folds it; folded, it shows how many
/// it holds and their most urgent activity. Menus, drops and the icon picker are the caller's.
struct GroupHeader: View {
    enum Symbol {
        /// A project without an icon of its own.
        case folder
        case icon(PinIcon)
    }

    let title: String
    /// The tooltip.
    let help: String
    let symbol: Symbol
    let count: Int
    /// What "count" counts, for VoiceOver: "tab".
    let noun: String
    /// The most urgent activity inside, shown while folded.
    var display: PaneActivity.Display?
    let folded: Bool
    /// Folded over the selected tab.
    var selected = false
    /// A tab dragged over it would join the project.
    var dropTarget = false
    /// A "+" on hover: a new tab in the project.
    var onAdd: (() -> Void)?
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 2) {
            // A tap, not a Button: a Button would swallow the drag that reorders projects.
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
                if folded {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 2)
                // Folded, the header stands for its tabs.
                if folded, let display { ActivityIndicator(display: display) }
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)
            .help(help)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { toggle() }
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

/// A project's header in the tab list. A tap folds it; it drags to reorder the projects (dropped
/// on another project's header it takes that one's place, as a tab dropped on a tab does); a tab
/// dropped on it joins the project; its menu is the project's; its "+" opens a tab in the project.
struct ProjectHeader: View {
    let project: Project
    let count: Int
    /// What `count` counts: "tab".
    let noun: String
    /// The most urgent activity inside, shown while folded.
    var display: PaneActivity.Display?
    let selected: Bool
    let chrome: WindowChromeModel
    let actions: ChromeActions
    @State private var dropTargeted = false

    var body: some View {
        GroupHeader(title: project.name, help: project.name, symbol: GroupHeader.Symbol(project),
                    count: count, noun: noun, display: display, folded: project.folded,
                    selected: selected, dropTarget: dropTargeted,
                    onAdd: { actions.newTab(inProject: project.id) }) {
            withAnimation(.easeOut(duration: 0.15)) { actions.setProjectFolded(project.id, !project.folded) }
        }
        .contextMenu { ProjectMenu(project: project, chrome: chrome, actions: actions) }
        .onDrag {
            chrome.beginProjectDrag(project.id)
            return DragPayload.provider(DragPayload.project, id: project.id.rawValue)
        }
        .onDrop(of: [DragPayload.project, DragPayload.tab],
                delegate: ProjectHeaderDropDelegate(project: project, targeted: $dropTargeted, chrome: chrome, actions: actions))
        .popover(isPresented: Binding(get: { chrome.iconPickerProject == project.id },
                                      set: { if !$0, chrome.iconPickerProject == project.id { chrome.iconPickerProject = nil } }),
                 arrowEdge: .trailing) {
            PinIconPicker(current: project.icon) { actions.setProjectIcon(project.id, $0) }
        }
    }
}

/// A project's context menu.
struct ProjectMenu: View {
    let project: Project
    let chrome: WindowChromeModel
    let actions: ChromeActions

    var body: some View {
        Button("New Tab in \(project.name)") { actions.newTab(inProject: project.id) }
        Divider()
        Button("Rename…") { actions.renameProject(project.id) }
        Button("Change Icon…") { chrome.iconPickerProject = project.id }
        Divider()
        let index = actions.projects.firstIndex { $0.id == project.id }
        Button("Move Up") { actions.moveProject(project.id, by: -1) }
            .disabled(index == 0)
        Button("Move Down") { actions.moveProject(project.id, by: 1) }
            .disabled(index == actions.projects.count - 1)
        Divider()
        Button("Remove Project…") { actions.requestRemoveProject(project.id) }
    }
}

/// A project header takes other projects' headers (reorder: the dragged one takes its place) and
/// tabs (into the project, last).
private struct ProjectHeaderDropDelegate: DropDelegate {
    let project: Project
    @Binding var targeted: Bool
    let chrome: WindowChromeModel
    let actions: ChromeActions

    func dropEntered(info: DropInfo) {
        MainActor.assumeIsolated {
            // Over its own header a project drag means nothing.
            targeted = !(info.hasItemsConforming(to: [DragPayload.project]) && chrome.draggingProject == project.id)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        MainActor.assumeIsolated {
            info.hasItemsConforming(to: [DragPayload.project]) && chrome.draggingProject == project.id
                ? DropProposal(operation: .forbidden) : DropProposal(operation: .move)
        }
    }

    func dropExited(info: DropInfo) {
        MainActor.assumeIsolated { targeted = false }
    }

    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated {
            targeted = false
            let target = project.id
            if DragPayload.loadID(DragPayload.project, from: info.itemProviders(for: [DragPayload.project]), completion: { [actions] id in
                chrome.draggingProject = nil
                guard let index = actions.projects.firstIndex(where: { $0.id == target }) else { return }
                actions.moveProject(ProjectID(rawValue: id), to: index)
            }) {
                return true
            }
            chrome.draggingTab = nil
            return DragPayload.loadID(DragPayload.tab, from: info.itemProviders(for: [DragPayload.tab])) { [actions] id in
                actions.placeTab(TabID(rawValue: id), inProject: target, at: nil)
            }
        }
    }
}
