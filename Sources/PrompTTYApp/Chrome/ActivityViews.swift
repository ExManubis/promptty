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
