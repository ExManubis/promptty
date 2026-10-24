#if os(iOS)
import UIKit
import QuartzCore
import GhosttyKit

/// One libghostty surface on the phone, showing a pane that runs on the Mac: `feed(_:)` puts the
/// pane's output on screen, `onWrite` gets what the terminal sends the program (what is typed,
/// pasted and tapped, and its replies to the program's queries) and `onResize` the grid the
/// phone has room for. Metal draws it, as on the Mac, into a layer libghostty adds to this view.
@MainActor
public final class MirrorSurfaceView: UIView, UIKeyInput {
    /// Bytes for the program, in order. On the main thread.
    public var onWrite: ((Data) -> Void)?
    /// The grid now on screen (columns, rows), each time it changes. On the main thread.
    public var onResize: ((_ columns: Int, _ rows: Int) -> Void)?

    let engine: MirrorEngine
    private let fontSize: Float
    nonisolated(unsafe) private(set) var surface: UnsafeMutableRawPointer?
    /// The surface's userdata: what libghostty's IO thread reaches this view through. Released
    /// after the surface is freed, which stops that thread, so no callback outlives it.
    private let link: MirrorSurfaceLink
    nonisolated(unsafe) private var linkPointer: UnsafeMutableRawPointer

    /// `fontSize` 0 keeps the config's.
    public init(engine: MirrorEngine, fontSize: Float = 0) {
        self.engine = engine
        self.fontSize = fontSize
        link = MirrorSurfaceLink()
        linkPointer = Unmanaged.passRetained(link).toOpaque()
        // Non-zero, so the renderer has a layer size to start with.
        super.init(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        link.view = self
        isMultipleTouchEnabled = false
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
        isAccessibilityElement = true
        accessibilityTraits = .allowsDirectInteraction
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        if let surface { ghostty_surface_free(surface) }
        Unmanaged<MirrorSurfaceLink>.fromOpaque(linkPointer).release()
    }

    // MARK: Output

    /// The program's output, as read from its pty on the Mac.
    public func feed(_ data: Data) {
        guard let surface, !data.isEmpty else { return }
        data.withUnsafeBytes { raw in
            ghostty_surface_feed(surface, raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
        }
    }

    /// The grid on screen now.
    public var gridSize: (columns: Int, rows: Int)? {
        guard let surface else { return nil }
        let size = ghostty_surface_size(surface)
        return (Int(size.columns), Int(size.rows))
    }

    /// One cell, in points.
    public var cellSize: CGSize? {
        guard let surface else { return nil }
        let size = ghostty_surface_size(surface)
        let scale = window?.screen.scale ?? contentScaleFactor
        return CGSize(width: CGFloat(size.cell_width_px) / scale, height: CGFloat(size.cell_height_px) / scale)
    }

    // MARK: Lifecycle

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        createSurfaceIfNeeded()
        setNeedsLayout()
    }

    private func createSurfaceIfNeeded() {
        guard surface == nil else { return }
        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_IOS
        cfg.platform = ghostty_platform_u(ios: ghostty_platform_ios_s(uiview: Unmanaged.passUnretained(self).toOpaque()))
        cfg.userdata = linkPointer
        cfg.scale_factor = Double(window?.screen.scale ?? 3)
        cfg.font_size = fontSize
        cfg.context = GHOSTTY_SURFACE_CONTEXT_TAB
        cfg.io_write_cb = mirrorSurfaceWrite
        cfg.io_resize_cb = mirrorSurfaceResize
        surface = ghostty_surface_new(engine.app, &cfg)
        if let surface { ghostty_surface_set_color_scheme(surface, GHOSTTY_COLOR_SCHEME_DARK) }
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        guard let surface else { return }
        let scale = window?.screen.scale ?? contentScaleFactor
        // libghostty's layer is a sublayer here (a UIView's own layer can't be replaced), so it
        // doesn't follow the view's size by itself; a frame of the wrong size is discarded.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sublayer in layer.sublayers ?? [] {
            sublayer.frame = layer.bounds
            sublayer.contentsScale = scale
        }
        CATransaction.commit()
        ghostty_surface_set_content_scale(surface, Double(scale), Double(scale))
        ghostty_surface_set_size(surface, UInt32(bounds.width * scale), UInt32(bounds.height * scale))
    }

    // MARK: Focus

    public override var canBecomeFirstResponder: Bool { true }

