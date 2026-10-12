import AppKit
import CommandEditing
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
    /// Newest first.
    var history: () -> [String] = { [] }
    var isKnownCommand: (String) -> Bool = { _ in true }

    private(set) var vi = ViEngine()
    private var navigator: HistoryNavigator?
    /// Set while history replaces the text, so that edit does not end the history walk.
    private var replacingFromHistory = false
    /// The ghost text after the caret.
    private(set) var suggestion: String?
    /// Where Tab completion looks: the shell's names and the pane's directory.
    var completionContext: () -> (sources: CompletionSources, directory: String)? = { nil }
    private let popup = CompletionPopup()
    var isShowingCompletions: Bool { popup.isVisible }

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
        if !replacingFromHistory { navigator = nil }
        recolor()
        updateSuggestion()
        onTextChange?()
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        updateSuggestion()
    }

    override func resignFirstResponder() -> Bool {
        popup.close()
        return super.resignFirstResponder()
    }

    /// The command was sent: start the next one fresh, in insert mode.
    func commandRan() {
        popup.close()
        navigator = nil
        vi.enterInsert()
        modeChanged()
    }

    func styleChanged() {
        typingAttributes = [.font: EditorStyle.font, .foregroundColor: EditorStyle.colors.text]
        applyParagraphStyle()
        insertionPointColor = EditorStyle.colors.text
        recolor()
        needsDisplay = true
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.shift, .control, .option, .command])
        if popup.isVisible {
            switch (event.keyCode, mods) {
            case (48, []), (125, []): popup.move(by: 1); return
            case (48, .shift), (126, []): popup.move(by: -1); return
            case (36, []), (76, []): acceptCompletion(); return
            case (53, []): popup.close(); return
            default:
                break
            }
        }
        if handleShellKey(event) { return }
        if event.keyCode == 48, mods.isEmpty {
            if vi.mode == .insert { complete() }
            return
        }
        switch (event.keyCode, mods) {
        case (53, []): // Escape
            applyVi(.escape)
            return
        case (124, []), (119, []): // → or End: at the end of the text they take the suggestion
            if acceptSuggestion(wordOnly: false) { return }
        case (124, .option):
            if acceptSuggestion(wordOnly: true) { return }
        case (49, .control): // ⌃Space
            if acceptSuggestion(wordOnly: false) { return }
        case (126, []) where isOnFirstLine:
            walkHistory(older: true)
            return
        case (125, []) where isOnLastLine && navigator?.isBrowsing == true:
            walkHistory(older: false)
            return
        default:
            break
        }
        // Normal mode takes every key that types something; arrows and the like keep moving the caret.
        if vi.mode == .normal, mods.isDisjoint(with: [.command, .control]),
           let chars = event.characters, chars.count == 1, let c = chars.first,
           !(c.unicodeScalars.first.map { (0xF700...0xF8FF).contains($0.value) } ?? false) {
            applyVi(.char(c))
            return
        }
        super.keyDown(with: event)
        if popup.isVisible { refilterCompletions() }
    }

    private var isOnFirstLine: Bool {
        !(string as NSString).substring(to: selectedRange().location).contains("\n")
    }

    private var isOnLastLine: Bool {
        !(string as NSString).substring(from: NSMaxRange(selectedRange())).contains("\n")
    }

    // MARK: Vi

    private func applyVi(_ key: ViKey) {
        var buffer = EditBuffer(text: string, cursor: selectedRange().location)
        let before = buffer
        let result = vi.handle(key, buffer: &buffer)
        switch result {
        case .historyOlder: walkHistory(older: true)
        case .historyNewer: walkHistory(older: false)
        case .undo: undoManager?.undo()
        case .handled, .unhandled: apply(buffer, from: before)
        }
        modeChanged()
    }

    /// Replaces only what changed, as one undoable edit, then places the caret.
    private func apply(_ buffer: EditBuffer, from before: EditBuffer) {
        if buffer.text != before.text {
            let old = Array(before.text.utf16), new = Array(buffer.text.utf16)
            var prefix = 0
            while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
            var suffix = 0
            while suffix < old.count - prefix, suffix < new.count - prefix, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
            let range = NSRange(location: prefix, length: old.count - prefix - suffix)
            let replacement = String(decoding: new[prefix..<(new.count - suffix)], as: UTF16.self)
            breakUndoCoalescing()
            if shouldChangeText(in: range, replacementString: replacement) {
                textStorage?.replaceCharacters(in: range, with: replacement)
                didChangeText()
            }
        }
        setSelectedRange(NSRange(location: min(buffer.cursor, (string as NSString).length), length: 0))
    }

    private func modeChanged() {
        updateInsertionPointStateAndRestartTimer(true)
        needsDisplay = true
    }

    // MARK: History

    private func walkHistory(older: Bool) {
        if navigator == nil { navigator = HistoryNavigator(history: history()) }
        let next = older ? navigator?.older(current: string) : navigator?.newer()
        guard let next else { return }
        replacingFromHistory = true
        defer { replacingFromHistory = false }
        let all = NSRange(location: 0, length: (string as NSString).length)
        breakUndoCoalescing()
        if shouldChangeText(in: all, replacementString: next) {
            textStorage?.replaceCharacters(in: all, with: next)
            didChangeText()
        }
        var end = (next as NSString).length
        if vi.mode == .normal, end > 0 { end -= 1 }
        setSelectedRange(NSRange(location: end, length: 0))
    }

    // MARK: Completion

    private func currentCompletion() -> Completion? {
        guard let context = completionContext(), selectedRange().length == 0 else { return nil }
        return CompletionEngine.complete(text: string, cursor: selectedRange().location, directory: context.directory,
                                         home: NSHomeDirectory(), sources: context.sources)
    }

    /// Tab: one match is inserted; several insert what they share and open the list.
    private func complete() {
        guard let completion = currentCompletion(), completion.candidates.count <= 500 else {
            NSSound.beep()
            return
        }
        let range = NSRange(location: completion.replacement.lowerBound, length: completion.replacement.count)
        if let single = completion.singleInsertion {
            insertText(single, replacementRange: range)
            return
        }
        let typed = (string as NSString).substring(with: range)
        if (completion.commonPrefix as NSString).length > (typed as NSString).length {
            insertText(completion.commonPrefix, replacementRange: range)
        }
        guard let window else { return }
        let anchor = firstRect(forCharacterRange: NSRange(location: range.location, length: 0), actualRange: nil)
        popup.show(completion.candidates, anchor: anchor, in: window, font: font ?? EditorStyle.font)
    }

    private func refilterCompletions() {
        guard let completion = currentCompletion(), completion.candidates.count <= 500 else {
            popup.close()
            return
        }
        popup.update(completion.candidates)
    }

    private func acceptCompletion() {
        defer { popup.close() }
        guard let item = popup.selectedItem, let completion = currentCompletion() else { return }
        let range = NSRange(location: completion.replacement.lowerBound, length: completion.replacement.count)
        insertText(item.hasSuffix("/") ? item : item + " ", replacementRange: range)
    }

    // MARK: Suggestions

    private func updateSuggestion() {
        let range = selectedRange()
        let atEnd = range.length == 0 && range.location == (string as NSString).length
        let next = atEnd && !hasMarkedText() ? Autosuggester.suggestion(for: string, history: history()) : nil
        if next != suggestion {
            suggestion = next
            needsDisplay = true
        }
    }

    /// Inserts the suggestion (or its first word). Only when there is one, which needs the caret at
    /// the end of the text.
    private func acceptSuggestion(wordOnly: Bool) -> Bool {
        guard let suggestion else { return false }
        let text = wordOnly ? Autosuggester.firstWord(of: suggestion) : suggestion
        let end = (string as NSString).length
        insertText(text, replacementRange: NSRange(location: end, length: 0))
        return true
    }

    // MARK: Coloring

    func recolor() {
        guard let storage = textStorage, !hasMarkedText() else { return }
        let colors = EditorStyle.colors
        let units = Array(string.utf16)
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: colors.text, range: NSRange(location: 0, length: storage.length))
        for token in CommandTokenizer.tokenize(string) {
            let color: NSColor
            switch token.kind {
            case .command:
                let word = String(decoding: units[token.range], as: UTF16.self)
                color = isKnownCommand(word.replacingOccurrences(of: "\\", with: "")) ? colors.command : colors.unknownCommand
            case .argument: continue
            case .flag: color = colors.flag
            case .string: color = colors.string
            case .variable: color = colors.variable
            case .op: color = colors.op
            case .comment: color = colors.comment
            }
            storage.addAttribute(.foregroundColor, value: color, range: NSRange(location: token.range.lowerBound, length: token.range.count))
        }
        storage.endEditing()
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let suggestion, let font, let layoutManager, let textContainer else { return }
        let length = (string as NSString).length
        var origin = textContainerOrigin
        if length > 0 {
            let glyph = layoutManager.glyphIndexForCharacter(at: length - 1)
            let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
            origin = NSPoint(x: origin.x + rect.maxX, y: origin.y + line.minY)
        }
        (suggestion as NSString).draw(at: origin, withAttributes: [.font: font, .foregroundColor: EditorStyle.colors.ghost])
    }

    /// Normal mode shows a block caret, like vi (and zsh's vi mode in Ghostty).
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        guard vi.mode == .normal else {
            super.drawInsertionPoint(in: rect, color: color, turnedOn: flag)
            return
        }
        var block = rect
        block.size.width = blockWidth
        if flag {
            color.withAlphaComponent(0.55).setFill()
            block.fill()
        } else {
            setNeedsDisplay(block, avoidAdditionalLayout: false)
        }
    }

    override func setNeedsDisplay(_ rect: NSRect, avoidAdditionalLayout flag: Bool) {
        var r = rect
        r.size.width += blockWidth
        super.setNeedsDisplay(r, avoidAdditionalLayout: flag)
    }

    private var blockWidth: CGFloat {
        (font ?? EditorStyle.font).advancement(forGlyph: (font ?? EditorStyle.font).glyph(withName: "M")).width
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
                didChangeText()
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
            navigator = nil
            vi.enterInsert()
            modeChanged()
            didChangeText()
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

    /// The height for the text's lines (one to `maxLines`), always a whole number of lines so the
    /// bar, and the terminal above it, keep their size while typing on one line.
    func height(maxLines: Int = 8) -> CGFloat {
        let lineHeight = Self.lineHeight(for: font ?? EditorStyle.font)
        guard let layoutManager, let textContainer else { return lineHeight }
        layoutManager.ensureLayout(for: textContainer)
        var lines = 0
        layoutManager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layoutManager.numberOfGlyphs)) { _, _, _, _, _ in
            lines += 1
        }
        if layoutManager.extraLineFragmentTextContainer != nil, (string as NSString).length > 0 { lines += 1 }
        return CGFloat(min(maxLines, max(1, lines))) * lineHeight
    }

    static func lineHeight(for font: NSFont) -> CGFloat {
        NSLayoutManager().defaultLineHeight(for: font).rounded(.up)
    }

    /// Every line exactly `lineHeight` tall, so the line count above is the layout's.
    func applyParagraphStyle() {
        let style = NSMutableParagraphStyle()
        let lineHeight = Self.lineHeight(for: font ?? EditorStyle.font)
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        defaultParagraphStyle = style
        typingAttributes[.paragraphStyle] = style
        if let storage = textStorage, storage.length > 0 {
            storage.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: storage.length))
        }
    }
}
