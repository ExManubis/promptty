import PaneActivity
import SwiftUI
import WorkspaceModel

/// The SF Symbols a pinned tab's icon can be, grouped as the picker shows them.
enum PinIconChoices {
    static let groups: [(title: String, symbols: [String])] = [
        ("Code", ["terminal", "chevron.left.forwardslash.chevron.right", "curlybraces", "function", "hammer",
                  "wrench.and.screwdriver", "ladybug", "ant", "testtube.2", "checkmark.seal", "shippingbox", "gearshape"]),
        ("Servers & Data", ["server.rack", "cpu", "memorychip", "externaldrive", "cylinder.split.1x2", "network",
                            "globe", "cloud", "antenna.radiowaves.left.and.right", "lock.shield", "key", "chart.bar"]),
        ("Agents", ["sparkles", "brain", "wand.and.stars", "bubble.left.and.bubble.right", "lightbulb", "atom"]),
        ("Other", ["house", "folder", "doc.text", "book", "flag", "star", "heart", "bolt", "flame", "leaf",
                   "music.note", "gamecontroller", "cup.and.saucer", "moon", "sun.max", "bell", "paperplane", "eye", "scope"]),
    ]

    /// A tile's fill, and the symbol's color on it.
    static func colors(for color: PinIcon.Color) -> (background: Color, foreground: Color) {
        switch color {
        case .dark: (ProgramStack.darkTile, Color(white: 0.9))
        case .red: (ProgramStack.color(0xE5484D), .white)
        case .orange: (ProgramStack.color(0xF76B15), .white)
        case .yellow: (ProgramStack.color(0xFFC53D), .black)
        case .green: (ProgramStack.color(0x30A46C), .white)
        case .teal: (ProgramStack.color(0x12A594), .white)
        case .blue: (ProgramStack.color(0x0090FF), .white)
        case .purple: (ProgramStack.color(0x8E4EC6), .white)
        }
    }
}

/// A pinned tab's own icon, drawn like the front card of its programs' stack: a tilted tile.
struct PinIconTile: View {
    let icon: PinIcon

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 4, style: .continuous) }

    var body: some View {
        card
            .frame(width: ProgramStack.width, height: ProgramStack.height)
            .rotationEffect(.degrees(ProgramStack.tilt))
            .shadow(color: .black.opacity(0.3), radius: 1, x: 0.5)
            .frame(width: ProgramStack.width + 2, height: ProgramStack.height + 3)
            .accessibilityHidden(true)
    }

    private var card: some View {
        let colors = PinIconChoices.colors(for: icon.color)
        return shape.fill(colors.background)
            .overlay {
                Image(systemName: icon.symbol)
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(colors.foreground)
            }
            // The same rims as the logo tiles.
            .overlay(shape.strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5).padding(0.75))
            .overlay(shape.strokeBorder(Color.black.opacity(0.55), lineWidth: 1))
    }
}

/// "Change Icon…": the symbols, the tile colors, and the way back to the programs' logos. Stays
/// open while the user tries icons; a click outside or Esc closes it.
struct PinIconPicker: View {
    let current: PinIcon?
    let choose: (PinIcon?) -> Void

    private let columns = Array(repeating: GridItem(.fixed(28), spacing: 4), count: 8)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Icon")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Default") { choose(nil) }
                    .controlSize(.small)
                    .disabled(current == nil)
                    .help("Show the tab's programs' logos")
            }
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(PinIconChoices.groups, id: \.title) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.title)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
                                ForEach(group.symbols, id: \.self) { symbol in
                                    symbolButton(symbol)
                                }
                            }
                        }
                    }
                }
            }
            .frame(height: 330)
            Divider()
            HStack(spacing: 6) {
                ForEach(PinIcon.Color.allCases, id: \.self) { color in
                    colorButton(color)
                }
            }
        }
        .padding(12)
        .frame(width: 274)
    }

    private func symbolButton(_ symbol: String) -> some View {
        let selected = current?.symbol == symbol
        return Button {
            choose(PinIcon(symbol: symbol, color: current?.color ?? .dark))
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 28, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(selected ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.0001))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(symbol)
        .accessibilityLabel(symbol.replacingOccurrences(of: ".", with: " "))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Choosing a color before a symbol gives the tile the terminal symbol.
    private func colorButton(_ color: PinIcon.Color) -> some View {
        let selected = current?.color == color
        let fill = PinIconChoices.colors(for: color).background
        return Button {
            choose(PinIcon(symbol: current?.symbol ?? "terminal", color: color))
        } label: {
            Circle()
                .fill(fill)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
                .frame(width: 20, height: 20)
                .padding(3)
                .overlay(Circle().strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(color.rawValue.capitalized)
        .accessibilityLabel(color.rawValue.capitalized)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
