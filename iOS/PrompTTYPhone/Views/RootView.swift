import SwiftUI

/// The app, laid out for the posture: on a phone-width screen the sidebar with a pane over it; on an
/// open iPhone Duo the sidebar beside the pane; half-folded, the pane above the hinge and the
/// controls below it, like a laptop.
struct RootView: View {
    @Bindable var model: PhoneModel
    @State private var hingePartlyOpen = false
    @AppStorage("requireFaceID") private var requireFaceID = true
    /// Locked until Face ID says so, while a real Mac is shown (`LockScreen`).
    @State private var locked = true
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let canvas = DebugLayout.canvas {
                CanvasPreview(size: canvas) { layout(size: canvas, inCanvas: true) }
            } else {
                GeometryReader { geometry in
                    layout(size: geometry.size, inCanvas: false)
                }
            }
        }
        .background(Backdrop())
        .background(HingeReader(partlyOpen: $hingePartlyOpen))
        .overlay { if model.switchingMac { switcher } }
        .overlay { if locked, requireFaceID, model.isRemote { LockScreen { locked = false } } }
        .onChange(of: scenePhase) { _, phase in if phase == .background { locked = true } }
        .animation(.spring(duration: 0.3, bounce: 0.1), value: model.switchingMac)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func layout(size: CGSize, inCanvas: Bool) -> some View {
        let posture = DebugLayout.posture ?? Posture.resolve(size: size, hingePartlyOpen: hingePartlyOpen)
        switch posture {
        case .compact: compact
        case .flat: flat.padding(.top, inCanvas ? 20 : 0)
        case .halfFolded: halfFolded(height: size.height).padding(.top, inCanvas ? 20 : 0)
        }
    }

    private var compact: some View {
        ZStack {
            if model.paneOpen, let tab = model.tab {
                VStack(spacing: 0) {
                    TabStrip(model: model)
                    PaneColumn(model: model, tab: tab)
                        .padding(.horizontal, PhoneMetrics.inset)
                        .padding(.bottom, 4)
                }
                .transition(.move(edge: .trailing))
            } else {
                SidebarScreen(model: model)
                    .transition(.move(edge: .leading))
            }
        }
        .animation(.spring(duration: 0.35, bounce: 0.08), value: model.paneOpen)
    }

    private var flat: some View {
        HStack(spacing: 0) {
            SidebarScreen(model: model, besidePane: true)
                .frame(width: 300)
            if let tab = model.tab {
                PaneColumn(model: model, tab: tab, wideControls: true)
                    .padding(.vertical, PhoneMetrics.inset)
                    .padding(.trailing, PhoneMetrics.inset)
            }
        }
    }

    private func halfFolded(height: CGFloat) -> some View {
        VStack(spacing: 0) {
            if let tab = model.tab {
                VStack(spacing: 0) {
                    TabStrip(model: model)
                    PaneCard(model: model, tab: tab, pane: tab.focused)
                        .padding(.horizontal, PhoneMetrics.inset)
                        .padding(.bottom, 10)
                }
                .frame(height: height / 2)
                VStack(spacing: PhoneMetrics.inset) {
                    if let request = tab.permission {
                        PermissionBanner(model: model, tab: tab, request: request)
                    }
                    Controls(model: model, tab: tab, wide: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.top, 14)
                .frame(height: height / 2)
                .animation(.easeOut(duration: 0.2), value: tab.permission)
            }
        }
    }

    private var switcher: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { model.switchingMac = false }
            MacSwitcher(model: model)
                .frame(maxWidth: 520)
                .padding(.horizontal, 10)
                .padding(.top, 56)
        }
        .transition(.opacity)
    }
}

/// The app laid out at `size` and scaled to fit the screen, for checking an open iPhone Duo's
/// layouts in a simulator that stays folded (`-canvas 951x669`).
private struct CanvasPreview<Content: View>: View {
    let size: CGSize
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / size.width, geometry.size.height / size.height)
            content()
                .frame(width: size.width, height: size.height)
                .background(Backdrop())
                .clipShape(RoundedRectangle(cornerRadius: 44, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 44, style: .continuous).strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
                .scaleEffect(scale)
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
    }
}
