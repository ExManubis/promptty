import SwiftUI
import UIKit

/// How the phone is held, which decides the layout.
enum Posture: String, CaseIterable {
    /// A phone-width screen (an iPhone, or an iPhone Duo folded): the sidebar, and a pane over it.
    case compact
    /// An iPhone Duo open: the sidebar beside the pane.
    case flat
    /// An iPhone Duo open part-way, its bottom half on the table like a laptop: the pane above the
    /// hinge, the controls and the keyboard below it.
    case halfFolded

    /// The hinge gives no position, so the fold is taken to be across the middle.
    static func resolve(size: CGSize, hingePartlyOpen: Bool) -> Posture {
        if size.width < 500 { return .compact }
        if hingePartlyOpen, size.height >= size.width * 0.8 { return .halfFolded }
        return .flat
    }
}

/// Debug overrides, from the launch arguments (`-posture flat`, `-canvas 951x669`) or the debug
/// menu: a forced posture, and a canvas the app lays itself out in and is scaled down to fit, so an
/// open iPhone Duo's layouts can be checked in a simulator that stays folded.
enum DebugLayout {
    static var posture: Posture? {
        UserDefaults.standard.string(forKey: "posture").flatMap(Posture.init(rawValue:))
    }

    static var canvas: CGSize? {
        guard let text = UserDefaults.standard.string(forKey: "canvas") else { return nil }
        let parts = text.split(separator: "x").compactMap { Double($0) }
        return parts.count == 2 ? CGSize(width: parts[0], height: parts[1]) : nil
    }
}

/// Reports whether the hinge is partly open. UIKit's `UIHingeInteraction` has no SwiftUI
/// counterpart, and arrived in iOS 27.1: before that the phone is never seen half-folded.
struct HingeReader: UIViewRepresentable {
    @Binding var partlyOpen: Bool

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        if #available(iOS 27.1, *) {
            view.addInteraction(UIHingeInteraction { _, update in
                MainActor.assumeIsolated { partlyOpen = update.hinge?.status == .partiallyOpen }
            })
        }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {}
}
