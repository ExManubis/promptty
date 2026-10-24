import LocalAuthentication
import SwiftUI

/// The app is a shell on your Mac, so a real Mac's tabs ask for Face ID (or the passcode) first:
/// at launch and each time the app comes back. On by default; the demo never asks.
struct LockScreen: View {
    let unlock: () -> Void
    @State private var failed: String?

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "lock.fill")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.secondary)
            Text("PrompTTY is locked")
                .font(.system(size: 24, weight: .semibold))
            Text(failed ?? "It's a shell on your Mac.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                authenticate()
            } label: {
                Label("Unlock", systemImage: "faceid")
                    .font(.system(size: 17, weight: .semibold))
                    .padding(.horizontal, 20)
                    .frame(height: 48)
            }
            .buttonStyle(.plain)
            .glassControl(Capsule())
            .accessibilityIdentifier("unlock")
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Backdrop())
        .onAppear(perform: authenticate)
    }

    private func authenticate() {
        let context = LAContext()
        var error: NSError?
        // Without Face ID or a passcode set up there is nothing to ask for.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return unlock() }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Show your Mac's terminals") { success, error in
            Task { @MainActor in
                if success { unlock() } else { failed = error?.localizedDescription }
            }
        }
    }
}

/// The phone's settings: Face ID, and the Macs added.
struct PhoneSettings: View {
    @Bindable var model: PhoneModel
    @AppStorage("requireFaceID") private var requireFaceID = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Require Face ID", isOn: $requireFaceID)
                } footer: {
                    Text("Before showing a Mac's tabs, when the app opens or comes back. The demo never asks.")
                }
                Section("Macs") {
                    ForEach(model.macs.filter { !$0.isDemo }) { mac in
                        LabeledContent(mac.name, value: mac.host)
                    }
                    .onDelete { offsets in
                        let real = model.macs.filter { !$0.isDemo }
                        for index in offsets { model.removeMac(real[index].id) }
                    }
                    if !model.macs.contains(where: { !$0.isDemo }) {
                        Text("Add a Mac from the Mac switcher, by its Tailscale name.").foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar { Button("Done") { dismiss() } }
        }
        .preferredColorScheme(.dark)
    }
}
