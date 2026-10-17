import AppKit
import CommandBlocks
import GhosttyBridge
import SwiftUI

/// A pane's command blocks, drawn over its terminal: a hairline above each command, a red mark
/// beside a command that failed, the selected block (⌘↑ and ⌘↓), a header naming the command
/// whose output fills the screen when scrolled back, and copy buttons on the block under the
/// pointer. It also keeps the selection and copies blocks.
///
/// The terminal is a layer-hosting view, so this sits beside it in the pane's host, which moves
/// it with the terminal. Clicks pass through to the terminal except on the header and buttons.
@MainActor
final class BlockOverlayView: NSView {
    private weak var surface: TerminalSurfaceView?
    private(set) var snapshot: BlockSnapshot?
    private(set) var selection: BlockSelection?
    private var hovered: BlockSelection?

    private let dividers = CAShapeLayer()
    private let failures = CAShapeLayer()
    private let selectionFill = CALayer()
    private let selectionBar = CALayer()
    private let flash = CALayer()
    private let header = NSHostingView(rootView: StickyHeader(model: .init()))
    private let buttons = NSHostingView(rootView: BlockButtons(actions: .init()))
    private var headerModel = StickyHeader.Model()
    /// "↓ 12 new lines": output arrived while the screen is scrolled back.
    private let newOutputPill = NSHostingView(rootView: NewOutputPill(count: 0, action: {}))
    private var newOutput = NewOutputTracker()
    private var newOutputCount: Int?

    private var refreshQueued = false
    /// A refresh was skipped while hidden (another tab, or behind a zoom): one comes when shown.
    private var staleWhileHidden = false
    private var lastRefresh: CFTimeInterval = 0
    /// The bounds the last layout pass refreshed for.
    private var laidOutBounds: CGRect?
    /// What the last render drew from.
    private var rendered: RenderState?
    private var buttonsDark: Bool?
    /// While a block is selected or under the pointer, its last row can move as its command
    /// prints, before the screen fills and scrolls; a slow poll keeps the outline on it, while
    /// the pane can be seen.
    private var poll: Timer?
    nonisolated(unsafe) private var windowObservers: [NSObjectProtocol] = []
    /// The command the header names, read from the terminal once: the block keeps its command
    /// while its rows shift as old ones drop off the top.
    private var headerCommand: (block: BlockSelection, text: String)?
    /// Puts a command in the pane's input bar; false when the pane is not at a prompt.
    var onRerun: ((String) -> Bool)?
    /// Saves a command for the palette (asks for its name).
    var onSave: ((String) -> Void)?

    init(surface: TerminalSurfaceView) {
        self.surface = surface
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        for sub in [selectionFill, selectionBar, flash] {
            sub.isHidden = true
            sub.actions = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
        }
        for shape in [dividers, failures] {
            shape.actions = ["path": NSNull()]
        }
        selectionBar.cornerRadius = 1
        flash.opacity = 0
        for sub in [dividers, failures, selectionFill, selectionBar, flash] { layer?.addSublayer(sub) }
        for view in [header, buttons, newOutputPill] as [NSView] {
            view.isHidden = true
            addSubview(view)
        }
        newOutputPill.sizingOptions = []
        newOutputPill.safeAreaRegions = []
        // Laid out here; and near the top of a window with a see-through titlebar, SwiftUI would
        // otherwise push their contents down out of the titlebar's way.
        header.sizingOptions = []
        header.safeAreaRegions = []
        buttons.sizingOptions = []
        buttons.safeAreaRegions = []
        buttons.rootView = BlockButtons(actions: .init(
            copyOutput: { [weak self] in self?.copyHovered(.output) ?? false },
            copyCommand: { [weak self] in self?.copyHovered(.command) ?? false },
            copyMarkdown: { [weak self] in self?.copyHovered(.markdown) ?? false },
            rerun: { [weak self] in self?.rerunHovered() },
            save: { [weak self] in self?.saveHovered() }
        ))
        surface.overlay = self
        surface.contextMenu = { [weak self] event in self?.contextMenu(for: event) }
        surface.onLayoutChange = { [weak self] in self?.setNeedsRefresh() }
        surface.onPointerMoved = { [weak self] event in self?.pointerMoved(event) }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    deinit {
        for o in windowObservers { NotificationCenter.default.removeObserver(o) }
    }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// Only the header and the buttons take clicks; everywhere else is the terminal's.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    override func layout() {
        super.layout()
        // Only a new size moves the blocks; layout passes come for other reasons too.
        guard bounds != laidOutBounds else { return }
        laidOutBounds = bounds
        setNeedsRefresh()
    }

