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
    private var hovered: Int?

    private let dividers = CAShapeLayer()
    private let failures = CAShapeLayer()
    private let selectionFill = CALayer()
    private let selectionBar = CALayer()
    private let flash = CALayer()
    private let header = NSHostingView(rootView: StickyHeader(model: .init()))
    private let buttons = NSHostingView(rootView: BlockButtons(actions: .init()))
    private var headerModel = StickyHeader.Model()

    private var refreshQueued = false
    private var lastRefresh: CFTimeInterval = 0
    /// While a block is selected or under the pointer, its last row can move as its command
    /// prints, before the screen fills and scrolls; a slow poll keeps the outline on it.
    private var poll: Timer?
    /// Commands by row, read from the terminal for the header.
    private var commands: [Int: String] = [:]

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
        for view in [header, buttons] as [NSView] {
            view.isHidden = true
            addSubview(view)
        }
        // Laid out here; and near the top of a window with a see-through titlebar, SwiftUI would
        // otherwise push their contents down out of the titlebar's way.
        header.sizingOptions = []
        header.safeAreaRegions = []
        buttons.sizingOptions = []
        buttons.safeAreaRegions = []
        buttons.rootView = BlockButtons(actions: .init(
            copyOutput: { [weak self] in self?.copyHovered(.output) },
            copyCommand: { [weak self] in self?.copyHovered(.command) }
        ))
        surface.overlay = self
        surface.onLayoutChange = { [weak self] in self?.setNeedsRefresh() }
        surface.onPointerMoved = { [weak self] event in self?.pointerMoved(event) }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// Only the header and the buttons take clicks; everywhere else is the terminal's.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    override func layout() {
        super.layout()
        setNeedsRefresh()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            poll?.invalidate()
            poll = nil
        } else {
            setNeedsRefresh()
        }
    }

    // MARK: State

    /// Reads the blocks again soon: on the next turn of the run loop, but no more often than a
    /// fast display draws (streaming output reports a scroll thousands of times a second). Any
    /// number of calls before then read once.
    func setNeedsRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        let wait = max(0, lastRefresh + 1.0 / 120 - CACurrentMediaTime())
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshQueued = false
                self.refresh()
            }
        }
    }

    func refresh() {
        lastRefresh = CACurrentMediaTime()
        #if DEBUG
        if Self.disabled { return }
        let started = lastRefresh
        defer { Self.readTime += CACurrentMediaTime() - started; Self.reads += 1 }
        #endif
        guard window != nil, let snap = surface?.blockSnapshot() else {
            snapshot = nil
            render()
            return
        }
        if snap.blocks.map(\.row) != snapshot?.blocks.map(\.row) { commands.removeAll() }
        snapshot = snap
        if let selection, selection.index(in: snap.blocks) == nil { self.selection = nil }
        render()
    }

    /// A new command started: the blocks are counted from the newest, so a selection would move
    /// to another command.
    func commandStarted() {
        selection = nil
        setNeedsRefresh()
    }

    func clearSelection() {
        guard selection != nil else { return }
        selection = nil
        render()
    }

    var hasBlocks: Bool { !(snapshot?.blocks.isEmpty ?? true) }

    // MARK: Navigation

    func selectPrevious() {
        refresh()
        guard let snapshot else { return }
        select(BlockNavigation.previous(from: selection, in: snapshot))
    }

    func selectNext() {
        refresh()
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

    private func select(_ new: BlockSelection?) {
        selection = new
        if let snapshot, let index = new?.index(in: snapshot.blocks),
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
    func copy(_ part: BlockPart) -> Bool {
        refresh()
        guard let snapshot, let index = selection?.index(in: snapshot.blocks) ?? snapshot.blocks.indices.last else { return false }
        return copy(part, of: index)
    }

    private func copyHovered(_ part: BlockPart) {
        guard let index = buttonsIndex else { return }
        copy(part, of: index)
    }

    @discardableResult
    private func copy(_ part: BlockPart, of index: Int) -> Bool {
        guard let snapshot, let block = snapshot.blocks[safe: index],
              let text = surface?.blockText(row: block.row, part: part), !text.isEmpty else {
            NSSound.beep()
            return false
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        flashBlock(index)
        return true
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

    // MARK: Pointer

    /// The terminal's own pointer tracking: the block under the pointer gets the copy buttons.
    private func pointerMoved(_ event: NSEvent?) {
        var index: Int?
        if let event {
            let point = convert(event.locationInWindow, from: nil)
            index = snapshot.flatMap { BlockLayout.block(atY: point.y, in: $0) }
        }
        guard index != hovered else { return }
        hovered = index
        render()
    }

    // MARK: Drawing

    /// The block the copy buttons are on: the one under the pointer, else the selected one.
    private var buttonsIndex: Int?

    private func render() {
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

        let selected = selection?.index(in: snapshot.blocks)
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
        let command = commands[block.row] ?? surface?.blockText(row: block.row, part: .command) ?? ""
        commands[block.row] = command
        let model = StickyHeader.Model(
            command: command, exitCode: block.exitCode, running: index == snapshot.blocks.count - 1 && block.exitCode == nil,
            dark: Self.isDark, font: EditorStyle.font
        )
        if model != headerModel || header.isHidden {
            headerModel = model
            header.rootView = StickyHeader(model: model) { [weak self] in self?.reveal(row: block.row) }
        }
        // Over the top row only: the row it stands for.
        let v = snapshot.viewport
        header.frame = CGRect(x: 6, y: max(2, v.paddingTop - 4), width: max(0, bounds.width - 12), height: v.rowHeight + 4)
        header.isHidden = false
    }

    private func layoutButtons(_ snapshot: BlockSnapshot, frames: [BlockLayout.Frame], selected: Int?) {
        let index = hovered ?? selected
        guard let index, let frame = frames.first(where: { $0.index == index }) else {
            buttons.isHidden = true
            buttonsIndex = nil
            return
        }
        buttonsIndex = index
        let size = CGSize(width: 58, height: 24)
        let top = header.isHidden ? 4 : header.frame.maxY + 4
        // At the block's top right, kept on screen while the block is.
        let y = min(max(frame.minY + 3, top), max(top, frame.maxY - size.height - 3))
        buttons.frame = CGRect(x: bounds.width - size.width - 10, y: y, width: size.width, height: size.height)
        buttons.appearance = NSAppearance(named: Self.isDark ? .darkAqua : .aqua)
        buttons.isHidden = false
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

    private func updatePoll() {
        let wanted = window != nil && (selection != nil || hovered != nil)
        if wanted, poll == nil {
            poll = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        } else if !wanted, let timer = poll {
            timer.invalidate()
            poll = nil
        }
    }

    /// Scrolls the command on `row` to the top.
    private func reveal(row: Int) {
        surface?.scroll(toRow: row)
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
        var lines = ["viewport top=\(v.top) rows=\(v.rows) total=\(v.totalRows) rowHeight=\(v.rowHeight) padTop=\(v.paddingTop) atBottom=\(v.atBottom) frame=\(NSStringFromRect(frame)) superview=\(superview.map { "\(type(of: $0))" } ?? "-") above=\(superview?.subviews.last === self)"]
        for (i, b) in snapshot.blocks.enumerated() {
            lines.append("block \(i) rows=\(b.row)-\(b.endRow) exit=\(b.exitCode.map(String.init) ?? "-")")
        }
        lines.append("selection=\(selection.map { "fromEnd \($0.fromEnd) index \($0.index(in: snapshot.blocks).map(String.init) ?? "-")" } ?? "-") hovered=\(hovered.map(String.init) ?? "-")")
        lines.append("header=\(header.isHidden ? "hidden" : "\(headerModel.command.debugDescription) \(NSStringFromRect(header.frame))") buttons=\(buttons.isHidden ? "hidden" : NSStringFromRect(buttons.frame))")
        lines.append("reads=\(Self.reads) readTime=\(String(format: "%.1f", Self.readTime * 1000))ms buttonsInWindow=\(buttons.isHidden ? "-" : NSStringFromRect(buttons.convert(buttons.bounds, to: nil)))")
        lines.append("dividers=\(dividers.path.map { NSStringFromRect($0.boundingBoxOfPath) } ?? "-") failures=\(failures.path.map { NSStringFromRect($0.boundingBoxOfPath) } ?? "-") selectionFill=\(selectionFill.isHidden ? "hidden" : NSStringFromRect(selectionFill.frame))")
        return lines.joined(separator: "\n")
    }
}
#endif

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
