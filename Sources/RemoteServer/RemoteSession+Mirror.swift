import Foundation
import RemoteProtocol

extension RemoteSession {
    /// A mirror request (`attach`, `input`, `control.take`, …) as the action for the hub, or its
    /// params' error; nil for any other method.
    static func mirrorAction(_ request: RemoteRequest) -> Action? {
        let call: MirrorCall?, takes: String
        switch request.method {
        case RemoteProtocol.Method.attach:
            call = (try? request.params(as: AttachParams.self)).map(MirrorCall.attach)
            takes = "a pane, and where to resume or how much scrollback"
        case RemoteProtocol.Method.detach:
            call = (try? request.params(as: PaneParams.self)).map(MirrorCall.detach)
            takes = "a pane"
        case RemoteProtocol.Method.input:
            call = (try? request.params(as: InputParams.self)).map(MirrorCall.input)
            takes = "a pane and its text, paste or key"
        case RemoteProtocol.Method.takeControl:
            call = (try? request.params(as: ControlTake.self)).map(MirrorCall.takeControl)
            takes = "a pane and the client's columns and rows"
        case RemoteProtocol.Method.resize:
            call = (try? request.params(as: ControlTake.self)).map(MirrorCall.resize)
            takes = "a pane and the client's columns and rows"
        case RemoteProtocol.Method.releaseControl:
            call = (try? request.params(as: PaneParams.self)).map(MirrorCall.releaseControl)
            takes = "a pane"
        default:
            return nil
        }
        guard let call else {
            return .send(.response(.error(RemoteError(code: RemoteError.invalidParams, message: "\(request.method) takes \(takes)"), id: request.id)))
        }
        return .mirror(call, id: request.id)
    }
}
