import PaneActivity
import SwiftUI

/// A program's logo in its brand color, or the terminal symbol for a shell or an unknown program.
public struct ProgramIcon: View {
    let program: Program?
    var size: CGFloat
    /// Shown when no program is recognised.
    var fallbackSymbol: String
    /// The logo's color, in place of the brand's (on a brand-colored tile).
    var tint: Color?
    /// One color even for a logo drawn in its own colors (a pane header's glyph, as Rex's).
    var monochrome: Bool

    @Environment(\.colorScheme) private var colorScheme

    public init(program: Program?, size: CGFloat = 14, fallbackSymbol: String = "terminal", tint: Color? = nil, monochrome: Bool = false) {
        self.program = program
        self.size = size
        self.fallbackSymbol = fallbackSymbol
        self.tint = tint
        self.monochrome = monochrome
    }

    public var body: some View {
        if let program, let logo = program.logo, program.fullColorLogo, !monochrome {
            // In its own colors, whatever the tile.
            Image("logo-\(logo)", bundle: .module)
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .accessibilityLabel(program.name)
        } else if let program, let logo = program.logo {
            Image("logo-\(logo)", bundle: .module)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .foregroundStyle(tint ?? color(for: program))
                .accessibilityLabel(program.name)
        } else {
            Image(systemName: fallbackSymbol)
                .font(.system(size: size * 0.92, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }

    /// The brand color, unless it would be hard to see on this background (a black logo on a
    /// dark pane): below a 2.5:1 contrast ratio the text color is used instead.
    private func color(for program: Program) -> Color {
        guard let hex = program.color else { return .primary }
        let r = Double((hex >> 16) & 0xFF) / 255, g = Double((hex >> 8) & 0xFF) / 255, b = Double(hex & 0xFF) / 255
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        // Typical dark and light pane backgrounds.
        let background = colorScheme == .dark ? 0.012 : 0.87
        let ratio = (max(luminance, background) + 0.05) / (min(luminance, background) + 0.05)
        return ratio < 2.5 ? .primary : Color(red: r, green: g, blue: b)
    }
}

/// A tab's panes as a stack of tiles, like Rex's: the focused pane's logo on a light card in
/// front, tilted a little, the other panes' cards peeking out behind it, each edge in the color of
/// its activity. A tab with one pane is one tile.
public struct ProgramStack: View {
    public struct Card: Identifiable {
        public let id: AnyHashable
        public let program: Program?
        public let display: PaneActivity.Display

        public init(id: AnyHashable, program: Program?, display: PaneActivity.Display) {
            self.id = id
            self.program = program
            self.display = display
        }
    }

    /// The focused pane first, then the others in order.
    let cards: [Card]
    /// How much larger than the Mac's sidebar the tiles are drawn (the iPhone's are larger).
    var scale: CGFloat

    public nonisolated static let width: CGFloat = 18
    public nonisolated static let height: CGFloat = 15
    /// How far each card behind shows past the one in front: enough for its logo.
    nonisolated static let step: CGFloat = 8
    nonisolated static let maxCards = 3
    /// The front card's tilt; each card behind turns a little less.
    public nonisolated static let tilt: Double = -5

    public init(cards: [Card], scale: CGFloat = 1) {
        self.cards = cards
        self.scale = scale
    }

    public var body: some View {
        let shown = Array(cards.prefix(Self.maxCards))
        ZStack(alignment: .leading) {
            ForEach(Array(shown.enumerated().reversed()), id: \.element.id) { depth, card in
                let shape = RoundedRectangle(cornerRadius: 4 * scale, style: .continuous)
                // Every card is its program's tile; on the cards behind, the logo sits where the
                // card shows, at its right edge.
                shape.fill(Self.background(for: card.program))
                    .overlay(alignment: depth == 0 ? .center : .trailing) {
                        logo(of: card.program, size: (depth == 0 ? 11 : 9) * scale)
                            .padding(.trailing, depth == 0 ? 0 : 1.5 * scale)
                    }
                    // A faint rim, so a dark tile stands out on a dark sidebar.
                    .overlay(shape.strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5).padding(0.75))
                .overlay(shape.strokeBorder(.black.opacity(0.55), lineWidth: 1))
                .frame(width: Self.width * scale, height: Self.height * scale)
                .rotationEffect(.degrees(Self.tilt + Double(depth) * 2.5))
                // Each card shades the one behind it.
                .shadow(color: .black.opacity(0.3), radius: 1, x: 0.5)
                .offset(x: CGFloat(depth) * Self.step * scale)
            }
        }
        .frame(width: (Self.width + CGFloat(max(shown.count - 1, 0)) * Self.step + 2) * scale, height: (Self.height + 3) * scale, alignment: .leading)
        .accessibilityElement()
        .accessibilityLabel(Self.label(for: shown))
    }

    @ViewBuilder
    private func logo(of program: Program?, size: CGFloat) -> some View { Self.logo(of: program, size: size) }

    /// A program's logo for its tile, or the prompt for a shell.
    @ViewBuilder
    public static func logo(of program: Program?, size: CGFloat) -> some View {
        if program?.logo != nil {
            // On a brand tile in the brand's pairing; on the dark tile in the brand's color, as on
            // a dark background.
            ProgramIcon(program: program, size: size, tint: program?.tile.map { Self.color($0.foreground) })
                .environment(\.colorScheme, .dark)
        } else {
            // A shell or an unknown program: the prompt itself, as Rex shows it.
            Text(">_")
                .font(.system(size: size * 0.73, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(white: 0.85))
                .accessibilityHidden(true)
        }
    }

    /// The default tile: dark, like a terminal.
    public nonisolated static let darkTile = Color(red: 0.13, green: 0.13, blue: 0.145)

    public nonisolated static func background(for program: Program?) -> Color {
        program?.tile.map { color($0.background) } ?? darkTile
    }

    public nonisolated static func color(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    public nonisolated static func color(for display: PaneActivity.Display) -> Color {
        switch display {
        case .idle: Color(white: 0.55)
        case .running, .working: .green
        case .finished: .blue
        case .failed: .red
        case .attention, .permission: .orange
        }
    }

    private static func label(for cards: [Card]) -> String {
        let names = cards.map { $0.program?.name ?? "Terminal" }
        return cards.count == 1 ? names[0] : "\(cards.count) panes: " + names.joined(separator: ", ")
    }
}

/// One pane's program as a flat tile (a pane header's), not tilted or stacked.
public struct ProgramTile: View {
    let program: Program?
    var width: CGFloat
    var height: CGFloat

    public init(program: Program?, width: CGFloat = 20, height: CGFloat = 16) {
        self.program = program
        self.width = width
        self.height = height
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: 4.5, style: .continuous)
        shape.fill(ProgramStack.background(for: program))
            .overlay { ProgramStack.logo(of: program, size: 11) }
            .overlay(shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5).padding(0.5))
            .overlay(shape.strokeBorder(.black.opacity(0.45), lineWidth: 0.75))
            .frame(width: width, height: height)
            .accessibilityLabel(program?.name ?? "Terminal")
    }
}

/// A tab's programs as the strip's pills show them (`ProgramStack`), with a blue dot on the front
/// tile's corner for what happened out of sight.
public struct SidebarTabIcon: View {
    let cards: [ProgramStack.Card]
    var badge: Bool
    var scale: CGFloat

    /// The width the rows' text lines up after, for the headers' symbols.
    public nonisolated static let size: CGFloat = ProgramStack.width

    public init(cards: [ProgramStack.Card], badge: Bool = false, scale: CGFloat = 1) {
        self.cards = cards
        self.badge = badge
        self.scale = scale
    }

    public var body: some View {
        ProgramStack(cards: cards, scale: scale)
            .overlay(alignment: .topLeading) {
                if badge {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 7 * scale, height: 7 * scale)
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 0.5))
                        .offset(x: (ProgramStack.width - 4.5) * scale, y: -2.5 * scale)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(minWidth: Self.size * scale, alignment: .leading)
    }
}
