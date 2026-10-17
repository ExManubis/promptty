import SwiftUI
import WorkspaceModel

/// A tab row's second line while it is connected somewhere or something in it listens: the host
/// its focused pane's ssh reaches, else its ports, each a link that opens `localhost:<port>` in
/// the browser. Reads the panes' boxes itself, so only it redraws.
struct TabPortsLine: View {
    let panes: [PaneID]
    let actions: ChromeActions

    var body: some View {
        let ports = Array(Set(panes.flatMap { actions.ports(for: $0) })).sorted()
        if let host = panes.lazy.compactMap({ actions.remoteHost(for: $0) }).first {
            Label(host, systemImage: "globe")
                .labelStyle(RemoteLabelStyle())
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help("Connected to \(host)")
        } else if !ports.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "network")
                    .font(.system(size: 9, weight: .medium))
                ForEach(ports.prefix(4), id: \.self) { port in
                    Button(":\(String(port))") { actions.openPort(port) }
                        .buttonStyle(.plain)
                        .underline(false)
                        .help("Open localhost:\(String(port))")
                        .accessibilityLabel("Open localhost port \(String(port))")
                        .onHover { inside in
                            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                        }
                }
                if ports.count > 4 { Text("+\(ports.count - 4)") }
            }
            .font(.system(size: 10.5).monospacedDigit())
            .foregroundStyle(Color.accentColor)
            .lineLimit(1)
        }
    }
}

private struct RemoteLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 9, weight: .medium))
            configuration.title
        }
    }
}
