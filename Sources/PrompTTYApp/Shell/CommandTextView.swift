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
    /// Control keys for the shell: `d` (end of input) on an empty bar, `l` (clear screen).
    var onShellControl: ((Character) -> Void)?
    /// ⌃R: opens the history search, seeded with the bar's text.
    var onHistorySearch: ((String) -> Void)?
    var onFocus: (() -> Void)?
    var onTextChange: (() -> Void)?
    /// The terminal next to the bar: ⌘C copies its selection when the bar has none.
    weak var terminal: TerminalSurfaceView?
    /// Newest first.
    var history: () -> MergedHistory = { MergedHistory(newestFirst: []) }
    /// The commands run in the pane's folder and the folders above it, best first: ghost text
    /// prefers them to the whole history.
    var folderHistory: () -> [String] = { [] }
    /// Changes when `history` or `folderHistory` may have, which ends the incremental scan.
    var suggestionGeneration: () -> Int = { 0 }
    var isKnownCommand: (String) -> Bool = { _ in true }

    private(set) var vi = ViEngine()
    private var navigator: HistoryNavigator?
    /// Set while history replaces the text, so that edit does not end the history walk.
    private var replacingFromHistory = false
    /// The ghost text after the caret.
    private(set) var suggestion: String?
    private var suggester = IncrementalSuggester()
    private struct SuggestionKey: Equatable {
        let text: String
        let range: NSRange
        let marked: Bool
        let generation: Int
    }
    private var lastSuggestionKey: SuggestionKey?
    /// Where Tab completion looks: the pane's directory, and the shell's names (a snapshot with
    /// nothing fetched yet).
    var completionDirectory: () -> String? = { nil }
    var completionNames: () -> CompletionSnapshot? = { nil }
    /// Read off the main thread by the pane: a folder on a stalled share or a slow `git` must not
    /// freeze the bar.
    var listEntries: (String) async -> [(name: String, isDirectory: Bool)] = { _ in [] }
    var loadBranches: (String) async -> [String] = { _ in [] }
    private let popup = CompletionPopup()
    /// What the open completion list filters: fetched once when it opens (and again only when the
    /// word moves to another folder), so a keystroke does no disk or git work.
    private var popupSnapshot: (snapshot: CompletionSnapshot, directory: String)? {
        didSet {
            snapshotRevision += 1
            if popupSnapshot == nil { cachedCompletion = nil }
        }
    }
    /// Bumped whenever `popupSnapshot` changes, so the cached completion is worked out again.
    private var snapshotRevision = 0
    private struct CompletionKey: Equatable {
        let text: String
        let caret: Int
        let revision: Int
    }
    /// The last completion worked out: a keystroke refilters, places the ghost and accepts from one
    /// result, and ↑/↓ in the picker reuse it.
    private var cachedCompletion: (key: CompletionKey, completion: Completion?)?
    /// Bumped whenever the text, the list or the question changes: a fetch that finishes under an
    /// older number is stale and dropped.
    private var completionRequest = 0
    /// Fetches under way, so a keystroke while one runs waits for it instead of listing again.
    private var fetches: [CompletionNeed: Task<Void, Never>] = [:]
    /// The open list is `cd`'s folder picker, which opens by itself as the folder is typed.
    private var folderPickerOpen = false
    /// Escape closed the folder picker: it stays closed until the caret leaves `cd`'s folder.
    private var folderPickerDismissed = false
    /// Each bar keeps its own undo history; the window's is shared by every pane.
    private let ownUndoManager = UndoManager()
    /// Set while the app itself inserts text (completions, suggestions), which normal mode must
    /// not mistake for typing.
    private var insertingProgrammatically = false
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
        // Apple Intelligence's Writing Tools (the button that shows beside a selection or the
        // caret) and math results ("2+2=" offering 4) mean nothing for a command.
        writingToolsBehavior = .none
        mathExpressionCompletionType = .no
        popup.onClose = { [weak self] in
            guard let self else { return }
            popupSnapshot = nil
            completionRequest += 1
            if folderPickerOpen {
                folderPickerOpen = false
                suggestion = nil
                lastSuggestionKey = nil
                needsDisplay = true
                updateSuggestion()
            }
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var undoManager: UndoManager? { ownUndoManager }
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
        clearText()
        navigator = nil
        suggester = IncrementalSuggester()
        lastSuggestionKey = nil
        vi.enterInsert()
        modeChanged()
    }

    func styleChanged() {
        typingAttributes = [.font: EditorStyle.font, .foregroundColor: EditorStyle.colors.text]
        applyParagraphStyle()
        insertionPointColor = EditorStyle.cursor ?? EditorStyle.colors.text
        recolor()
        needsDisplay = true
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.shift, .control, .option, .command])
        // A composition in progress (Japanese, Chinese, Korean, dead keys) owns Return, Escape and
        // every other key until it is committed or cancelled.
        if hasMarkedText() {
            super.keyDown(with: event)
            return
        }
        if popup.isVisible, folderPickerOpen {
            // `cd`'s folder picker, best match at the bottom: ↑ goes to the next match, Tab or →
            // goes into the folder chosen, Return changes to it.
            switch (event.keyCode, mods) {
            case (126, []), (48, .shift): popup.move(by: 1); syncPickerGhost(); return
            case (125, []): popup.move(by: -1); syncPickerGhost(); return
            case (48, []), (124, []):
                acceptCompletion()
                updateFolderPicker()
                return
            case (36, []), (76, []):
                acceptCompletion()
                onSubmit?(string)
                return
            case (53, []):
                folderPickerDismissed = true
                popup.close()
                return
            default:
                break
            }
        } else if popup.isVisible {
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
        updateFolderPicker()
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
            replaceText(in: range, with: replacement)
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
        breakUndoCoalescing()
        replaceText(in: NSRange(location: 0, length: (string as NSString).length), with: next)
        var end = (next as NSString).length
        if vi.mode == .normal, end > 0 { end -= 1 }
        setSelectedRange(NSRange(location: end, length: 0))
    }

    /// Replaces `range` with `text` as an undoable edit, in the bar's own font and line height: a
    /// plain string would take the attributes of the text it replaces, and into an empty bar that
    /// is none at all (AppKit's Helvetica 12).
    private func replaceText(in range: NSRange, with text: String) {
        guard shouldChangeText(in: range, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: typingAttributes))
        didChangeText()
    }

    /// Replaces what is typed with `command`, the caret at its end, as one undoable edit.
    func setCommand(_ command: String) {
        breakUndoCoalescing()
        replaceText(in: NSRange(location: 0, length: (string as NSString).length), with: command)
        var end = (command as NSString).length
        if vi.mode == .normal, end > 0 { end -= 1 }
        setSelectedRange(NSRange(location: end, length: 0))
    }

    // MARK: Completion

    private func currentCompletion() -> Completion? {
        guard let context = popupSnapshot, selectedRange().length == 0 else { return nil }
        let key = CompletionKey(text: string, caret: selectedRange().location, revision: snapshotRevision)
        if let cachedCompletion, cachedCompletion.key == key { return cachedCompletion.completion }
        let completion = CompletionEngine.complete(text: key.text, cursor: key.caret, directory: context.directory,
                                                   home: NSHomeDirectory(), sources: context.snapshot)
        cachedCompletion = (key, completion)
        return completion
    }

    /// Tab: one match is inserted; several insert what they share and open the list.
    /// Empties the bar and its undo history (undoing into a sent command is meaningless, and the
    /// direct `string` assignment is not undoable).
    private func clearText() {
        string = ""
        ownUndoManager.removeAllActions()
        didChangeText()
    }

    /// Typing that reaches the text system without a key the engine saw (a dead key's committed
    /// character, the emoji picker, dictation) is a vi command in normal mode, not text.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard vi.mode == .normal, !insertingProgrammatically else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        if hasMarkedText() { unmarkText() }
        for ch in text { applyVi(.char(ch)) }
    }

    // MARK: File drops

    /// Files dropped on the bar (or on its terminal while the bar is shown): their paths, quoted,
    /// at the drop point, or at the caret.
    func insertDroppedFiles(_ urls: [URL], at index: Int? = nil) {
        // Without the pane's folder, paths stay absolute (the app's own folder means nothing here).
        let directory = completionDirectory() ?? ""
        let words = urls.map { ShellQuoting.pathArgument($0.path, directory: directory, home: NSHomeDirectory()) }
        // A composition in progress is committed first, as a click elsewhere would.
        if hasMarkedText() { unmarkText() }
        let text = string as NSString
        // In normal mode the block cursor sits on a character: the paths go after it, as `a` would.
        let caret = selectedRange().location + (vi.mode == .normal && selectedRange().location < text.length ? 1 : 0)
        let at = min(index ?? caret, text.length)
        let before = at > 0 ? text.substring(with: NSRange(location: at - 1, length: 1)) : " "
        let after = at < text.length ? text.substring(with: NSRange(location: at, length: 1)) : ""
        let spaceBefore = before.rangeOfCharacter(from: .whitespacesAndNewlines) == nil ? " " : ""
        // A space after, as a terminal leaves one: the next argument follows right away.
        let spaceAfter = after.isEmpty || after.rangeOfCharacter(from: .whitespacesAndNewlines) == nil ? " " : ""
        window?.makeFirstResponder(self)
        insertProgrammatically(spaceBefore + words.joined(separator: " ") + spaceAfter, replacing: NSRange(location: at, length: 0))
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.fileURLs(in: sender).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = Self.fileURLs(in: sender)
        guard !urls.isEmpty else { return super.performDragOperation(sender) }
        insertDroppedFiles(urls, at: characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil)))
        return true
    }

    private static func fileURLs(in sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    /// Inserts on the app's behalf (completions, suggestions), in any mode.
    private func insertProgrammatically(_ text: String, replacing range: NSRange) {
        insertingProgrammatically = true
        defer { insertingProgrammatically = false }
        insertText(text, replacementRange: range)
    }

    private func complete() {
        guard selectedRange().length == 0, let directory = completionDirectory(), let names = completionNames() else {
            NSSound.beep()
            return
        }
        popupSnapshot = (names, directory)
        completionRequest += 1
        whenFetched(thenDo: { $0.finishComplete() })
    }

    /// Fetches what the text needs that the snapshot lacks, then runs `action`, unless the user
    /// typed, moved the caret, or closed the list meanwhile (the next keystroke asks again).
    private func whenFetched(quiet: Bool = false, thenDo action: @escaping (CommandTextView) -> Void) {
        guard let context = popupSnapshot else { return }
        let caret = selectedRange().location
        guard let need = CompletionEngine.need(text: string, cursor: caret, directory: context.directory, home: NSHomeDirectory()),
              !context.snapshot.has(need) else {
            action(self)
            return
        }
        let request = completionRequest
        let text = string
        let fetch = fetches[need] ?? Task { [weak self] in
            guard let self else { return }
            switch need {
            case .directory(let path):
                let entries = await listEntries(path)
                let folders = await Task.detached(priority: .userInitiated) { FolderEntry.sorted(from: entries) }.value
                popupSnapshot?.snapshot.store(entries, folders: folders, forDirectory: path)
            case .gitBranches(let directory):
                let branches = await loadBranches(directory)
                popupSnapshot?.snapshot.branches[directory] = branches
            }
            fetches[need] = nil
        }
        fetches[need] = fetch
        Task { [weak self] in
            await fetch.value
            guard let self, request == completionRequest else { return }
            guard string == text, selectedRange() == NSRange(location: caret, length: 0) else {
                // Typing moved on while the list loaded; a refilter has its own request.
                if popup.isVisible == false, !quiet { NSSound.beep() }
                return
            }
            action(self)
        }
    }

    /// Tab, once the data is in: the rest of `complete`.
    private func finishComplete() {
        guard let completion = currentCompletion(), completion.candidates.count <= 500 else {
            NSSound.beep()
            return
        }
        let range = NSRange(location: completion.replacement.lowerBound, length: completion.replacement.count)
        if let single = completion.singleInsertion {
            popupSnapshot = nil
            insertProgrammatically(single, replacing: range)
            return
        }
        let typed = (string as NSString).substring(with: range)
        // Loose matches (`cd`'s folders) may share less than was typed, or something else.
        if (completion.commonPrefix as NSString).length > (typed as NSString).length, completion.commonPrefix.hasPrefix(typed) {
            insertProgrammatically(completion.commonPrefix, replacing: range)
        }
        guard let window else { return }
        let anchor = firstRect(forCharacterRange: NSRange(location: range.location, length: 0), actualRange: nil)
        popup.show(completion.candidates, anchor: anchor, in: window, font: font ?? EditorStyle.font)
    }

    private func refilterCompletions() {
        completionRequest += 1
        whenFetched(quiet: folderPickerOpen, thenDo: { $0.applyRefilter() })
    }

    private func applyRefilter() {
        guard popup.isVisible, let completion = currentCompletion(), completion.candidates.count <= 500 else {
            popup.close()
            return
        }
        popup.update(completion.candidates)
        if folderPickerOpen { syncPickerGhost() }
    }

    // MARK: cd's folder picker

    /// After a keystroke: in `cd`'s folder the picker opens (or follows the typing) without Tab;
    /// elsewhere it closes. Other lists follow the typing as before.
    private func updateFolderPicker() {
        let caret = selectedRange()
        guard caret.length == 0, vi.mode == .insert, !hasMarkedText(),
              CompletionEngine.picksFolder(text: string, cursor: caret.location) else {
            folderPickerDismissed = false
            if folderPickerOpen {
                popup.close()
            } else if popup.isVisible {
                refilterCompletions()
            }
            return
        }
        if popup.isVisible {
            refilterCompletions()
        } else if !folderPickerDismissed, let directory = completionDirectory(), let names = completionNames() {
            popupSnapshot = (names, directory)
            completionRequest += 1
            whenFetched(quiet: true, thenDo: { $0.showFolderPicker() })
        }
    }

    private func showFolderPicker() {
        guard let completion = currentCompletion(), completion.folders, completion.candidates.count <= 500, let window else {
            popupSnapshot = nil
            return
        }
        let anchor = firstRect(forCharacterRange: NSRange(location: completion.replacement.lowerBound, length: 0), actualRange: nil)
        popup.show(completion.candidates, anchor: anchor, in: window, font: font ?? EditorStyle.font, bottomUp: true)
        folderPickerOpen = true
        syncPickerGhost()
    }

    /// The rest of the chosen folder's name after the caret, in ghost text, when it continues what
    /// was typed ("config/ae" shows "rc/").
    private func syncPickerGhost() {
        var ghost: String?
        if let item = popup.selectedItem, let completion = currentCompletion() {
            let range = NSRange(location: completion.replacement.lowerBound, length: completion.replacement.count)
            let typed = (string as NSString).substring(with: range)
            if item.hasPrefix(typed), item.count > typed.count, selectedRange().location == (string as NSString).length {
                ghost = String(item.dropFirst(typed.count))
            }
        }
        if ghost != suggestion {
            suggestion = ghost
            needsDisplay = true
        }
    }

    private func acceptCompletion() {
        defer { popup.close() }
        // A list still waiting for its folder may hold another folder's names: insert only what the
        // current text completes to.
        guard let item = popup.selectedItem, let completion = currentCompletion(), completion.candidates.contains(item) else { return }
        let range = NSRange(location: completion.replacement.lowerBound, length: completion.replacement.count)
        insertProgrammatically(item.hasSuffix("/") ? item : item + " ", replacing: range)
    }

    // MARK: Suggestions

    private func updateSuggestion() {
        // The folder picker shows its own ghost text: the chosen folder's name.
        if folderPickerOpen {
            syncPickerGhost()
            return
        }
        let text = string
        let range = selectedRange()
        let atEnd = range.length == 0 && range.location == (text as NSString).length
        let marked = hasMarkedText()
        // Typing a key reports a new selection and then the text change; the second finds nothing new.
        let key = SuggestionKey(text: text, range: range, marked: marked, generation: suggestionGeneration())
        if key == lastSuggestionKey { return }
        lastSuggestionKey = key
        var next: String?
        if atEnd, !marked, !text.isEmpty, !text.contains("\n") {
            next = suggester.suggestion(for: text, local: folderHistory(), history: history(), generation: key.generation)
        }
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
        insertProgrammatically(text, replacing: NSRange(location: end, length: 0))
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
                // The shell session decides: run now, at the next prompt, or not at all. It clears
                // the text once the command is sent.
                onSubmit?(string)
            } else {
                return false
            }
            return true
        }
        guard mods == .control, let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        switch key {
        case "c":
            clearText()
            navigator = nil
            vi.enterInsert()
            modeChanged()
        case "d":
            guard string.isEmpty else { return false }
            onShellControl?("d")
        case "l":
            onShellControl?("l")
        case "r":
            onHistorySearch?(string)
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
        // The bar's font, not `font`: that is whatever font is at the caret, and a fallback font
        // (for → or an emoji) has a different line height.
        let lineHeight = Self.lineHeight(for: EditorStyle.font)
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
        let lineHeight = Self.lineHeight(for: EditorStyle.font)
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        defaultParagraphStyle = style
        typingAttributes[.paragraphStyle] = style
        if let storage = textStorage, storage.length > 0 {
            storage.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: storage.length))
        }
    }
}
