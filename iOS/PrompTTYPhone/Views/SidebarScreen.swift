import PaneActivity
import PrompTTYChrome
import SwiftUI

/// The Mac's sidebar as the phone's home: the glass band (the Activity eye, settings, the sidebar
/// button), the Mac's name, each project's tabs under its header, and a search field that opens the
/// Mac switcher.
struct SidebarScreen: View {
    @Bindable var model: PhoneModel
    /// Beside the pane (an open iPhone Duo), the selected row stays lit and nothing slides in.
    var besidePane = false

    var body: some View {
        VStack(spacing: 0) {
            band
            ScrollView(.vertical) {
                // Not lazy: a Mac's tabs are few, and a lazy stack kept tab list rows where the
                // Activity's belonged when the eye switched lists (both are keyed by the tabs).
                VStack(spacing: 2) {
                    MachineHeaderRow(mac: model.mac) { model.switchingMac = true }
                    if model.showsActivity { activity } else { tabList }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
            SearchField { model.switchingMac = true }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
        }
    }

    /// The Activity eye and settings in one glass capsule, the sidebar button in a glass circle.
    private var band: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    BandButton(symbol: model.showsActivity ? "eye.fill" : "eye", label: "Activity",
                               badge: agentNews) { model.showsActivity.toggle() }
                        .accessibilityIdentifier("activity")
                        .accessibilityValue(model.showsActivity ? "on" : "off")
                    BandButton(symbol: "gearshape", label: "Settings") {}
                }
                .padding(.horizontal, 4)
                .glassControl(Capsule(), interactive: false)
                BandButton(symbol: "sidebar.left", label: "Show Pane") { model.paneOpen = true }
                    .frame(width: PhoneMetrics.control - 4, height: PhoneMetrics.control - 4)
                    .glassControl(Circle())
                    .opacity(besidePane ? 0 : 1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }

    /// An agent's tab out of sight has something new: the eye's dot.
    private var agentNews: Bool {
        model.allTabs.contains { $0.isAgent && $0.id != model.selectedTab && ($0.unseen || $0.permission != nil) }
    }

    @ViewBuilder
    private var tabList: some View {
        ForEach(model.projects) { project in
            ProjectHeaderRow(project: project, toggle: { model.toggleFold(project.id) })
            if !project.folded {
                ForEach(project.tabs) { tab in
                    TabRowView(tab: tab, selected: tab.id == model.selectedTab) { model.select(tab.id) }
                }
            }
        }
        NewTabRow()
    }

    @ViewBuilder
    private var activity: some View {
        let agents = model.projects.filter { $0.tabs.contains(where: \.isAgent) }
        ForEach(agents) { project in
            ProjectHeaderRow(project: project, toggle: nil)
            ForEach(project.tabs.filter(\.isAgent)) { tab in
                ActivityRowView(tab: tab, selected: tab.id == model.selectedTab) { model.select(tab.id) }
            }
        }
    }
}

private struct BandButton: View {
    let symbol: String
    let label: String
    var badge = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .regular))
                .frame(width: 40, height: 40)
                .overlay(alignment: .topTrailing) {
                    if badge {
                        Circle().fill(Color.accentColor).frame(width: 7, height: 7).offset(x: -6, y: 9)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .accessibilityLabel(label)
    }
}

/// The Mac's name above its projects, as the Mac's "This Mac" header; a tap switches Macs.
private struct MachineHeaderRow: View {
    let mac: PhoneMac
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: mac.symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: ProgramStack.width * PhoneMetrics.tileScale)
                Text(mac.name)
                    .font(.system(size: 16.5, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.85))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .padding(.leading, 10)
            .frame(height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(mac.name), switch Mac")
    }
}

/// A project's header: a plain gray label, as the Mac's, with its "+" and fold always shown, there
/// being no pointer to bring them up.
private struct ProjectHeaderRow: View {
    let project: PhoneProject
    let toggle: (() -> Void)?

