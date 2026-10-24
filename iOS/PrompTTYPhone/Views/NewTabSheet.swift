import RemoteProtocol
import SwiftUI

/// Opens a tab on the Mac for work on the phone, at the phone's size: a shell in a folder (⌘J's
/// most used), an ssh host from the Mac's config, or a saved command. It stays open on the Mac when
/// the phone goes, so a long `brew upgrade` runs on.
struct NewTabSheet: View {
    let model: PhoneModel
    @State private var places: RemotePlaces?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let places {
                    Section("Shell") {
                        row("Home", symbol: "house", detail: "~") { open(folder: places.home) }
                        ForEach(places.folders.filter { $0 != places.home }, id: \.self) { folder in
                            row(folder.split(separator: "/").last.map(String.init) ?? folder, symbol: "folder",
                                detail: RemoteMapping.abbreviate(folder)) { open(folder: folder) }
                        }
                    }
                    if !places.hosts.isEmpty {
                        Section("SSH") {
                            ForEach(places.hosts, id: \.self) { host in
                                row(host, symbol: "network") { open(command: "ssh \(Self.quoted(host))") }
                            }
                        }
                    }
                    if !places.commands.isEmpty {
                        Section("Saved commands") {
                            ForEach(places.commands, id: \.name) { saved in
                                row(saved.name, symbol: "bookmark", detail: saved.command) { open(command: saved.command) }
                            }
                        }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("New Tab")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Cancel") { dismiss() } }
        }
        .preferredColorScheme(.dark)
        .task { places = await model.connection?.places() }
    }

    private func row(_ title: String, symbol: String, detail: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).frame(width: 22).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    if let detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
        }
    }

    private func open(folder: String? = nil, command: String? = nil) {
        model.connection?.openTab(folder: folder ?? places?.home, command: command)
        dismiss()
    }

    /// Shell-safe: a host from a config file is not trusted to be a plain word.
    static func quoted(_ word: String) -> String {
        word.allSatisfy { $0.isLetter || $0.isNumber || "-_.@:".contains($0) } ? word : "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
