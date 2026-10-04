import AppKit
import GhosttyBridge

/// The rounded card that holds the selected tab's surface. Keeps every tab's surface alive
/// (hidden and occluded) so switching tabs is instant.
@MainActor
final class TerminalContainerView: NSView {
    static let inset: CGFloat = 8
    static let cornerRadius: CGFloat = 10

    private var overlays: [ObjectIdentifier: NSView] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ view: TerminalSurfaceView) {
        if view.superview !== self {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
        for sub in subviews {
            guard let surface = sub as? TerminalSurfaceView else { continue }
            let selected = surface === view
            surface.isHidden = !selected
            surface.setOccluded(!selected)
        }
        overlays.values.forEach { $0.isHidden = true }
        overlays[ObjectIdentifier(view)]?.isHidden = false
        window?.makeFirstResponder(view)
    }

    func remove(_ view: TerminalSurfaceView) {
        overlays.removeValue(forKey: ObjectIdentifier(view))?.removeFromSuperview()
        view.removeFromSuperview()
    }

    func showExitedOverlay(for view: TerminalSurfaceView, exitCode: UInt32, onClose: @escaping () -> Void) {
        let key = ObjectIdentifier(view)
        overlays[key]?.removeFromSuperview()
        let overlay = ExitedOverlayView(exitCode: exitCode, onClose: onClose)
        overlay.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 44)
        overlay.autoresizingMask = [.width, .maxYMargin]
        overlay.isHidden = view.isHidden
        addSubview(overlay)
        overlays[key] = overlay
    }
}

private final class ExitedOverlayView: NSView {
    init(exitCode: UInt32, onClose: @escaping () -> Void) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        let label = NSTextField(labelWithString: exitCode == 0 ? "Process exited" : "Process exited with code \(exitCode)")
        label.textColor = .white
        label.font = .systemFont(ofSize: 12, weight: .medium)
        let button = NSButton(title: "Close tab", target: nil, action: nil)
        button.bezelStyle = .rounded
        button.controlSize = .small
        let handler = ClosureTarget(onClose)
        button.target = handler
        button.action = #selector(ClosureTarget.fire)
        self.handler = handler
        let stack = NSStackView(views: [label, NSView(), button])
        stack.orientation = .horizontal
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    private var handler: ClosureTarget?
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

/// Lets a plain closure be an AppKit target/action.
final class ClosureTarget: NSObject {
    private let body: () -> Void
    init(_ body: @escaping () -> Void) { self.body = body }
    @objc func fire() { body() }
}
