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

    /// The brand color, unless it would vanish on this background (a black logo on a dark pane).
    private func color(for program: Program) -> Color {
        guard let hex = program.color else { return .primary }
        let r = Double((hex >> 16) & 0xFF) / 255, g = Double((hex >> 8) & 0xFF) / 255, b = Double(hex & 0xFF) / 255
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        if colorScheme == .dark, luminance < 0.18 { return .primary }
        if colorScheme == .light, luminance > 0.85 { return .primary }
        return Color(red: r, green: g, blue: b)
    }
}

/// Rex-style activity mark: a green bar while something runs, a dot for what finished or failed
/// unseen, an orange pulse when a program wants the user.
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
                Capsule().fill(Color.green).frame(width: 3, height: 12)
                    .opacity(pulse ? 0.45 : 1)
            case .finished:
                Circle().fill(Color.blue).frame(width: 6, height: 6)
            case .failed:
                Circle().fill(Color.red).frame(width: 6, height: 6)
            case .attention:
                Circle().fill(Color.orange).frame(width: 7, height: 7)
                    .scaleEffect(pulse ? 1.25 : 1)
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
        guard !reduceMotion, display == .running || display == .attention else { return }
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
