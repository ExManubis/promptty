import CoreGraphics

/// Layout constants shared by the SwiftUI chrome and the window controller's sizing code.
enum ChromeMetrics {
    /// Window edge to the content panel.
    static let inset: CGFloat = 8
    /// Height of the band that holds the traffic lights (unified titlebar).
    static let titlebarHeight: CGFloat = 52
    /// Width reserved for the traffic lights from the window's leading edge.
    static let trafficLightsWidth: CGFloat = 84

    /// The rounded panel that holds the toolbar and the panes.
    static let panelCornerRadius: CGFloat = 10
    /// Toolbar row inside the panel; its center lines up with the traffic lights.
    static let toolbarHeight: CGFloat = 36
    /// Panes sit this far inside the panel so their clipped corners stay within its curve.
    static let paneInset: CGFloat = 2
    static let paneCornerRadius: CGFloat = 8
    /// Between split panes: the divider's hit area, with a hairline drawn in the middle.
    static let paneGap: CGFloat = 7

    /// Sidebar tab rows (Dia-sized).
    static let rowHeight: CGFloat = 30
    static let rowCornerRadius: CGFloat = 8
    static let sidebarHorizontalPadding: CGFloat = 8
}
