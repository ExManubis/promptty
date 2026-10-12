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

/// Rex-style activity mark: a green bar while something runs, a blue dot for what finished
/// unseen, a red diamond for what failed, an orange pulse when a program wants the user.
struct ActivityIndicator: View {
    let display: PaneActivity.Display

    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch display {
            case .idle:
                Color.clear
            case .running:
                // Still: agents and editors run all day, and a pulse would never rest.
                Capsule().fill(Color.green).frame(width: 3, height: 12)
            case .finished:
                Circle().fill(Color.blue).frame(width: 6, height: 6)
            case .failed:
                // Not only red: a different shape for those who cannot tell the colors apart.
                Rectangle().fill(Color.red).frame(width: 5.5, height: 5.5).rotationEffect(.degrees(45))
            case .attention:
                Circle().fill(Color.orange).frame(width: 6, height: 6)
                    .scaleEffect(pulse ? 1.2 : 0.9)
            }
        }
        .frame(width: 7, height: 12)
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

/// A split tab's panes as a stack of tiles, like Rex's: the focused pane's logo on a light card in
/// front, the other panes' cards peeking out behind it, each edge in the color of its activity.
struct ProgramStack: View {
    struct Card: Identifiable {
        let id: AnyHashable
        let program: Program?
        let display: PaneActivity.Display
    }

    /// The focused pane first, then the others in order.
    let cards: [Card]
    var fallbackSymbol = "terminal"

    static let tile: CGFloat = 16
    /// How far each card behind shows past the one in front.
    static let step: CGFloat = 4
    static let maxCards = 3

    var body: some View {
        let shown = Array(cards.prefix(Self.maxCards))
        ZStack(alignment: .leading) {
            ForEach(Array(shown.enumerated().reversed()), id: \.element.id) { depth, card in
                if depth == 0 {
                    front(card)
                } else {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Self.color(for: card.display))
                        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.black.opacity(0.25), lineWidth: 0.5))
                        .frame(width: Self.tile, height: Self.tile - CGFloat(depth) * 1.5)
                        .offset(x: CGFloat(depth) * Self.step)
                }
            }
        }
        .frame(width: Self.tile + CGFloat(max(shown.count - 1, 0)) * Self.step, height: Self.tile, alignment: .leading)
        .accessibilityElement()
        .accessibilityLabel(Self.label(for: shown))
    }

    private func front(_ card: Card) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Color(white: 0.96))
            .shadow(color: .black.opacity(0.3), radius: 1, x: 0.5)
            .overlay {
                // The logo as on a light background, whatever the window's appearance.
                ProgramIcon(program: card.program, size: 11, fallbackSymbol: fallbackSymbol)
                    .environment(\.colorScheme, .light)
            }
            .frame(width: Self.tile, height: Self.tile)
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
        return "\(cards.count) panes: " + names.joined(separator: ", ")
    }
}
