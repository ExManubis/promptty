import GhosttyKit

public enum CloseTabMode: Equatable, Sendable { case this, others, right }

public enum GotoTab: Equatable, Sendable {
    /// 1-based, as in Ghostty's `goto_tab:N`.
    case index(Int)
    case previous, next, last
}

public enum MouseShape: Equatable, Sendable {
    case `default`, text, pointer, crosshair, verticalText, notAllowed, grab, grabbing
    case resizeEW, resizeNS, resizeNESW, resizeNWSE, progress, wait, contextMenu, help
    case other
}

/// What libghostty says a link's target is; `text` is a file to show in an editor.
public enum OpenURLKind: Equatable, Sendable { case unknown, text, html }

/// What a program asks of secure keyboard input (a password prompt).
public enum SecureInputRequest: Equatable, Sendable { case on, off, toggle }

public enum ColorKind: Equatable, Sendable {
    case foreground, background, cursor
    case palette(Int)
}

/// A libghostty runtime action, decoded into Swift. Anything the MVP does not implement
/// decodes to `.unhandled`, and the runtime returns `false` for it without consulting the sink.
public enum GhosttyAction: Equatable, Sendable {
    case quit
    case newWindow
    case newTab
    case closeTab(CloseTabMode)
    case closeWindow
    case gotoTab(GotoTab)
    case moveTab(Int)
    case setTitle(String)
    case setTabTitle(String)
    case pwd(String)
    case initialSize(width: UInt32, height: UInt32)
    case cellSize(width: UInt32, height: UInt32)
    case mouseShape(MouseShape)
    case mouseVisibility(visible: Bool)
    case render
    case colorChange(kind: ColorKind, red: UInt8, green: UInt8, blue: UInt8)
    case configChange
    case reloadConfig(soft: Bool)
    case openConfig
    case showChildExited(exitCode: UInt32, runtimeMs: UInt64)
    case desktopNotification(title: String, body: String)
    case ringBell
    /// From shell integration (OSC 133;D): `exitCode` is -1 when the shell gave none.
    case commandFinished(exitCode: Int16, durationNs: UInt64)
    /// The screen moved in the scrollback, or the scrollback grew: rows in all, the first row on
    /// screen, and how many are on screen.
    case scrollbar(total: UInt64, offset: UInt64, length: UInt64)
    /// ⌘-click on a link or a file path in the output.
    case openURL(kind: OpenURLKind, url: String)
    /// The pointer is over a link (its text), or left it (nil).
    case mouseOverLink(String?)
    /// A program in the pane starts or stops reading a secret; `toggle` flips the pane's request.
    case secureInput(SecureInputRequest)
    /// Synthesized from `close_surface_cb`, not a `ghostty_action_tag_e`.
    case closeSurface(processAlive: Bool)
    case unhandled(tag: UInt32)

    public var isImplemented: Bool {
        if case .unhandled = self { return false }
        return true
    }

