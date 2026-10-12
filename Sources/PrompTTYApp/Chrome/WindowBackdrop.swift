import AppKit
import SwiftUI

/// The window's background, Dia-style: the desktop blurred behind the window, under a dark (or
/// light) tint so the chrome reads as near-solid while the wallpaper's color still shows through.
/// Reduce Transparency makes the blur solid on its own.
struct WindowBackdrop: View {
    /// The tint over the blur, alpha included.
    let tint: NSColor

    var body: some View {
        ZStack {
            BehindWindowBlur()
            Color(nsColor: tint)
        }
    }
}

private struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