    var body: some View {
        HStack(spacing: 14) {
            Text(project.name)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if project.folded {
                Text("\(project.tabs.count)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
            if let toggle {
                Image(systemName: "plus.circle")
                    .font(.system(size: 17))
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("New tab in \(project.name)")
                Button(action: toggle) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .rotationEffect(.degrees(project.folded ? -90 : 0))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .accessibilityLabel(project.folded ? "Show \(project.name)'s tabs" : "Hide \(project.name)'s tabs")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(height: 34)
        .padding(.top, 6)
    }
}

/// A tab's row, as the Mac sidebar's: its panes' program tiles, its title (an agent's row reads its
/// task alone; a shell's adds its folder, dimmed), and on the right what needs the user or "•••"
/// while an agent works. Selected, it sits on a glass pill.
struct TabRowView: View {
    let tab: PhoneTab
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                SidebarTabIcon(cards: cards(tab), badge: tab.unseen && !selected, scale: PhoneMetrics.tileScale)
                HStack(spacing: 6) {
                    Text(tab.title)
                        .font(.system(size: 17, weight: selected ? .medium : .regular))
                        .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.85))
                        .layoutPriority(1)
                    if !tab.isAgent {
                        Text(tab.lead.folder)
                            .font(.system(size: 17))
                            .foregroundStyle(.tertiary)
                            .truncationMode(.head)
                    }
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                if tab.permission != nil {
                    ActivityIndicator(display: .permission)
                        .scaleEffect(1.4)
                } else if tab.display == .working {
                    WorkingDots(scale: 1.2)
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 12)
            .frame(height: PhoneMetrics.rowHeight)
            .background { RowBackground(selected: selected, hovering: false, cornerRadius: PhoneMetrics.rowCornerRadius) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tab.\(tab.title)")
        .accessibilityLabel([tab.title, tab.permission != nil ? "needs permission" : nil, tab.display == .working ? "working" : nil]
            .compactMap { $0 }.joined(separator: ", "))
    }
}

/// A tab in the Activity: its agent's task, what it does and how long ago that changed.
private struct ActivityRowView: View {
    let tab: PhoneTab
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let lead = tab.lead
        Button(action: action) {
            HStack(spacing: 12) {
                SidebarTabIcon(cards: [ProgramStack.Card(id: lead.id, program: lead.program, display: lead.display)],
                               badge: tab.unseen && !selected, scale: PhoneMetrics.tileScale)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(tab.title)
                            .font(.system(size: 17, weight: selected ? .medium : .regular))
                            .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.85))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if lead.display == .working { WorkingDots(scale: 1.2) }
                    }
                    HStack(spacing: 6) {
                        Text(AgentListing.activity(display: lead.display, tool: lead.tool))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            Text(AgentListing.ago(context.date.timeIntervalSince(lead.since)))
                                .monospacedDigit()
                        }
                    }
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 12)
            .frame(height: 58)
            .background { RowBackground(selected: selected, hovering: false, cornerRadius: PhoneMetrics.rowCornerRadius) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("activity.\(tab.title)")
    }
}

/// The dim "+ New Tab" row that ends the tab list.
private struct NewTabRow: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "plus")
                .font(.system(size: 15))
                .frame(width: ProgramStack.width * PhoneMetrics.tileScale)
            Text("New Tab")
                .font(.system(size: 17))
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.leading, 10)
        .frame(height: 40)
    }
}

/// A glass search field at the bottom of the sidebar, as Rex's: it opens the Mac switcher (the
/// palette, later).
private struct SearchField: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .medium))
                Text("Search")
                    .font(.system(size: 17))
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .frame(height: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassControl(Capsule())
        .accessibilityIdentifier("search")
    }
}

/// A tab's panes as `ProgramStack` cards, the focused one first.
func cards(_ tab: PhoneTab) -> [ProgramStack.Card] {
    let ordered = tab.panes.filter { $0.id == tab.focusedPane } + tab.panes.filter { $0.id != tab.focusedPane }
    return ordered.map { ProgramStack.Card(id: $0.id, program: $0.program, display: $0.display) }
}
