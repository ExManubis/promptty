import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WorkspaceModel

/// In-app drag payloads. All are visible to this process only, so dragging text or files from
/// other apps never lights up pane, tab or project drop targets.
enum DragPayload {
    static let pane = UTType(exportedAs: "dev.promptty.pane")
    static let tab = UTType(exportedAs: "dev.promptty.tab")
    /// A sidebar project's header, dragged to reorder the projects.
    static let project = UTType(exportedAs: "dev.promptty.project")

    static func provider(_ type: UTType, id: UUID) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .ownProcess) { completion in
            completion(Data(id.uuidString.utf8), nil)
            return nil
        }
        return provider
    }

    /// Loads the first UUID of `type` and calls `completion` on the main actor.
    static func loadID(_ type: UTType, from providers: [NSItemProvider], completion: @escaping @MainActor (UUID) -> Void) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(type.identifier) }) else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
            guard let data, let id = UUID(uuidString: String(decoding: data, as: UTF8.self)) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(id) }
            }
        }
        return true
    }
}

/// The nearest edge of `size` to `point`, measured relative to the size so tall and wide panes
/// behave the same.
func nearestEdge(of size: CGSize, to point: CGPoint) -> PaneEdge {
    guard size.width > 0, size.height > 0 else { return .right }
    let x = point.x / size.width
    let y = point.y / size.height
    let distances: [(PaneEdge, CGFloat)] = [(.left, x), (.right, 1 - x), (.top, y), (.bottom, 1 - y)]
    return distances.min { $0.1 < $1.1 }!.0
}

/// Makes a pane a drop target for other panes: highlights the half it would land on.
struct PaneDropTarget: ViewModifier {
    let pane: Pane
    let chrome: WindowChromeModel
    let actions: ChromeActions
    @State private var size: CGSize = .zero

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .overlay {
                if let target = chrome.dropTarget, target.pane == pane.id {
                    DropHighlight(edge: target.edge)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: chrome.dropTarget?.edge)
            .onDrop(of: [DragPayload.pane], delegate: Delegate(pane: pane.id, size: { size }, chrome: chrome, actions: actions))
    }

    struct Delegate: DropDelegate {
        let pane: PaneID
        let size: () -> CGSize
        let chrome: WindowChromeModel
        let actions: ChromeActions

        func validateDrop(info: DropInfo) -> Bool {
            MainActor.assumeIsolated { chrome.draggingPane != pane }
        }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            MainActor.assumeIsolated {
                guard chrome.draggingPane != pane else {
                    chrome.dropTarget = nil
                    return DropProposal(operation: .forbidden)
                }
                chrome.dropTarget = (pane, nearestEdge(of: size(), to: info.location))
                return DropProposal(operation: .move)
            }
        }

        func dropExited(info: DropInfo) {
            MainActor.assumeIsolated {
                if chrome.dropTarget?.pane == pane { chrome.dropTarget = nil }
            }
        }

        func performDrop(info: DropInfo) -> Bool {
            MainActor.assumeIsolated {
                let edge = chrome.dropTarget?.edge ?? nearestEdge(of: size(), to: info.location)
                chrome.dropTarget = nil
                chrome.draggingPane = nil
                let target = pane
                return DragPayload.loadID(DragPayload.pane, from: info.itemProviders(for: [DragPayload.pane])) { [actions] id in
                    actions.movePane(PaneID(rawValue: id), to: target, edge: edge)
                }
            }
        }
    }
}

/// The half of a pane a dropped pane will take.
struct DropHighlight: View {
    let edge: PaneEdge

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let rect: CGRect = switch edge {
            case .left: CGRect(x: 0, y: 0, width: w / 2, height: h)
            case .right: CGRect(x: w / 2, y: 0, width: w / 2, height: h)
            case .top: CGRect(x: 0, y: 0, width: w, height: h / 2)
            case .bottom: CGRect(x: 0, y: h / 2, width: w, height: h / 2)
            }
            RoundedRectangle(cornerRadius: ChromeMetrics.paneCornerRadius, style: .continuous)
                .fill(Color.accentColor.opacity(0.22))
                .overlay(
                    RoundedRectangle(cornerRadius: ChromeMetrics.paneCornerRadius, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.9), lineWidth: 2)
                )
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
        }
    }
}

private struct WindowChromeKey: EnvironmentKey {
    static let defaultValue: WindowChromeModel? = nil
}

extension EnvironmentValues {
    var windowChrome: WindowChromeModel? {
        get { self[WindowChromeKey.self] }
        set { self[WindowChromeKey.self] = newValue }
    }
}
