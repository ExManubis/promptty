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
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: ChromeMetrics.bannerHeight)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .combine)
    }
}
