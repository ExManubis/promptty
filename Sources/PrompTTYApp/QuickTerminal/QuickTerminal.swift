import AppKit
import Carbon.HIToolbox
import GhosttyBridge
import Preferences

/// The quick terminal: a terminal that drops down from the top of the screen the pointer is on,
/// over any app, on a global shortcut (⌥↩ by default), and goes again on the same shortcut or
/// when another window takes the keys. Its shell lives on between shows; it is a plain terminal
/// (no input bar or tabs), kept apart from the workspace and the session.
@MainActor
final class QuickTerminal: NSObject, NSWindowDelegate {
    /// Its surfaces carry this token, so the coordinator knows their actions are not a pane's.
    struct Token: Hashable {}

    private let runtime: GhosttyRuntime
    private var panel: QuickTerminalPanel?
    private var surface: TerminalSurfaceView?
    private var hotKey: GlobalHotKey?
    /// The app in front before the quick terminal came down, given the keys back when it goes.
    private var previousApp: NSRunningApplication?
    private var animating = false

    /// The share of the screen's height it takes.
    static let heightFraction: CGFloat = 0.42

    init(runtime: GhosttyRuntime) {
        self.runtime = runtime
    }

    /// Registers the global shortcut, or none when the quick terminal is off.
    func apply(_ settings: Settings, shortcut: Shortcut) {
        hotKey = nil
        guard settings.quickTerminal else {
            hide(animated: false)
            return
        }
        hotKey = GlobalHotKey(shortcut) { [weak self] in self?.toggle() }
    }

    var isShown: Bool { panel?.isVisible == true }

    #if DEBUG
    /// For the debug driver: whether it is shown, has the keys, and where.
    var debugState: String {
        guard let panel else { return "none" }
        return "shown=\(panel.isVisible) key=\(panel.isKeyWindow) alpha=\(panel.alphaValue) frame=\(NSStringFromRect(panel.frame)) surface=\(surface != nil)"
    }
    #endif

    @objc func toggle(_ sender: Any? = nil) {
        guard !animating else { return }
        if isShown, panel?.isKeyWindow == true { hide() } else { show() }
    }

    func show() {
        let panel = panel ?? makePanel()
        let surface = surface ?? makeSurface(in: panel)
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame
        let height = (visible.height * Self.heightFraction).rounded()
        let width = min(visible.width - 32, max(720, visible.width * 0.7)).rounded()
        let shown = NSRect(x: (visible.midX - width / 2).rounded(), y: visible.maxY - height, width: width, height: height)
        if !NSApp.isActive {
            previousApp = NSWorkspace.shared.frontmostApplication
        }
        NSApp.activate()
        if !panel.isVisible {
            panel.setFrame(shown, display: false)
            panel.makeKeyAndOrderFront(nil)
            slide(panel, in: true) {}
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
        panel.makeFirstResponder(surface)
    }

    func hide(animated: Bool = true) {
        guard let panel, panel.isVisible else { return }
        let done: @MainActor () -> Void = { [weak self] in
            panel.orderOut(nil)
            // Back to the app the user came from, unless they went to another PrompTTY window.
            if let previous = self?.previousApp, previous != NSRunningApplication.current,
               NSApp.keyWindow == nil || NSApp.keyWindow === panel {
                previous.activate()
            }
            self?.previousApp = nil
        }
        guard animated else { return done() }
        slide(panel, in: false, completion: done)
    }

    /// Slides the panel's content down from above the screen's top (`in`), or back up, in Core
    /// Animation: window frame animations stall while the app is not frontmost.
    private func slide(_ panel: NSPanel, in coming: Bool, completion: @escaping @MainActor () -> Void) {
        guard let layer = panel.contentView?.layer, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            return completion()
        }
        animating = true
        let offset = panel.frame.height
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                self?.animating = false
                completion()
                // Ordered out by now: back in place for the next show.
                if !coming { layer.removeAnimation(forKey: "slide") }
            }
        }
        let slide = CABasicAnimation(keyPath: "transform.translation.y")
        slide.fromValue = coming ? offset : 0
        slide.toValue = coming ? 0 : offset
        slide.duration = coming ? 0.2 : 0.16
        slide.timingFunction = CAMediaTimingFunction(name: coming ? .easeOut : .easeIn)
        // Held at the end until the panel is ordered out.
        slide.fillMode = .forwards
        slide.isRemovedOnCompletion = coming
        layer.add(slide, forKey: "slide")
        CATransaction.commit()
    }

    // MARK: Panel and terminal

    private func makePanel() -> QuickTerminalPanel {
        let panel = QuickTerminalPanel(contentRect: NSRect(x: 0, y: 0, width: 900, height: 400),
                                       styleMask: [.borderless, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.title = "Quick Terminal"
        let content = NSVisualEffectView()
        content.material = .hudWindow
        content.blendingMode = .behindWindow
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 12
        content.layer?.cornerCurve = .continuous
        content.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        content.layer?.masksToBounds = true
        panel.contentView = content
        self.panel = panel
        return panel
    }

    private func makeSurface(in panel: NSPanel) -> TerminalSurfaceView {
        let view = TerminalSurfaceView(runtime: runtime, configuration: TerminalSurfaceConfiguration(workingDirectory: NSHomeDirectory()))
        view.token = Token()
        view.autoresizingMask = [.width, .height]
        if let content = panel.contentView {
            view.frame = content.bounds.insetBy(dx: 6, dy: 6)
            content.addSubview(view)
        }
        surface = view
        return view
    }

    /// Its shell exited (or asked to close): a fresh one comes next time, the panel goes.
    func surfaceClosed() {
        hide()
        surface?.removeFromSuperview()
        surface?.teardown()
        surface = nil
    }

    // MARK: NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        // Another window (any app's) took the keys: out of the way, as a drop-down does.
        guard !animating else { return }
        hide()
    }
}

/// A borderless panel that can take the keys.
final class QuickTerminalPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// A system-wide shortcut, registered with Carbon (no Accessibility permission needed).
@MainActor
final class GlobalHotKey {
    nonisolated(unsafe) private var ref: EventHotKeyRef?
    nonisolated(unsafe) private var handler: EventHandlerRef?
    private let action: () -> Void
    private static var nextID: UInt32 = 1

    init?(_ shortcut: Shortcut, action: @escaping () -> Void) {
        guard let code = KeyboardLayout.keyCode(for: shortcut.key) else { return nil }
        self.action = action
        var modifiers: UInt32 = 0
        if shortcut.modifiers.contains(.command) { modifiers |= UInt32(cmdKey) }
        if shortcut.modifiers.contains(.option) { modifiers |= UInt32(optionKey) }
        if shortcut.modifiers.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if shortcut.modifiers.contains(.control) { modifiers |= UInt32(controlKey) }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let id = EventHotKeyID(signature: OSType(0x5054_5459), id: Self.nextID) // 'PTTY'
        Self.nextID += 1
        let me = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, data in
            guard let event, let data else { return OSStatus(eventNotHandledErr) }
            var pressed = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(data).takeUnretainedValue()
            MainActor.assumeIsolated { hotKey.fire(pressed.id) }
            return noErr
        }, 1, &spec, me, &handler)
        guard installed == noErr,
              RegisterEventHotKey(UInt32(code), modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr else {
            if let handler { RemoveEventHandler(handler) }
            return nil
        }
        registeredID = id.id
    }

    private var registeredID: UInt32 = 0

    private func fire(_ id: UInt32) {
        guard id == registeredID else { return }
        action()
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}