    init(_ c: ghostty_action_s) {
        switch c.tag {
        case GHOSTTY_ACTION_QUIT: self = .quit
        case GHOSTTY_ACTION_NEW_WINDOW: self = .newWindow
        case GHOSTTY_ACTION_NEW_TAB: self = .newTab
        case GHOSTTY_ACTION_CLOSE_WINDOW: self = .closeWindow
        case GHOSTTY_ACTION_RENDER: self = .render
        case GHOSTTY_ACTION_OPEN_CONFIG: self = .openConfig
        case GHOSTTY_ACTION_CONFIG_CHANGE: self = .configChange
        case GHOSTTY_ACTION_RING_BELL: self = .ringBell
        case GHOSTTY_ACTION_CLOSE_TAB:
            switch c.action.close_tab_mode {
            case GHOSTTY_ACTION_CLOSE_TAB_MODE_OTHER: self = .closeTab(.others)
            case GHOSTTY_ACTION_CLOSE_TAB_MODE_RIGHT: self = .closeTab(.right)
            default: self = .closeTab(.this)
            }
        case GHOSTTY_ACTION_GOTO_TAB:
            switch c.action.goto_tab {
            case GHOSTTY_GOTO_TAB_PREVIOUS: self = .gotoTab(.previous)
            case GHOSTTY_GOTO_TAB_NEXT: self = .gotoTab(.next)
            case GHOSTTY_GOTO_TAB_LAST: self = .gotoTab(.last)
            default: self = .gotoTab(.index(Int(c.action.goto_tab.rawValue)))
            }
        case GHOSTTY_ACTION_MOVE_TAB:
            self = .moveTab(Int(c.action.move_tab.amount))
        case GHOSTTY_ACTION_SET_TITLE:
            self = .setTitle(Self.string(c.action.set_title.title))
        case GHOSTTY_ACTION_SET_TAB_TITLE:
            self = .setTabTitle(Self.string(c.action.set_tab_title.title))
        case GHOSTTY_ACTION_PWD:
            self = .pwd(Self.string(c.action.pwd.pwd))
        case GHOSTTY_ACTION_INITIAL_SIZE:
            self = .initialSize(width: c.action.initial_size.width, height: c.action.initial_size.height)
        case GHOSTTY_ACTION_CELL_SIZE:
            self = .cellSize(width: c.action.cell_size.width, height: c.action.cell_size.height)
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            self = .mouseShape(Self.mouseShape(c.action.mouse_shape))
        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            self = .mouseVisibility(visible: c.action.mouse_visibility == GHOSTTY_MOUSE_VISIBLE)
        case GHOSTTY_ACTION_COLOR_CHANGE:
            let cc = c.action.color_change
            self = .colorChange(kind: Self.colorKind(cc.kind), red: cc.r, green: cc.g, blue: cc.b)
        case GHOSTTY_ACTION_RELOAD_CONFIG:
            self = .reloadConfig(soft: c.action.reload_config.soft)
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            self = .showChildExited(exitCode: c.action.child_exited.exit_code, runtimeMs: c.action.child_exited.timetime_ms)
        case GHOSTTY_ACTION_COMMAND_FINISHED:
            self = .commandFinished(exitCode: c.action.command_finished.exit_code, durationNs: c.action.command_finished.duration)
        case GHOSTTY_ACTION_SCROLLBAR:
            let s = c.action.scrollbar
            self = .scrollbar(total: s.total, offset: s.offset, length: s.len)
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            let n = c.action.desktop_notification
            self = .desktopNotification(title: Self.string(n.title), body: Self.string(n.body))
        case GHOSTTY_ACTION_OPEN_URL:
            let o = c.action.open_url
            let kind: OpenURLKind
            switch o.kind {
            case GHOSTTY_ACTION_OPEN_URL_KIND_TEXT: kind = .text
            case GHOSTTY_ACTION_OPEN_URL_KIND_HTML: kind = .html
            default: kind = .unknown
            }
            self = .openURL(kind: kind, url: Self.string(o.url, length: Int(o.len)) ?? "")
        case GHOSTTY_ACTION_MOUSE_OVER_LINK:
            let l = c.action.mouse_over_link
            self = .mouseOverLink(Self.string(l.url, length: Int(l.len)).flatMap { $0.isEmpty ? nil : $0 })
        case GHOSTTY_ACTION_SECURE_INPUT:
            switch c.action.secure_input {
            case GHOSTTY_SECURE_INPUT_ON: self = .secureInput(.on)
            case GHOSTTY_SECURE_INPUT_OFF: self = .secureInput(.off)
            default: self = .secureInput(.toggle)
            }
        default:
            self = .unhandled(tag: c.tag.rawValue)
        }
    }

    /// Copies a C string before the callback returns; libghostty owns the memory only until then.
    private static func string(_ ptr: UnsafePointer<CChar>?) -> String {
        guard let ptr else { return "" }
        return String(cString: ptr)
    }

    /// Copies `length` bytes, which are not NUL-terminated.
    private static func string(_ ptr: UnsafePointer<CChar>?, length: Int) -> String? {
        guard let ptr, length > 0 else { return nil }
        return ptr.withMemoryRebound(to: UInt8.self, capacity: length) {
            String(decoding: UnsafeBufferPointer(start: $0, count: length), as: UTF8.self)
        }
    }

    private static func mouseShape(_ s: ghostty_action_mouse_shape_e) -> MouseShape {
        switch s {
        case GHOSTTY_MOUSE_SHAPE_DEFAULT: return .default
        case GHOSTTY_MOUSE_SHAPE_TEXT: return .text
        case GHOSTTY_MOUSE_SHAPE_POINTER: return .pointer
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: return .crosshair
        case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT: return .verticalText
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED: return .notAllowed
        case GHOSTTY_MOUSE_SHAPE_GRAB: return .grab
        case GHOSTTY_MOUSE_SHAPE_GRABBING: return .grabbing
        case GHOSTTY_MOUSE_SHAPE_EW_RESIZE, GHOSTTY_MOUSE_SHAPE_COL_RESIZE: return .resizeEW
        case GHOSTTY_MOUSE_SHAPE_NS_RESIZE, GHOSTTY_MOUSE_SHAPE_ROW_RESIZE: return .resizeNS
        case GHOSTTY_MOUSE_SHAPE_NESW_RESIZE: return .resizeNESW
        case GHOSTTY_MOUSE_SHAPE_NWSE_RESIZE: return .resizeNWSE
        case GHOSTTY_MOUSE_SHAPE_PROGRESS: return .progress
        case GHOSTTY_MOUSE_SHAPE_WAIT: return .wait
        case GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU: return .contextMenu
        case GHOSTTY_MOUSE_SHAPE_HELP: return .help
        default: return .other
        }
    }

    private static func colorKind(_ k: ghostty_action_color_kind_e) -> ColorKind {
        switch k {
        case GHOSTTY_ACTION_COLOR_KIND_FOREGROUND: return .foreground
        case GHOSTTY_ACTION_COLOR_KIND_BACKGROUND: return .background
        case GHOSTTY_ACTION_COLOR_KIND_CURSOR: return .cursor
        default: return .palette(Int(k.rawValue))
        }
    }
}
