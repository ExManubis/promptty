import CoreGraphics

/// Layout constants shared by the SwiftUI chrome and the window controller's sizing code.
enum ChromeMetrics {
    /// Window edge to floating panels and cards.
    static let inset: CGFloat = 8
    /// Between the sidebar panel and the pane area.
    static let sidebarGap: CGFloat = 8
    /// Height of the band that holds the traffic lights (unified titlebar).
    static let titlebarHeight: CGFloat = 52
    /// Width reserved for the traffic lights from the window's leading edge.
    static let trafficLightsWidth: CGFloat = 84
    /// Gap between split pane cards; also the divider's hit area.
    static let paneGap: CGFloat = 6
    static let paneCornerRadius: CGFloat = 12
    static let sidebarCornerRadius: CGFloat = 18
    static let bannerHeight: CGFloat = 34
}
