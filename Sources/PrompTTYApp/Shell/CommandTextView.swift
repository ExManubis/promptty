import AppKit
import GhosttyBridge

/// The input bar's editor: a plain-text `NSTextView` in a scroll view that grows to eight lines.
/// Native macOS editing; Return runs the command, Shift-Return adds a line.
final class CommandEditorView: NSScrollView {
    let textView: CommandTextView

    init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        textView = CommandTextView(frame: .zero, textContainer: container)
        super.init(frame: .zero)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        documentView = textView
        hasVerticalScroller = false
        hasHorizontalScroller = false
        drawsBackground = false
        borderType = .noBorder
        verticalScrollElasticity = .none
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

@MainActor
final class CommandTextView: NSTextView {
    /// Runs the text as a command (Return). Empty text runs nothing but still gets a fresh prompt.
    var onSubmit: ((String) -> Void)?
    /// Raw input for the shell: ⌃D (end of input) on an empty bar, ⌃L (clear screen).
    var onShellInput: ((String) -> Void)?
    var onFocus: (() -> Void)?
    var onTextChange: (() -> Void)?
    /// The terminal next to the bar: ⌘C copies its selection when the bar has none.
    weak var terminal: TerminalSurfaceView?

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        drawsBackground = false
        textContainerInset = .zero
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        smartInsertDeleteEnabled = false
        usesFindBar = false
        allowsCharacterPickerTouchBarItem = false
        // macOS's inline predictions (grey text and their panel) would compete with the bar's own
        // history suggestions.
        inlinePredictionType = .no
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus?() }
        return ok
    }

    override func didChangeText() {
        super.didChangeText()
        onTextChange?()
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        if handleShellKey(event) { return }
        super.keyDown(with: event)
    }

    /// Return, Shift-Return and the control keys the shell gives meaning to. True when handled.
    func handleShellKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.shift, .control, .option, .command])
        if event.keyCode == 36 || event.keyCode == 76 {
            if mods == .shift {
                insertNewlineIgnoringFieldEditor(nil)
            } else if mods.isEmpty {
                let command = string
                string = ""
                onTextChange?()
                onSubmit?(command)
            } else {
                return false
            }
            return true
        }
        guard mods == .control, let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        switch key {
        case "c":
            string = ""
            onTextChange?()
        case "d":
            guard string.isEmpty else { return false }
            onShellInput?("\u{04}")
        case "l":
            onShellInput?("\u{0c}")
        case "u":
            let caret = selectedRange().location
            let lineStart = (string as NSString).lineRange(for: NSRange(location: caret, length: 0)).location
            let range = NSRange(location: lineStart, length: caret - lineStart)
            if range.length > 0, shouldChangeText(in: range, replacementString: "") {
                replaceCharacters(in: range, with: "")
                didChangeText()
            }
        default:
            return false
        }
        return true
    }

    // MARK: Copy

    @objc override func copy(_ sender: Any?) {
        if selectedRange().length == 0, let terminal, terminal.hasSelection {
            terminal.copy(sender)
        } else {
            super.copy(sender)
        }
    }

    /// The height for `lines` (clamped to 1…8) lines of the current font.
    func height(maxLines: Int = 8) -> CGFloat {
        guard let layoutManager, let textContainer, let font else { return 18 }
        layoutManager.ensureLayout(for: textContainer)
        let lineHeight = layoutManager.defaultLineHeight(for: font)
        let used = layoutManager.usedRect(for: textContainer).height
        return min(CGFloat(maxLines) * lineHeight, max(lineHeight, used.rounded(.up)))
    }
}
