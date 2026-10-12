import AppKit
import PaneActivity
import SwiftUI

/// A program's logo in its brand color, or the terminal symbol for a shell or an unknown program.
struct ProgramIcon: View {
    let program: Program?
    var size: CGFloat = 14
    /// Shown when no program is recognised.
    var fallbackSymbol = "terminal"

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let program, let logo = program.logo {
            Image("logo-\(logo)")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .foregroundStyle(color(for: program))
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
        guard !reduceMotion, display == .attention else { return }
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
    }

    static func label(for display: PaneActivity.Display) -> String {
        switch display {
        case .idle: ""
        case .running: "Running"
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
    /// How far each card behind shows past the one in front.
    static let step: CGFloat = 4
    static let maxCards = 3
    /// The front card's tilt; each card behind turns a little less.
    static let tilt: Double = -5

    var body: some View {
        let shown = Array(cards.prefix(Self.maxCards))
        ZStack(alignment: .leading) {
            ForEach(Array(shown.enumerated().reversed()), id: \.element.id) { depth, card in
                let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
                Group {
                    if depth == 0 {
                        shape.fill(Color(white: 0.96))
                            .overlay {
                                if card.program?.logo != nil {
                                    // The logo as on a light background, whatever the window's appearance.
                                    ProgramIcon(program: card.program, size: 11)
                                        .environment(\.colorScheme, .light)
                                } else {
                                    // A shell or an unknown program: the prompt itself, as Rex shows it.
                                    Text(">_")
                                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                                        .foregroundStyle(Color(white: 0.25))
                                        .accessibilityHidden(true)
                                }
                            }
                    } else {
                        shape.fill(Self.color(for: card.display))
                    }
                }
                .overlay(shape.strokeBorder(.black.opacity(0.55), lineWidth: 1))
                .frame(width: Self.width, height: Self.height)
                .rotationEffect(.degrees(Self.tilt + Double(depth) * 2.5))
                .shadow(color: .black.opacity(depth == 0 ? 0.25 : 0), radius: 1, x: 0.5)
                .offset(x: CGFloat(depth) * Self.step)
            }
        }
        .frame(width: Self.width + CGFloat(max(shown.count - 1, 0)) * Self.step + 2, height: Self.height + 3, alignment: .leading)
        .accessibilityElement()
        .accessibilityLabel(Self.label(for: shown))
    }

    static func color(for display: PaneActivity.Display) -> Color {
        switch display {
        case .idle: Color(white: 0.55)
        case .running: .green
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
