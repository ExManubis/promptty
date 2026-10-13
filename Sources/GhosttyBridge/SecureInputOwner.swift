import Foundation

/// Decides when macOS secure event input should be on and keeps the calls to turn it on and off
/// balanced. Secure input is a counted global state of the system (and affects other apps while
/// it is on), so exactly one owner holds it: on while the user forces it (`global`) or while a
/// focused pane has asked for it (a program is reading a password), and never while the app is
/// not in front. The system calls are injected, so the logic runs without Carbon.
@MainActor
public final class SecureInputOwner<Key: Hashable> {
    private let enable: () -> Bool
    private let disable: () -> Bool
    private var appActive: Bool

    /// Whether this owner has turned secure input on and not yet off.
    public private(set) var enabled = false
    /// Called when `enabled` changes.
    public var onChange: (() -> Void)?

    /// The user forces secure input on while the app is in front.
    public var global = false { didSet { apply() } }
    private var requested = Set<Key>()
    private var focused = Set<Key>()

    /// `enable` and `disable` return whether the system call succeeded.
    public init(appActive: Bool, enable: @escaping () -> Bool, disable: @escaping () -> Bool) {
        self.appActive = appActive
        self.enable = enable
        self.disable = disable
    }

    /// Whether secure input should be on, ignoring whether the app is in front.
    public var desired: Bool { global || !requested.isDisjoint(with: focused) }

    /// Whether the pane's program has asked for secure input itself.
    public func isRequested(_ key: Key) -> Bool { requested.contains(key) }

    /// Whether the pane shows the lock: forced on, or it has asked for it itself.
    public func isSecure(_ key: Key) -> Bool { global || requested.contains(key) }

    /// A pane's program asks for secure input (a password prompt) or no longer does.
    public func setRequested(_ key: Key, _ on: Bool) {
        if on { requested.insert(key) } else { requested.remove(key) }
        apply()
    }

    /// A pane's terminal has the keyboard or lost it.
    public func setFocused(_ key: Key, _ on: Bool) {
        if on { focused.insert(key) } else { focused.remove(key) }
        apply()
    }

    /// A pane is gone.
    public func remove(_ key: Key) {
        requested.remove(key)
        focused.remove(key)
        apply()
    }

    /// The app came to the front or left it: secure input is given up while it is not in front.
    public func setAppActive(_ active: Bool) {
        appActive = active
        apply()
    }

    /// Gives secure input up for good (at quit).
    public func shutDown() {
        global = false
        requested.removeAll()
        focused.removeAll()
        apply()
    }

    private func apply() {
        let want = appActive && desired
        guard want != enabled else { return }
        // On failure `enabled` stays as it was, so the next change tries again.
        guard (want ? enable() : disable()) else { return }
        enabled = want
        onChange?()
    }
}
