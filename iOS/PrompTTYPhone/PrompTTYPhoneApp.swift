import SwiftUI

/// PrompTTY for iPhone and iPhone Duo: the tabs and panes of PrompTTY on your Mac. For now it runs
/// on demo data (`DemoData`); the connection to a Mac comes with the remote API (PTY-70, PTY-71).
@main
struct PrompTTYPhoneApp: App {
    @State private var model = DemoData.model()

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if let recording = MirrorDebug.recording {
                MirrorDebugScreen(recording: recording)
            } else {
                RootView(model: model)
            }
            #else
            RootView(model: model)
            #endif
        }
    }
}
