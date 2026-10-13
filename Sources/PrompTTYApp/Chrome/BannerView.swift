import SwiftUI

/// Non-modal message above the panes: settings problems or a short-lived notice.
///
/// One row where it fits; where it does not (a narrow pane), the message wraps above the buttons,
/// and the buttons stack when even one row of them is too wide, so nothing is cut short.
struct BannerView: View {
    let content: BannerContent

    var body: some View {
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
        }
        if let title = content.actionTitle, let action = content.action {
            Button(title, action: action)
                .controlSize(.small)
        }
    }
}
