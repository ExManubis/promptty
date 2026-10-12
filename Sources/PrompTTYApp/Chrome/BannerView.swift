import AppKit

/// Non-modal message strip above the terminal card.
@MainActor
final class BannerView: NSView {
    private var handler: ClosureTarget?

    init(message: String, actionTitle: String?, action: (() -> Void)?) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.25).cgColor

        let label = NSTextField(wrappingLabelWithString: message)
        label.font = .systemFont(ofSize: 12)
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        var views: [NSView] = [label, NSView()]
        if let actionTitle, let action {
            let button = NSButton(title: actionTitle, target: nil, action: nil)
            button.bezelStyle = .inline
            button.controlSize = .small
            let target = ClosureTarget(action)
            button.target = target
            button.action = #selector(ClosureTarget.fire)
            handler = target
            views.append(button)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}
