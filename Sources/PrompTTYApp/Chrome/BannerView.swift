import SwiftUI

/// Non-modal message above the panes: settings problems or a short-lived notice.
struct BannerView: View {
    let content: BannerContent

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(content.message)
                .font(.system(size: 12))
                .lineLimit(2)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if let title = content.actionTitle, let action = content.action {
                Button(title, action: action)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 32)
        .background(FlatSurface(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}