    /// Also when an ancestor (the pane's host) is shown again.
    override func viewDidUnhide() {
        super.viewDidUnhide()
        refreshIfStale()
        updatePoll()
    }

    override func viewDidHide() {
        super.viewDidHide()
        updatePoll()
    }

    /// Moved to another host, which may be shown.
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        refreshIfStale()
    }

    private func refreshIfStale() {
        guard staleWhileHidden, !isHiddenOrHasHiddenAncestor else { return }
        staleWhileHidden = false
        setNeedsRefresh()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for o in windowObservers { NotificationCenter.default.removeObserver(o) }
        windowObservers.removeAll()
        updatePoll()
        guard let window else { return }
        let nc = NotificationCenter.default
        windowObservers = [
            nc.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updatePoll() }
            },
            // The pointer's tracking stops with the window's focus, maybe before it says it left.
            nc.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.pointerMoved(nil) }
            },
        ]
        setNeedsRefresh()
    }

    // MARK: State

    /// Reads the blocks again soon: on the next turn of the run loop, but no more often than a
    /// fast display draws (streaming output reports a scroll thousands of times a second), or 20
    /// times a second at the newest output with no block under the pointer or selected, where
    /// only the lines between commands move. Any number of calls before then read once.
    func setNeedsRefresh() {
        // Nobody sees a hidden pane's blocks: read them once it is shown again.
        guard !isHiddenOrHasHiddenAncestor else {
            staleWhileHidden = true
            return
        }
        guard !refreshQueued else { return }
        refreshQueued = true
        let calm = snapshot.map { $0.viewport.atBottom && !onScreen(hovered, in: $0) && !onScreen(selection, in: $0) } ?? false
        let wait = max(0, lastRefresh + (calm ? 1.0 / 20 : 1.0 / 120) - CACurrentMediaTime())
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshQueued = false
                guard !self.isHiddenOrHasHiddenAncestor else {
                    self.staleWhileHidden = true
                    return
                }
                self.refresh()
            }
        }
    }

    /// Reads the blocks on screen, or all of them when `all` (to move between them or copy one), and
    /// draws them. A selected block off the screen is kept until a read of all of them misses it.
    func refresh(all: Bool = false) {
        lastRefresh = CACurrentMediaTime()
        #if DEBUG
        if Self.disabled { return }
        let started = lastRefresh
        defer { Self.readTime += CACurrentMediaTime() - started; Self.reads += 1 }
        #endif
        guard window != nil, let snap = surface?.blockSnapshot(all ? .all : .viewport) else {
            snapshot = nil
            render()
            return
        }
        snapshot = snap
        if let selection, !snap.hasBlocks || (all && selection.index(in: snap) == nil) { self.selection = nil }
        if !snap.hasBlocks { headerCommand = nil }
        render()
    }

    /// A new command started: the blocks are counted from the newest, so a selection would move
    /// to another command.
    func commandStarted() {
        selection = nil
        // Counted from the newest too; and after a clear, rows and counts start over, so the
        // header's command read for one block would name another.
        hovered = nil
        headerCommand = nil
        setNeedsRefresh()
    }

    func clearSelection() {
        guard selection != nil else { return }
        selection = nil
        render()
    }

    var hasBlocks: Bool { snapshot?.hasBlocks ?? false }

    // MARK: Navigation

    func selectPrevious() {
        refresh(all: true)
        guard let snapshot else { return }
        select(BlockNavigation.previous(from: selection, in: snapshot))
    }

    func selectNext() {
        refresh(all: true)
        guard let snapshot else { return }
        let next = BlockNavigation.next(from: selection, in: snapshot)
        if next == nil, selection != nil {
            selection = nil
            surface?.scrollToBottom()
            refresh()
            return
        }
        select(next)
    }

    /// The previous or next block that failed; a beep when there is none.
    func selectPreviousFailed() {
        refresh(all: true)
        guard let snapshot, let previous = BlockNavigation.previousFailed(from: selection, in: snapshot) else {
            NSSound.beep()
            return
        }
        select(previous)
    }

    func selectNextFailed() {
        refresh(all: true)
        guard let snapshot, let next = BlockNavigation.nextFailed(from: selection, in: snapshot) else {
            NSSound.beep()
            return
        }
        select(next)
    }

    private func select(_ new: BlockSelection?) {
        selection = new
        if let snapshot, let index = new?.index(in: snapshot),
           let top = BlockNavigation.scrollTarget(for: snapshot.blocks[index], in: snapshot.viewport) {
            // libghostty scrolls at once, so the next read already has the new position.
            surface?.scroll(toRow: top)
        }
        refresh()
    }

    // MARK: Copying

    /// Copies part of the selected block, else of the newest one. False when there is nothing to
    /// copy (no blocks, or a command that printed nothing).
    @discardableResult
    func copy(_ part: CopyPart) -> Bool {
        refresh(all: true)
        guard let snapshot, let index = selection?.index(in: snapshot) ?? snapshot.blocks.indices.last else { return false }
        return copy(part, of: index)
    }

    /// Puts the selected block's command (else the newest's) in the input bar, for the user to
    /// run with Return. A beep when the pane is not at a prompt, or the block has no command.
    @discardableResult
    func rerun() -> Bool {
        refresh(all: true)
        guard let snapshot, let index = selection?.index(in: snapshot) ?? snapshot.blocks.indices.last else { return false }
        return rerun(index)
    }

    private func copyHovered(_ part: CopyPart) -> Bool {
        guard let index = buttonsIndex else { return false }
        return copy(part, of: index)
    }

    private func rerunHovered() {
        guard let index = buttonsIndex else { return }
        rerun(index)
    }

    @discardableResult
    private func rerun(_ index: Int) -> Bool {
        guard let snapshot, let block = snapshot.blocks[safe: index],
              let command = surface?.blockText(row: block.row, part: .command), !command.isEmpty,
              onRerun?(command) == true else {
            NSSound.beep()
            return false
        }
        flashBlock(index)
        return true
    }

    @discardableResult
    private func copy(_ part: CopyPart, of index: Int) -> Bool {
        guard let snapshot, let block = snapshot.blocks[safe: index], let surface else {
            NSSound.beep()
            return false
        }
        let text: String?
        switch part {
        case .output: text = surface.blockText(row: block.row, part: .output)
        case .command: text = surface.blockText(row: block.row, part: .command)
        case .markdown:
            text = surface.blockText(row: block.row, part: .command).map {
                BlockMarkdown.format(command: $0, output: surface.blockText(row: block.row, part: .output) ?? "")
            }
        }
        guard let text, !text.isEmpty else {
            NSSound.beep()
            return false
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        shineBlock(index)
        return true
    }

    /// A copied block catches the light, as Rex's code cards do (`CopyShine`).
    private func shineBlock(_ index: Int) {
        guard let layer, let snapshot, let frame = BlockLayout.visible(snapshot).first(where: { $0.index == index }) else { return }
        CopyShine.play(in: layer, rect: blockRect(frame).insetBy(dx: 3, dy: 0), cornerRadius: 6, dark: buttonsDark ?? true)
    }

    private func flashBlock(_ index: Int) {
        guard let snapshot, let frame = BlockLayout.visible(snapshot).first(where: { $0.index == index }) else { return }
        flash.frame = blockRect(frame)
        flash.backgroundColor = Self.accent.withAlphaComponent(0.22).cgColor
        flash.isHidden = false
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.45
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        flash.add(fade, forKey: "flash")
    }

    // MARK: Context menu

    /// Right-click on a block: it gets selected, and the menu acts on it. Nothing outside blocks.
    private func contextMenu(for event: NSEvent) -> NSMenu? {
        guard window != nil else { return nil }
        refresh(all: true)
        guard let snapshot else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        guard let index = BlockLayout.block(atY: point.y, in: snapshot) else { return nil }
        selection = BlockSelection(index: index, in: snapshot)
        render()
        let menu = NSMenu()
        for (title, action) in [("Copy Command", #selector(menuCopyCommand)), ("Copy Output", #selector(menuCopyOutput)),
                                ("Copy as Markdown", #selector(menuCopyMarkdown)), ("Rerun", #selector(menuRerun)),
                                ("Save Command…", #selector(menuSave))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        // Through the responder chain, to the window.
        menu.addItem(NSMenuItem(title: "Label Pane…", action: #selector(TerminalWindowController.labelPane(_:)), keyEquivalent: ""))
        return menu
    }

    @objc private func menuCopyCommand() { copy(.command) }
    @objc private func menuCopyOutput() { copy(.output) }
    @objc private func menuCopyMarkdown() { copy(.markdown) }
    @objc private func menuRerun() { rerun() }
    @objc private func menuSave() {
        guard let snapshot, let index = selection?.index(in: snapshot) else { return }
        save(index)
    }

    private func saveHovered() {
        guard let snapshot, let index = hovered?.index(in: snapshot) ?? selection?.index(in: snapshot) else { return }
        save(index)
    }

    private func save(_ index: Int) {
        guard let snapshot, let block = snapshot.blocks[safe: index],
              let command = surface?.blockText(row: block.row, part: .command), !command.isEmpty else {
            NSSound.beep()
            return
        }
        onSave?(command)
    }

    // MARK: Pointer

    /// The terminal's own pointer tracking: the block under the pointer gets the copy buttons.
    private func pointerMoved(_ event: NSEvent?) {
        var block: BlockSelection?
        if let event, let snapshot {
            let point = convert(event.locationInWindow, from: nil)
            block = BlockLayout.block(atY: point.y, in: snapshot).map { BlockSelection(index: $0, in: snapshot) }
        }
        guard block != hovered else { return }
        hovered = block
        render()
    }

    // MARK: Drawing

    /// The block the copy buttons are on: the one under the pointer, else the selected one.
    private var buttonsIndex: Int?

    /// Everything a render draws from: when none of it changed, neither would the drawing.
    private struct RenderState: Equatable {
        var snapshot: BlockSnapshot?
        var size: CGSize
        var hovered: BlockSelection?
        var selection: BlockSelection?
        var scale: CGFloat?
        var text: NSColor
        var failure: NSColor
        var accent: NSColor
        var font: NSFont
    }

    private func render() {
        let state = RenderState(
            snapshot: snapshot, size: bounds.size, hovered: hovered, selection: selection, scale: window?.backingScaleFactor,
            text: EditorStyle.colors.text, failure: EditorStyle.colors.unknownCommand,
            accent: Self.accent.usingColorSpace(.sRGB) ?? Self.accent, font: EditorStyle.font
        )
        guard state != rendered else { return }
        rendered = state
        layoutNewOutputPill(snapshot?.viewport)
        guard let snapshot, !snapshot.blocks.isEmpty, bounds.height > 0 else {
            hideAll()
            return
        }
        let frames = BlockLayout.visible(snapshot)
        let text = EditorStyle.colors.text
        let scale = window?.backingScaleFactor ?? 2
        let hairline = 1 / scale

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let lines = CGMutablePath()
        let marks = CGMutablePath()
        for frame in frames {
            // Between each command and the one before, when on screen.
            if let mid = BlockLayout.dividerY(before: frame.index, in: snapshot), mid > 1 {
                let y = (mid * scale).rounded() / scale - hairline / 2
                lines.addRect(CGRect(x: 0, y: y, width: bounds.width, height: hairline))
            }
            if snapshot.blocks[frame.index].failed {
                let rect = blockRect(frame).insetBy(dx: 0, dy: 3)
                marks.addRoundedRect(in: CGRect(x: 3, y: rect.minY, width: 2.5, height: max(2, rect.height)), cornerWidth: 1.25, cornerHeight: 1.25)
            }
        }
        dividers.frame = bounds
        dividers.path = lines
        dividers.fillColor = text.withAlphaComponent(0.14).cgColor
        failures.frame = bounds
        failures.path = marks
        failures.fillColor = EditorStyle.colors.unknownCommand.withAlphaComponent(0.85).cgColor

        let selected = selection?.index(in: snapshot)
        if let selected, let frame = frames.first(where: { $0.index == selected }) {
            let rect = blockRect(frame)
            selectionFill.frame = rect
            selectionFill.backgroundColor = Self.accent.withAlphaComponent(0.09).cgColor
            selectionBar.frame = CGRect(x: 3, y: rect.minY + 3, width: 2.5, height: max(2, rect.height - 6))
            // A failed command keeps its red mark when selected.
            let failed = snapshot.blocks[selected].failed
            selectionBar.backgroundColor = (failed ? EditorStyle.colors.unknownCommand : Self.accent).cgColor
            selectionFill.isHidden = false
            selectionBar.isHidden = false
        } else {
            selectionFill.isHidden = true
            selectionBar.isHidden = true
        }

        layoutHeader(snapshot)
        layoutButtons(snapshot, frames: frames, selected: selected)
        updatePoll()
    }

    /// A block's rows, across the whole width.
    private func blockRect(_ frame: BlockLayout.Frame) -> CGRect {
        CGRect(x: 0, y: frame.minY, width: bounds.width, height: frame.maxY - frame.minY)
    }

    private func layoutHeader(_ snapshot: BlockSnapshot) {
        guard let index = BlockLayout.sticky(snapshot) else {
            header.isHidden = true
            return
        }
        let block = snapshot.blocks[index]
        let id = BlockSelection(index: index, in: snapshot)
        let command: String
        if let cached = headerCommand, cached.block == id {
            command = cached.text
        } else {
            command = surface?.blockText(row: block.row, part: .command) ?? ""
            headerCommand = (id, command)
        }
        let model = StickyHeader.Model(
            command: command, exitCode: block.exitCode, running: index == snapshot.blocks.count - 1 && block.exitCode == nil,
            dark: Self.isDark, font: EditorStyle.font
        )
        if model != headerModel || header.isHidden {
            headerModel = model
            header.rootView = StickyHeader(model: model) { [weak self] in self?.reveal(id) }
        }
        // Over the top row only: the row it stands for.
        let v = snapshot.viewport
        header.frame = CGRect(x: 6, y: max(2, v.paddingTop - 4), width: max(0, bounds.width - 12), height: v.rowHeight + 4)
        header.isHidden = false
    }

    private func layoutButtons(_ snapshot: BlockSnapshot, frames: [BlockLayout.Frame], selected: Int?) {
        let index = hovered?.index(in: snapshot) ?? selected
        guard let index, let frame = frames.first(where: { $0.index == index }) else {
            buttons.isHidden = true
            buttonsIndex = nil
            return
        }
        buttonsIndex = index
        let size = CGSize(width: 6 + 24 * 5, height: 24)
        let top = header.isHidden ? 4 : header.frame.maxY + 4
        // At the block's top right, kept on screen while the block is.
        let y = min(max(frame.minY + 3, top), max(top, frame.maxY - size.height - 3))
        buttons.frame = CGRect(x: bounds.width - size.width - 10, y: y, width: size.width, height: size.height)
        let dark = Self.isDark
        if dark != buttonsDark {
            buttonsDark = dark
            buttons.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        }
        buttons.isHidden = false
    }

    /// At the bottom center while lines arrived below a scrolled-back screen; a click goes to them.
    private func layoutNewOutputPill(_ viewport: BlockViewport?) {
        let count = viewport.flatMap { newOutput.update($0) }
        guard let count else {
            newOutputPill.isHidden = true
            newOutputCount = nil
            return
        }
        if count != newOutputCount {
            newOutputCount = count
            newOutputPill.rootView = NewOutputPill(count: count) { [weak self] in self?.surface?.scrollToBottom() }
        }
        // Laid out here (sizing off, as for the header): the label's width, the arrow and padding.
        let label = NewOutputPill.label(count) as NSString
        let textWidth = label.size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]).width
        let size = CGSize(width: (textWidth + 50).rounded(.up), height: 28)
        newOutputPill.frame = CGRect(x: ((bounds.width - size.width) / 2).rounded(), y: bounds.height - size.height - 14,
                                     width: size.width, height: size.height)
        newOutputPill.appearance = NSAppearance(named: Self.isDark ? .darkAqua : .aqua)
        newOutputPill.isHidden = false
    }

    private func hideAll() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dividers.path = nil
        failures.path = nil
        selectionFill.isHidden = true
        selectionBar.isHidden = true
        CATransaction.commit()
        header.isHidden = true
        buttons.isHidden = true
        buttonsIndex = nil
        updatePoll()
    }

    /// Whether `block` is listed in `snapshot`: on the screen, or the one just above it.
    private func onScreen(_ block: BlockSelection?, in snapshot: BlockSnapshot) -> Bool {
        block?.index(in: snapshot) != nil
    }

    private func updatePoll() {
        let visible = window.map { $0.occlusionState.contains(.visible) } == true && !isHiddenOrHasHiddenAncestor
        let wanted = visible && snapshot.map { onScreen(selection, in: $0) || onScreen(hovered, in: $0) } == true
        if wanted, poll == nil {
            poll = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        } else if !wanted, let timer = poll {
            timer.invalidate()
            poll = nil
        }
    }

    /// Scrolls `block`'s command to the top, at the row it is on now.
    private func reveal(_ block: BlockSelection) {
        refresh()
        guard let snapshot, let index = block.index(in: snapshot) else { return }
        surface?.scroll(toRow: snapshot.blocks[index].row)
        refresh()
    }

    private static var accent: NSColor { .controlAccentColor }

    /// The terminal theme's darkness, from its text color.
    private static var isDark: Bool {
        let text = EditorStyle.colors.text.usingColorSpace(.sRGB) ?? .white
        return text.brightnessComponent > 0.5
    }
}

#if DEBUG
extension BlockOverlayView {
    /// Time spent reading and drawing blocks, for the debug driver.
    nonisolated(unsafe) static var readTime: CFTimeInterval = 0
    nonisolated(unsafe) static var reads = 0
    /// Stops reading blocks, to compare throughput without them.
    nonisolated(unsafe) static var disabled = false

    override var debugDescription: String {
        guard let snapshot else { return "no snapshot (window=\(window != nil))" }
        let v = snapshot.viewport
        var lines = ["viewport top=\(v.top) rows=\(v.rows) total=\(v.totalRows) newer=\(snapshot.newer) rowHeight=\(v.rowHeight) padTop=\(v.paddingTop) atBottom=\(v.atBottom) frame=\(NSStringFromRect(frame)) superview=\(superview.map { "\(type(of: $0))" } ?? "-") above=\(superview?.subviews.last === self)"]
        for (i, b) in snapshot.blocks.enumerated() {
            lines.append("block \(i) rows=\(b.row)-\(b.endRow) exit=\(b.exitCode.map(String.init) ?? "-")")
        }
        lines.append("selection=\(selection.map { "fromEnd \($0.fromEnd) index \($0.index(in: snapshot).map(String.init) ?? "-")" } ?? "-") hovered=\(hovered.flatMap { $0.index(in: snapshot) }.map(String.init) ?? "-")")
        lines.append("header=\(header.isHidden ? "hidden" : "\(headerModel.command.debugDescription) \(NSStringFromRect(header.frame))") buttons=\(buttons.isHidden ? "hidden" : NSStringFromRect(buttons.frame))")
        lines.append("reads=\(Self.reads) readTime=\(String(format: "%.1f", Self.readTime * 1000))ms buttonsInWindow=\(buttons.isHidden ? "-" : NSStringFromRect(buttons.convert(buttons.bounds, to: nil)))")
        lines.append("dividers=\(dividers.path.map { NSStringFromRect($0.boundingBoxOfPath) } ?? "-") failures=\(failures.path.map { NSStringFromRect($0.boundingBoxOfPath) } ?? "-") selectionFill=\(selectionFill.isHidden ? "hidden" : NSStringFromRect(selectionFill.frame))")
        return lines.joined(separator: "\n")
    }
}
#endif

/// What copying a block takes.
enum CopyPart {
    case command, output, markdown
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
