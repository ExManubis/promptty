import AppKit
import PaneActivity
import SwiftUI

/// A program's logo in its brand color, or the terminal symbol for a shell or an unknown program.
struct ProgramIcon: View {
    let program: Program?
    var size: CGFloat = 14
    /// Shown when no program is recognised.
    var fallbackSymbol = "terminal"
    /// The logo's color, in place of the brand's (on a brand-colored tile).
    var tint: Color?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let program, let logo = program.logo, program.fullColorLogo {
            // In its own colors, whatever the tile.
            Image("logo-\(logo)")
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .accessibilityLabel(program.name)
        } else if let program, let logo = program.logo {
            Image("logo-\(logo)")
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

/// A pane's or tab's activity as a dot: green while something runs, blue for what finished
/// unseen, red for what failed, a pulsing orange when a program wants the user.
struct ActivityIndicator: View {
    let display: PaneActivity.Display

    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch display {
            case .idle:
                Color.clear
            case .attention:
                Circle().fill(ProgramStack.color(for: display)).frame(width: 7, height: 7)
                    .scaleEffect(pulse ? 1.15 : 0.85)
            case .working:
                // Breathes while the agent works.
                Circle().fill(ProgramStack.color(for: display)).frame(width: 7, height: 7)
                    .opacity(pulse ? 0.35 : 1)
            default:
                Circle().fill(ProgramStack.color(for: display)).frame(width: 7, height: 7)
            }
        }
        .frame(width: 9, height: 9)
        .onAppear(perform: startPulse)
        .onChange(of: display) { _, _ in startPulse() }
        .accessibilityElement()
        .accessibilityLabel(Self.label(for: display))
        .accessibilityHidden(display == .idle)
    }

    private func startPulse() {
        pulse = false
        guard !reduceMotion, display == .attention || display == .working else { return }
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
    }

    static func label(for display: PaneActivity.Display) -> String {
        switch display {
        case .idle: ""
        case .running: "Running"
        case .working: "Working"
        case .finished: "Finished"
        case .failed(let code): "Failed with exit code \(code)"
        case .attention: "Needs attention"
        }
    }
}

/// A tab's panes as a stack of tiles, like Rex's: the focused pane's logo on a light card in
/// front, tilted a little, the other panes' cards peeking out behind it, each edge in the color of
/// its activity. A tab with one pane is one tile.
struct ProgramStack: View {
    struct Card: Identifiable {
        let id: AnyHashable
        let program: Program?
        let display: PaneActivity.Display
    }

    /// The focused pane first, then the others in order.
    let cards: [Card]

    static let width: CGFloat = 18
    static let height: CGFloat = 15
    /// How far each card behind shows past the one in front: enough for its logo.
    static let step: CGFloat = 8
    static let maxCards = 3
    /// The front card's tilt; each card behind turns a little less.
    static let tilt: Double = -5

    var body: some View {
        let shown = Array(cards.prefix(Self.maxCards))
        ZStack(alignment: .leading) {
            ForEach(Array(shown.enumerated().reversed()), id: \.element.id) { depth, card in
                let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
                // Every card is its program's tile; on the cards behind, the logo sits where the
                // card shows, at its right edge.
                shape.fill(Self.background(for: card.program))
                    .overlay(alignment: depth == 0 ? .center : .trailing) {
                        logo(of: card.program, size: depth == 0 ? 11 : 9)
                            .padding(.trailing, depth == 0 ? 0 : 1.5)
                    }
                    // A faint rim, so a dark tile stands out on a dark sidebar.
                    .overlay(shape.strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5).padding(0.75))
                .overlay {
                    if depth == 0, card.display == .working { WorkingShimmer(shape: shape) }
                }
                .overlay(shape.strokeBorder(.black.opacity(0.55), lineWidth: 1))
                .frame(width: Self.width, height: Self.height)
                .rotationEffect(.degrees(Self.tilt + Double(depth) * 2.5))
                // Each card shades the one behind it.
                .shadow(color: .black.opacity(0.3), radius: 1, x: 0.5)
                .offset(x: CGFloat(depth) * Self.step)
            }
        }
        .frame(width: Self.width + CGFloat(max(shown.count - 1, 0)) * Self.step + 2, height: Self.height + 3, alignment: .leading)
        .accessibilityElement()
        .accessibilityLabel(Self.label(for: shown))
    }

    @ViewBuilder
    private func logo(of program: Program?, size: CGFloat) -> some View {
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
    static let darkTile = Color(red: 0.13, green: 0.13, blue: 0.145)

    static func background(for program: Program?) -> Color {
        program?.tile.map { color($0.background) } ?? darkTile
    }

    static func color(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    static func color(for display: PaneActivity.Display) -> Color {
        switch display {
        case .idle: Color(white: 0.55)
        case .running, .working: .green
        case .finished: .blue
        case .failed: .red
        case .attention: .orange
        }
    }

    private static func label(for cards: [Card]) -> String {
        let names = cards.map { $0.program?.name ?? "Terminal" }
        return cards.count == 1 ? names[0] : "\(cards.count) panes: " + names.joined(separator: ", ")
    }
}

/// A soft green light sweeping across an agent's tile while it works; a still green rim when
/// motion is reduced.
private struct WorkingShimmer: View {
    let shape: RoundedRectangle
    @State private var phase: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            shape.strokeBorder(Color.green, lineWidth: 1.5)
        } else {
            GeometryReader { proxy in
                LinearGradient(colors: [.clear, Color.green.opacity(0.45), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: proxy.size.width * 0.7)
                    .offset(x: phase * proxy.size.width)
            }
            .clipShape(shape)
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { phase = 1.2 }
            }
        }
    }
}
