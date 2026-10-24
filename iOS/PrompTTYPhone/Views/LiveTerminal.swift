import GhosttyMirror
import SwiftUI
import UIKit

/// A pane live from the Mac (`LiveMirror`): its terminal at the Mac's grid, zoomed out to fit the
/// card's width, pinch to zoom in, two fingers to move about; one finger scrolls its scrollback.
/// With control taken, the grid is the card's and it fits as it is.
struct LiveTerminal: View {
    let mirror: LiveMirror

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let view = mirror.view {
                    ZoomingTerminal(view: view, fit: mirror.fit ?? geometry.size, available: geometry.size)
                }
                if let failure = mirror.failure {
                    Text(failure)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                } else if mirror.state == nil {
                    ProgressView()
                }
            }
            .onAppear { mirror.available = geometry.size }
            .onChange(of: geometry.size) { _, size in mirror.available = size }
        }
    }
}

private struct ZoomingTerminal: UIViewRepresentable {
    let view: MirrorSurfaceView
    /// The terminal's size for the pane's grid.
    let fit: CGSize
    /// The card's room for it.
    let available: CGSize

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.delegate = context.coordinator
        scroll.backgroundColor = .clear
        scroll.bouncesZoom = true
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        // One finger is the terminal's (its scrollback, taps); two move the zoomed view about.
        scroll.panGestureRecognizer.minimumNumberOfTouches = 2
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.addSubview(view)
        context.coordinator.view = view
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        let coordinator = context.coordinator
        guard fit.width > 0, fit.height > 0, available.width > 0 else { return }
        let fitChanged = coordinator.fit != fit
        if fitChanged {
            coordinator.fit = fit
            scroll.zoomScale = 1
            view.frame = CGRect(origin: .zero, size: fit)
            scroll.contentSize = fit
        }
        // Zoomed out to show the grid's whole width; in up to twice the font's size.
        let fitWidth = min(1, available.width / fit.width)
        scroll.minimumZoomScale = min(fitWidth, available.height / fit.height, 1)
        scroll.maximumZoomScale = 2
        if fitChanged || coordinator.available != available {
            coordinator.available = available
            scroll.zoomScale = fitWidth
            // The bottom of the screen, where the prompt is.
            let bottom = max(0, fit.height * fitWidth - available.height)
            scroll.contentOffset = CGPoint(x: 0, y: bottom)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var view: UIView?
        var fit: CGSize = .zero
        var available: CGSize = .zero

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { view }
    }
}
