import AppKit
import GhosttyKit

extension TerminalSurfaceView {
    // MARK: Keyboard

    /// AppKit offers key equivalents to every view before the menu, and delivers some Control
    /// combinations (Ctrl+Return, Ctrl+/, Ctrl+Tab, …) only this way, never as `keyDown`. Keys
    /// without ⌘ belong to the terminal, so take them here; ⌘ keys go on to the menu, and reach
    /// `keyDown` only if no menu item claims them.
    ///
    /// The menu still gets the first look at non-⌘ keys: the app's own items all contain ⌘, so
    /// only system-provided items can match (Globe shortcuts such as window tiling and Emoji &
    /// Symbols), and those should keep working while a terminal is focused.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              window?.firstResponder === self,
              KeyRouting.terminalHandlesKeyEquivalent(flags: event.modifierFlags) else {
            return super.performKeyEquivalent(with: event)
        }
        if NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return true }
        keyDown(with: event)
        return true
    }

    public override func keyDown(with event: NSEvent) {
        guard let surface else { return }
        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        // Let the text system run first so IME, dead keys, and `insertText` happen; we collect the
        // resulting text and send one key event with it attached.
        let hadMarkedText = markedText.length > 0
        keyTextAccumulator = []
        interpretKeyEvents([event])
        let collected = keyTextAccumulator ?? []
        keyTextAccumulator = nil
        let text = collected.joined()

        if text.isEmpty {
            // Nothing committed. If a composition was active before or after this key (e.g. Backspace
            // deleting the last preedit character, Escape cancelling it), the key belongs to the IME:
            // `composing` makes libghostty's encoder emit nothing for it.
            var key = makeKey(event, action: action)
            key.composing = hadMarkedText || markedText.length > 0
            _ = ghostty_surface_key(surface, key)
        } else if hadMarkedText {
            // A composition was committed (Enter/Space in a Japanese IME, the next jamo in Korean).
            // Send only the text, detached from the committing key so it is not also encoded
            // (as Enter, Space, …). A new composition may already have started; that is preedit
            // state, not a property of this committed text, so `composing` stays false.
            sendCommittedText(text, action: action, surface: surface)
        } else {
            var key = makeKey(event, action: action)
            text.withCString { ptr in
                key.text = ptr
                _ = ghostty_surface_key(surface, key)
            }
        }
    }

    /// Mirrors Ghostty's `committedPreeditTextAction`: a key event with no keycode or mods, text only.
    private func sendCommittedText(_ text: String, action: ghostty_input_action_e, surface: UnsafeMutableRawPointer) {
        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = 0
        key.mods = GHOSTTY_MODS_NONE
        key.consumed_mods = GHOSTTY_MODS_NONE
        key.unshifted_codepoint = 0
        key.composing = false
        text.withCString { ptr in
            key.text = ptr
            _ = ghostty_surface_key(surface, key)
        }
    }

    public override func keyUp(with event: NSEvent) {
        guard let surface else { return }
        let key = makeKey(event, action: GHOSTTY_ACTION_RELEASE)
        _ = ghostty_surface_key(surface, key)
    }

    public override func flagsChanged(with event: NSEvent) {
        guard let surface, let flag = InputTranslation.modifierKey(forKeyCode: event.keyCode) else { return }
        // Modifier presses during a composition belong to the IME.
        if markedText.length > 0 { return }
        // `.shift` etc. stay set while the other side's key is still held, so for right-side keys
        // also require that side's device bit; otherwise releasing right-shift with left-shift held
        // would be reported as a press.
        let pressed = event.modifierFlags.contains(flag)
            && InputTranslation.isSidePressed(keyCode: event.keyCode, flags: event.modifierFlags)
        var key = makeKey(event, action: pressed ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE)
        key.text = nil
        _ = ghostty_surface_key(surface, key)
    }

    /// Swallow text-system commands (moveLeft:, deleteBackward:, …) so AppKit does not beep;
    /// libghostty gets the raw key and encodes it itself.
    public override func doCommand(by selector: Selector) {}

    private func makeKey(_ event: NSEvent, action: ghostty_input_action_e) -> ghostty_input_key_s {
        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = UInt32(event.keyCode)
        let mods = InputTranslation.mods(event.modifierFlags)
        key.mods = mods
        key.consumed_mods = surface.map { ghostty_surface_key_translation_mods($0, mods) } ?? GHOSTTY_MODS_NONE
        if event.type == .keyDown || event.type == .keyUp,
           let unshifted = event.characters(byApplyingModifiers: []),
           let scalar = unshifted.unicodeScalars.first {
            key.unshifted_codepoint = scalar.value
        }
        key.text = nil
        key.composing = false
        return key
    }

    // MARK: Mouse

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    public override func mouseDown(with event: NSEvent) { sendMouseButton(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, event) }
    public override func mouseUp(with event: NSEvent) { sendMouseButton(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, event) }
    public override func rightMouseDown(with event: NSEvent) { sendMouseButton(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, event) }
    public override func rightMouseUp(with event: NSEvent) { sendMouseButton(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, event) }
    public override func otherMouseDown(with event: NSEvent) {
        sendMouseButton(GHOSTTY_MOUSE_PRESS, InputTranslation.mouseButton(event.buttonNumber), event)
    }
    public override func otherMouseUp(with event: NSEvent) {
        sendMouseButton(GHOSTTY_MOUSE_RELEASE, InputTranslation.mouseButton(event.buttonNumber), event)
    }

    public override func mouseMoved(with event: NSEvent) { sendMousePosition(event) }
    public override func mouseDragged(with event: NSEvent) { sendMousePosition(event) }
    public override func rightMouseDragged(with event: NSEvent) { sendMousePosition(event) }
    public override func otherMouseDragged(with event: NSEvent) { sendMousePosition(event) }

    public override func mouseExited(with event: NSEvent) {
        guard let surface else { return }
        // During a drag AppKit keeps delivering dragged events outside the view; reporting
        // "left the viewport" here would interrupt the selection.
        if NSEvent.pressedMouseButtons != 0 { return }
        ghostty_surface_mouse_pos(surface, -1, -1, InputTranslation.mods(event.modifierFlags))
    }

    public override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precise = event.hasPreciseScrollingDeltas
        if precise {
            // Same 2x as Ghostty's macOS app. Discrete (wheel) deltas are passed through untouched:
            // libghostty treats them as wheel ticks and scales them by cell height and
            // `mouse-scroll-multiplier` itself.
            x *= 2
            y *= 2
        }
        let mods = InputTranslation.scrollMods(precision: precise, momentumPhase: event.momentumPhase)
        ghostty_surface_mouse_scroll(surface, x, y, mods)
    }

    public override func pressureChange(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_pressure(surface, UInt32(event.stage), Double(event.pressure))
    }

    private func sendMouseButton(_ state: ghostty_input_mouse_state_e, _ button: ghostty_input_mouse_button_e, _ event: NSEvent) {
        guard let surface else { return }
        if state == GHOSTTY_MOUSE_PRESS, window?.firstResponder !== self {
            window?.makeFirstResponder(self)
        }
        sendMousePosition(event)
        _ = ghostty_surface_mouse_button(surface, state, button, InputTranslation.mods(event.modifierFlags))
    }

    private func sendMousePosition(_ event: NSEvent) {
        guard let surface else { return }
        let p = convert(event.locationInWindow, from: nil)
        // libghostty wants a top-left origin; AppKit views are bottom-left unless flipped.
        ghostty_surface_mouse_pos(surface, p.x, bounds.height - p.y, InputTranslation.mods(event.modifierFlags))
    }

    // MARK: Cursor

    public func apply(mouseShape: MouseShape) {
        currentMouseShape = mouseShape
        window?.invalidateCursorRects(for: self)
        cursor(for: mouseShape).set()
    }

    public override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor(for: currentMouseShape))
    }

    private func cursor(for shape: MouseShape) -> NSCursor {
        switch shape {
        case .default, .other, .progress, .wait: return .arrow
        case .text: return .iBeam
        case .pointer: return .pointingHand
        case .crosshair: return .crosshair
        case .verticalText: return .iBeamCursorForVerticalLayout
        case .notAllowed: return .operationNotAllowed
        case .grab: return .openHand
        case .grabbing: return .closedHand
        case .resizeEW: return .resizeLeftRight
        case .resizeNS: return .resizeUpDown
        case .resizeNESW, .resizeNWSE: return .arrow
        case .contextMenu: return .contextualMenu
        case .help: return .arrow
        }
    }
}

