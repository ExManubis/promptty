/// Who an action is about. `TerminalSurfaceView` is defined in TerminalSurfaceView.swift (Task 5);
/// until that file exists, add a temporary `public final class TerminalSurfaceView {}` stub at the
/// bottom of this file and delete the stub in Task 5.
public enum GhosttyActionTarget {
    case app
    case surface(TerminalSurfaceView)
}

/// Implemented by the app. Return `true` only when the action was actually performed.
@MainActor
public protocol GhosttyActionSink: AnyObject {
    func handle(_ action: GhosttyAction, target: GhosttyActionTarget) -> Bool
}

@MainActor public final class TerminalSurfaceView {}
