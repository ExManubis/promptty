import Preferences
import SwiftUI

/// The Mac's chrome metrics, scaled for touch: about 1.33 times the sidebar's.
enum PhoneMetrics {
    /// `ProgramStack`'s 18×15 tiles drawn 24×20.
    static let tileScale: CGFloat = 1.33
    static let rowHeight: CGFloat = 44
    static let rowCornerRadius: CGFloat = 11
    static let paneCornerRadius: CGFloat = 20
    /// Screen edge to the pane cards, as the Mac's window inset.
    static let inset: CGFloat = 8
    static let control: CGFloat = 48
}

extension Color {
    init(_ rgb: RGB) {
        self.init(red: Double(rgb.r) / 255, green: Double(rgb.g) / 255, blue: Double(rgb.b) / 255)
    }
}

extension ThemeSwatch {
    func color(_ index: Int?) -> Color {
        guard let index, let rgb = palette[index] else { return Color(foreground) }
        return Color(rgb)
    }
}

/// The window's backdrop: the Mac's blurred desktop is a dark, quiet ground here, with a little
/// light at two corners for the glass to catch.
struct Backdrop: View {
    var body: some View {
        ZStack {
            Color(red: 0.10, green: 0.10, blue: 0.11)
            RadialGradient(colors: [Color(red: 0.33, green: 0.41, blue: 0.59).opacity(0.26), .clear],
                           center: .topTrailing, startRadius: 0, endRadius: 520)
            RadialGradient(colors: [Color(red: 0.59, green: 0.43, blue: 0.35).opacity(0.16), .clear],
                           center: .bottomLeading, startRadius: 0, endRadius: 480)
        }
        .ignoresSafeArea()
    }
}

/// The Mac's dark panes and strip track: smoked glass, a thin black layer under `.clear` glass
/// tinted a little toward the theme (`PaneCard.smoke`, `PaneCard.glassTint` and `SmokedGlass` on
/// the Mac), and Rex's lit edges.
struct SmokedGlass<S: InsettableShape>: ViewModifier {
    let shape: S
    let panel: Color
    var edges = false

    func body(content: Content) -> some View {
        content
            .background(shape.fill(Color.black.opacity(0.35)))
            .glassEffect(.clear.tint(panel.opacity(0.16)), in: shape)
            .overlay {
                if edges {
                    shape.strokeBorder(LinearGradient(stops: [.init(color: .white.opacity(0.24), location: 0),
                                                              .init(color: .white.opacity(0.05), location: 0.06),
                                                              .init(color: .white.opacity(0.05), location: 0.94),
                                                              .init(color: .white.opacity(0.12), location: 1)],
                                                      startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
                        .allowsHitTesting(false)
                }
            }
    }
}

extension View {
    func smokedGlass<S: InsettableShape>(_ shape: S, panel: Color, edges: Bool = false) -> some View {
        modifier(SmokedGlass(shape: shape, panel: panel, edges: edges))
    }

    /// A round or capsule control in Liquid Glass that responds to touch, as the system's toolbars.
    /// A group of buttons gets glass that does not: interactive glass would take their touches.
    func glassControl<S: Shape>(_ shape: S, interactive: Bool = true) -> some View {
        glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
    }
}