// MARK: - NSTextInputClient

// The SDK does not annotate NSTextInputClient as @MainActor; AppKit only calls it on the main thread,
// and @preconcurrency turns any violation into a runtime check instead of a silent race.
extension TerminalSurfaceView: @preconcurrency NSTextInputClient {
    public func hasMarkedText() -> Bool { markedText.length > 0 }

    public func markedRange() -> NSRange {
        markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0)
    }

    public func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let attributed as NSAttributedString: markedText = NSMutableAttributedString(attributedString: attributed)
        case let plain as String: markedText = NSMutableAttributedString(string: plain)
        default: return
        }
        guard let surface else { return }
        let s = markedText.string
        s.withCString { ptr in ghostty_surface_preedit(surface, ptr, UInt(strlen(ptr))) }
    }

    public func unmarkText() {
        markedText = NSMutableAttributedString()
        guard let surface else { return }
        ghostty_surface_preedit(surface, nil, 0)
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    public func characterIndex(for point: NSPoint) -> Int { 0 }

    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface, let window else { return .zero }
        var x: Double = 0, y: Double = 0, w: Double = 0, h: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        // libghostty reports a top-left-origin point whose y is the *bottom* of the cursor cell, so
        // in AppKit's bottom-left space that edge is the rect's origin.
        let viewRect = NSRect(x: x, y: bounds.height - y, width: w, height: h)
        let windowRect = convert(viewRect, to: nil)
        return window.convertToScreen(windowRect)
    }

    public func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String
        switch string {
        case let attributed as NSAttributedString: text = attributed.string
        case let plain as String: text = plain
        default: return
        }
        if markedText.length > 0 { unmarkText() }
        if keyTextAccumulator != nil {
            // Inside keyDown: attach to the key event instead of sending separately.
            keyTextAccumulator?.append(text)
            return
        }
        // Outside keyDown (e.g. IME candidate chosen with the mouse): send as plain text.
        guard let surface else { return }
        text.withCString { ptr in ghostty_surface_text(surface, ptr, UInt(strlen(ptr))) }
    }
}
