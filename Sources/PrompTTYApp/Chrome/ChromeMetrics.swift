import CoreGraphics

/// Layout constants shared by the SwiftUI chrome and the window controller's sizing code.
enum ChromeMetrics {
    /// Window edge to the pane cards.
    static let inset: CGFloat = 8
    /// Height of the band that holds the traffic lights (unified titlebar).
    static let titlebarHeight: CGFloat = 52
    /// Width reserved for the traffic lights from the window's leading edge.
    static let trafficLightsWidth: CGFloat = 84
    /// The strip at the window's left edge that peeks the collapsed sidebar in.
    static let peekEdgeWidth: CGFloat = 6

    /// Each pane is its own rounded card.
    static let paneCornerRadius: CGFloat = 10
    /// The gap between pane cards (window background shows through); also the divider's hit area.
    static let paneGap: CGFloat = 8

    /// Sidebar rows (Dia-sized): "+ New Tab".
    static let rowHeight: CGFloat = 30
    /// Sidebar tab rows: one line, as Rex's (the Activity's rows have two).
    static let tabRowHeight: CGFloat = 32
    static let rowCornerRadius: CGFloat = 8
    static let sidebarHorizontalPadding: CGFloat = 8
}
