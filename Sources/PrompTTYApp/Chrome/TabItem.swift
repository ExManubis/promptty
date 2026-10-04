import AppKit
import WorkspaceModel

@MainActor
protocol TabItemDelegate: AnyObject {
    func tabItemDidRequestClose(_ item: TabItem)
    func tabItem(_ item: TabItem, didRename title: String)
    /// Rename finished (committed or cancelled); the field has given up focus.
    func tabItemDidEndRenaming(_ item: TabItem)
}

/// One tab row. In sidebar mode it shows title and directory; in strip mode only the title.
final class TabItem: NSCollectionViewItem, NSTextFieldDelegate {
    static let identifier = NSUserInterfaceItemIdentifier("TabItem")

    weak var delegate: TabItemDelegate?
    private(set) var tabID: TabID?

    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")
    private let closeButton = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")!, target: nil, action: nil)
    private var compact = false
    /// True between a double-click and Enter/Escape; guards against end-editing after a cancel.
    private var renaming = false

    override func loadView() {
        let root = HoverView()
        root.wantsLayer = true
        root.layer?.cornerRadius = 7
        root.layer?.cornerCurve = .continuous
        root.onHover = { [weak self] hovering in self?.closeButton.isHidden = !hovering }
        view = root

        titleField.font = .systemFont(ofSize: 12, weight: .medium)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.isEditable = false
        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.delegate = self
        subtitleField.font = .systemFont(ofSize: 10.5)
        subtitleField.textColor = .secondaryLabelColor
        subtitleField.lineBreakMode = .byTruncatingMiddle

        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.isHidden = true
        closeButton.setContentHuggingPriority(.required, for: .horizontal)

        let labels = NSStackView(views: [titleField, subtitleField])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        let row = NSStackView(views: [labels, closeButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 5, left: 9, bottom: 5, right: 7)
        row.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            row.topAnchor.constraint(equalTo: view.topAnchor),
            row.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(beginRename))
        doubleClick.numberOfClicksRequired = 2
        view.addGestureRecognizer(doubleClick)
    }

    func configure(tab: Tab, compact: Bool, selected: Bool) {
        tabID = tab.id
        self.compact = compact
        titleField.stringValue = tab.displayTitle
        subtitleField.stringValue = tab.abbreviatedDirectory
        subtitleField.isHidden = compact
        isSelected = selected
        applySelection()
    }

    override var isSelected: Bool {
        didSet { applySelection() }
    }

    private func applySelection() {
        view.layer?.backgroundColor = isSelected
            ? NSColor.white.withAlphaComponent(0.55).cgColor
            : NSColor.clear.cgColor
    }

    @objc private func closeTapped() { delegate?.tabItemDidRequestClose(self) }

    @objc private func beginRename() {
        renaming = true
        titleField.isEditable = true
        titleField.isBordered = true
        titleField.drawsBackground = true
        view.window?.makeFirstResponder(titleField)
        titleField.currentEditor()?.selectAll(nil)
    }

    private func endRenameAppearance() {
        titleField.isEditable = false
        titleField.isBordered = false
        titleField.drawsBackground = false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard renaming else { return }
        renaming = false
        endRenameAppearance()
        delegate?.tabItem(self, didRename: titleField.stringValue)
        delegate?.tabItemDidEndRenaming(self)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            renaming = false
            titleField.abortEditing()
            endRenameAppearance()
            delegate?.tabItemDidEndRenaming(self)
            return true
        }
        return false
    }
}

/// The trailing "+" item.
final class NewTabItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("NewTabItem")
    var onTap: (() -> Void)?

    override func loadView() {
        let button = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "New tab")!, target: self, action: #selector(tapped))
        button.isBordered = false
        button.imagePosition = .imageOnly
        view = button
    }

    @objc private func tapped() { onTap?() }
}

/// Reports mouse enter/exit so rows can reveal their close button.
final class HoverView: NSView {
    var onHover: ((Bool) -> Void)?
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(a)
        area = a
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}
