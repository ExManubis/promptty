import AppKit
import WorkspaceModel

/// Tinted frame hosting the tab list (sidebar or strip), an optional banner, and the terminal card.
@MainActor
final class ChromeView: NSView {
    static let sidebarWidth: CGFloat = 220
    static let stripHeight: CGFloat = 36
    /// Space reserved for the system traffic lights, which sit over our content.
    static let trafficLightsHeight: CGFloat = 38
    static let trafficLightsWidth: CGFloat = 78

    let container = TerminalContainerView(frame: .zero)
    private var tabList: NSView?
    private var banner: NSView?
    private var layoutConstraints: [NSLayoutConstraint] = []
    private var layoutMode: TabLayout = .sidebar

    var tint: NSColor = ChromeTint.fallback {
        didSet { layer?.backgroundColor = tint.cgColor }
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 1000, height: 650))
        wantsLayer = true
        layer?.backgroundColor = tint.cgColor
        container.translatesAutoresizingMaskIntoConstraints = false
        addSubview(container)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Pass `nil` to hide the tab list entirely (⌘B); the terminal card then fills the window.
    func install(tabList view: NSView?, layout: TabLayout) {
        tabList?.removeFromSuperview()
        tabList = view
        if let view {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        layoutMode = layout
        relayout()
    }

    func setBanner(_ view: NSView?) {
        banner?.removeFromSuperview()
        banner = view
        if let view {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        relayout()
    }

    private func relayout() {
        NSLayoutConstraint.deactivate(layoutConstraints)
        layoutConstraints.removeAll()
        let inset = TerminalContainerView.inset
        var c: [NSLayoutConstraint] = []
        // With the tab list hidden (and no banner above it) the card starts below the traffic lights, not under them.
        let cardTop = tabList == nil && banner == nil ? Self.trafficLightsHeight : inset

        // The vertical stack on the terminal side: [banner?] then container.
        let topAnchorForContent: NSLayoutYAxisAnchor
        if let banner {
            c += [
                banner.heightAnchor.constraint(equalToConstant: 32),
            ]
            topAnchorForContent = banner.bottomAnchor
        } else {
            topAnchorForContent = topAnchor
        }

        switch layoutMode {
        case .sidebar:
            if let tabList {
                c += [
                    tabList.leadingAnchor.constraint(equalTo: leadingAnchor),
                    tabList.topAnchor.constraint(equalTo: topAnchor, constant: Self.trafficLightsHeight),
                    tabList.bottomAnchor.constraint(equalTo: bottomAnchor),
                    tabList.widthAnchor.constraint(equalToConstant: Self.sidebarWidth),
                ]
            }
            let leading = tabList?.trailingAnchor ?? leadingAnchor
            if let banner {
                c += [
                    banner.leadingAnchor.constraint(equalTo: leading, constant: tabList == nil ? inset : 0),
                    banner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
                    // With the tab list hidden, keep the banner clear of the traffic lights.
                    banner.topAnchor.constraint(equalTo: topAnchor, constant: tabList == nil ? Self.trafficLightsHeight : inset),
                ]
            }
            c += [
                container.leadingAnchor.constraint(equalTo: leading, constant: tabList == nil ? inset : 0),
                container.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
                container.topAnchor.constraint(equalTo: topAnchorForContent, constant: cardTop),
                container.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
            ]
        case .strip:
            if let tabList {
                c += [
                    tabList.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.trafficLightsWidth),
                    tabList.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
                    tabList.topAnchor.constraint(equalTo: topAnchor, constant: 6),
                    tabList.heightAnchor.constraint(equalToConstant: Self.stripHeight),
                ]
            }
            let top = tabList?.bottomAnchor ?? topAnchor
            if let banner {
                c += [
                    banner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
                    banner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
                    banner.topAnchor.constraint(equalTo: top, constant: inset),
                ]
            }
            c += [
                container.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
                container.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
                container.topAnchor.constraint(
                    equalTo: banner == nil ? top : topAnchorForContent,
                    constant: cardTop
                ),
                container.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
            ]
        }
        layoutConstraints = c
        NSLayoutConstraint.activate(c)
    }
}