    public override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became, let surface { ghostty_surface_set_focus(surface, true) }
        return became
    }

    public override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, let surface { ghostty_surface_set_focus(surface, false) }
        return resigned
    }

    // MARK: Typing (UIKeyInput, the on-screen keyboard)

    public var hasText: Bool { true }

    public func insertText(_ text: String) {
        for character in text {
            switch character {
            case "\n", "\r": send(.return)
            case "\t": send(.tab)
            default: type(character)
            }
        }
    }

    public func deleteBackward() { send(.backspace) }

    // A terminal takes keys as they are: no autocorrection, capitals or smart punctuation.
    public var autocorrectionType: UITextAutocorrectionType { get { .no } set {} }
    public var autocapitalizationType: UITextAutocapitalizationType { get { .none } set {} }
    public var spellCheckingType: UITextSpellCheckingType { get { .no } set {} }
    public var smartQuotesType: UITextSmartQuotesType { get { .no } set {} }
    public var smartDashesType: UITextSmartDashesType { get { .no } set {} }
    public var smartInsertDeleteType: UITextSmartInsertDeleteType { get { .no } set {} }
    public var keyboardType: UIKeyboardType { get { .asciiCapable } set {} }

    /// A key, pressed and released, as the key row and the hardware keyboard send them.
    public func send(_ key: MirrorKey, modifiers: MirrorModifiers = []) {
        // With Control the text is still the letter, as Ghostty's own app passes it: given the
        // control character, the encoder takes it for an unusual key and sends a CSI u sequence.
        let text: String? = if case .character(let c) = key, !modifiers.contains(.command) {
            String(modifiers.contains(.shift) ? Character(c.uppercased()) : c)
        } else {
            nil
        }
        sendKey(code: MirrorKeyCodes.keyCode(key) ?? 0, modifiers: modifiers, text: text, unshifted: unshifted(key))
    }

    /// Text, as a paste: in brackets when the program asked for them (mode 2004).
    public func paste(_ text: String) {
        guard let surface else { return }
        let bytes = Array(text.utf8)
        bytes.withUnsafeBufferPointer { buffer in
            buffer.baseAddress?.withMemoryRebound(to: CChar.self, capacity: buffer.count) {
                ghostty_surface_text(surface, $0, UInt(buffer.count))
            }
        }
    }

    private func type(_ character: Character) {
        let code = MirrorKeyCodes.keyCode(typing: character)
        let unshifted = code == nil ? 0 : character.unicodeScalars.first.map(\.value) ?? 0
        sendKey(code: code ?? 0, modifiers: [], text: String(character), unshifted: unshifted)
    }

    private func unshifted(_ key: MirrorKey) -> UInt32 {
        guard case .character(let c) = key else { return 0 }
        return Character(c.lowercased()).unicodeScalars.first?.value ?? 0
    }

    private func sendKey(code: UInt32, modifiers: MirrorModifiers, text: String?, unshifted: UInt32) {
        guard let surface else { return }
        var key = ghostty_input_key_s()
        key.mods = modifiers.ghostty
        // Shift made the text; the terminal shouldn't apply it a second time.
        key.consumed_mods = text != nil && modifiers.contains(.shift) && !modifiers.contains(.control)
            ? MirrorModifiers.shift.ghostty : GHOSTTY_MODS_NONE
        key.keycode = code
        key.unshifted_codepoint = unshifted
        key.composing = false
        for action in [GHOSTTY_ACTION_PRESS, GHOSTTY_ACTION_RELEASE] {
            key.action = action
            if let text {
                text.withCString { key.text = $0; _ = ghostty_surface_key(surface, key) }
            } else {
                key.text = nil
                _ = ghostty_surface_key(surface, key)
            }
        }
    }

    // MARK: Hardware keyboard

    public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key, surface != nil, let code = MirrorKeyCodes.keyCode(key.keyCode) else {
                unhandled.insert(press)
                continue
            }
            let modifiers = MirrorModifiers(key.modifierFlags)
            // ⌘ combinations stay the app's.
            if modifiers.contains(.command) { unhandled.insert(press); continue }
            // With Control, the letter (see `send`); named keys (Return, arrows) have no text.
            let characters = modifiers.contains(.control) ? key.charactersIgnoringModifiers : key.characters
            let printable = !characters.isEmpty && characters.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }
            let unshifted = key.charactersIgnoringModifiers.unicodeScalars.first.map(\.value) ?? 0
            sendKey(code: code, modifiers: modifiers, text: printable ? characters : nil, unshifted: printable ? unshifted : 0)
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    // MARK: Touch: taps are clicks (mouse reports when the program asks), a drag scrolls

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        if !isFirstResponder { _ = becomeFirstResponder() }
        guard let surface else { return }
        let point = gesture.location(in: self)
        ghostty_surface_mouse_pos(surface, point.x, point.y, GHOSTTY_MODS_NONE)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
    }

    private var lastPan: CGPoint = .zero

    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        guard let surface else { return }
        let translation = gesture.translation(in: self)
        if gesture.state == .began { lastPan = .zero }
        let dy = translation.y - lastPan.y
        lastPan = translation
        let location = gesture.location(in: self)
        ghostty_surface_mouse_pos(surface, location.x, location.y, GHOSTTY_MODS_NONE)
        // Precise (pixel) scrolling, as a trackpad's.
        ghostty_surface_mouse_scroll(surface, 0, Double(dy), 1)
    }

    // MARK: From the IO thread

    fileprivate func deliver(write data: Data) { onWrite?(data) }
    fileprivate func deliver(columns: Int, rows: Int) { onResize?(columns, rows) }
}

/// What the IO thread's callbacks resolve the surface's userdata to. Only read on the main thread.
@MainActor
final class MirrorSurfaceLink {
    weak var view: MirrorSurfaceView?
}

/// On the surface's IO thread, sometimes with its terminal locked: copy the bytes and return.
private func mirrorSurfaceWrite(_ userdata: UnsafeMutableRawPointer?, _ bytes: UnsafePointer<UInt8>?, _ len: Int) {
    guard let userdata, let bytes, len > 0 else { return }
    let data = Data(bytes: bytes, count: len)
    let link = Unmanaged<MirrorSurfaceLink>.fromOpaque(userdata).takeUnretainedValue()
    DispatchQueue.main.async {
        MainActor.assumeIsolated { link.view?.deliver(write: data) }
    }
}

private func mirrorSurfaceResize(_ userdata: UnsafeMutableRawPointer?, _ columns: UInt16, _ rows: UInt16, _ width: UInt32, _ height: UInt32) {
    guard let userdata else { return }
    let link = Unmanaged<MirrorSurfaceLink>.fromOpaque(userdata).takeUnretainedValue()
    DispatchQueue.main.async {
        MainActor.assumeIsolated { link.view?.deliver(columns: Int(columns), rows: Int(rows)) }
    }
}
#endif
