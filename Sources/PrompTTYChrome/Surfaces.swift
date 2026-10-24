import Foundation
import SwiftUI

/// The row states: a Liquid Glass pill when selected, like the input box; a faint fill on hover.
public struct RowBackground: View {
    let selected: Bool
    let hovering: Bool
    var dropTarget: Bool
    /// Tiles show their shape at rest too, like Dia's pinned tabs.
    var resting: Bool
    /// The Mac's sidebar rows are 8; the iPhone's, larger, round more.
    var cornerRadius: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    public init(selected: Bool, hovering: Bool, dropTarget: Bool = false, resting: Bool = false, cornerRadius: CGFloat = 8) {
        self.selected = selected
        self.hovering = hovering
        self.dropTarget = dropTarget
        self.resting = resting
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if dropTarget {
            shape.fill(Color.accentColor.opacity(0.22))
                .overlay(shape.strokeBorder(Color.accentColor.opacity(0.9), lineWidth: 1.5))
        } else if selected {
            Color.clear.glassEffect(.regular, in: shape)
        } else if hovering {
            shape.fill(Color.primary.opacity(colorScheme == .dark ? (resting ? 0.1 : 0.06) : (resting ? 0.09 : 0.05)))
        } else if resting {
            shape.fill(Color.primary.opacity(colorScheme == .dark ? 0.05 : 0.045))
        }
    }
}

/// A flat raised surface (Dia's popovers and bars): solid fill, hairline border, soft shadow.
public struct FlatSurface: View {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    public init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape
            .fill(colorScheme == .dark ? Color(white: 0.17) : Color.white)
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.10), radius: 4, y: 1)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
    }
}

/// A small borderless icon button (a block's copy buttons).
public struct HeaderButton: View {
    let symbol: String
    let help: String
    var size: CGFloat
    let action: () -> Void

    public init(symbol: String, help: String, size: CGFloat = 22, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.size = size
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size / 2, weight: .medium))
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A header item that opens a picker: its text in the theme's color, in a hairline outline that
/// fills in under the pointer and while its picker is open.
public struct HeaderChipStyle: ButtonStyle {
    let open: Bool
    let color: Color

    public init(open: Bool, color: Color) {
        self.open = open
        self.color = color
    }

    public func makeBody(configuration: Configuration) -> some View {
        HeaderChip(label: configuration.label, open: open, pressed: configuration.isPressed, color: color)
    }
}

private struct HeaderChip<Content: View>: View {
    let label: Content
    let open: Bool
    let pressed: Bool
    let color: Color
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        label
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background {
                if hovering || open || pressed {
                    shape.fill(Color.primary.opacity(pressed ? 0.12 : 0.07))
                }
            }
            .overlay(shape.strokeBorder(Color.primary.opacity(0.16), lineWidth: 1))
            .opacity(enabled ? 1 : 0.6)
            .contentShape(shape)
            .onHover { hovering = $0 }
    }
}

public struct HeaderLabelStyle: LabelStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

/// A message strip above the panes. Persistent (settings/config problems) or transient.
public struct BannerContent {
    public let id = UUID()
    public var message: String
    public var actionTitle: String?
    public var action: (() -> Void)?
    public var symbol: String
    /// Further buttons, shown before the main one.
    public var extraActions: [(title: String, action: () -> Void)]

    public init(message: String, actionTitle: String? = nil, action: (() -> Void)? = nil, symbol: String = "exclamationmark.triangle.fill",
                extraActions: [(title: String, action: () -> Void)] = []) {
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
        self.symbol = symbol
        self.extraActions = extraActions
    }
}

/// Non-modal message above the panes: settings problems or a short-lived notice.
///
/// One row where it fits; where it does not (a narrow pane), the message wraps above the buttons,
/// and the buttons stack when even one row of them is too wide, so nothing is cut short.
public struct BannerView: View {
    let content: BannerContent

    public init(content: BannerContent) {
        self.content = content
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                icon
                message.fixedSize()
                Spacer(minLength: 8)
                buttons
            }
            .frame(minHeight: 32)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    icon
                    message
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        Spacer(minLength: 0)
                        buttons
                    }
                    VStack(alignment: .trailing, spacing: 4) {
                        buttons
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(.vertical, 8)
        }
        .padding(.horizontal, 12)
        .background(FlatSurface(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    private var icon: some View {
        Image(systemName: content.symbol)
            .foregroundStyle(.orange)
    }

    private var message: some View {
        Text(content.message)
            .font(.system(size: 12))
    }

    @ViewBuilder private var buttons: some View {
        ForEach(Array(content.extraActions.enumerated()), id: \.offset) { _, extra in
            Button(extra.title, action: extra.action)
                .controlSize(.small)
                #if os(iOS)
                // iOS draws a plain button as bare text: bordered, as the Mac's push buttons.
                .buttonStyle(.bordered)
                #endif
        }
        if let title = content.actionTitle, let action = content.action {
            Button(title, action: action)
                .controlSize(.small)
                #if os(iOS)
                .buttonStyle(.borderedProminent)
                #endif
        }
    }
}
