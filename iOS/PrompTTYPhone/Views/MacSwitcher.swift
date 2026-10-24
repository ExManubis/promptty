import SwiftUI

/// The Macs, as the Mac's command palette lists its entries: dark glass, a search field, a row
/// per Mac with its symbol in a small tile, and adding one by its Tailscale name.
struct MacSwitcher: View {
    @Bindable var model: PhoneModel
    @State private var query = ""
    /// Adding a Mac: its Tailscale name, being typed.
    @State private var adding = false
    @State private var host = ""
    @FocusState private var hostFocused: Bool

    private static let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Switch to a Mac…", text: $query)
                    .font(.system(size: 18))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, 20)
            .frame(height: 56)
            Divider().opacity(0.5)
            VStack(spacing: 2) {
                ForEach(macs) { mac in
                    row(symbol: mac.symbol, title: mac.name, subtitle: subtitle(mac), selected: mac.id == model.macID) {
                        if mac.id == model.macID {
                            Image(systemName: "checkmark").font(.system(size: 14, weight: .semibold))
                        } else if mac.waiting > 0 {
                            Label("\(mac.waiting)", systemImage: "exclamationmark.shield.fill")
                                .foregroundStyle(.orange)
                                .font(.system(size: 13, weight: .medium))
                        }
                    } action: {
                        if mac.id != model.macID { model.selectMac(mac.id) }
                        model.switchingMac = false
                    }
                    .contextMenu {
                        if !mac.isDemo {
                            Button("Remove", systemImage: "trash", role: .destructive) { model.removeMac(mac.id) }
                        }
                    }
                }
                if adding {
                    HStack(spacing: 12) {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 30, height: 30)
                            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        TextField("Tailscale name, as mikkels-studio", text: $host)
                            .font(.system(size: 16))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .focused($hostFocused)
                            .submitLabel(.go)
                            .onSubmit(add)
                            .accessibilityIdentifier("mac-host")
                        Button("Add", action: add)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(MacConnection.url(for: host) == nil)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 46)
                } else {
                    row(symbol: "plus", title: "Add a Mac…", subtitle: "by its Tailscale name", selected: false) { EmptyView() } action: {
                        adding = true
                        hostFocused = true
                    }
                }
            }
            .padding(8)
            Divider().opacity(0.5)
            HStack(spacing: 7) {
                Label("Macs", systemImage: "laptopcomputer")
                Spacer()
                Text("on your tailnet")
            }
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .frame(height: 42)
        }
        // Darker than plain glass, as the Mac's palette, so the list reads over anything.
        .background(Color.black.opacity(0.45), in: Self.shape)
        .glassEffect(.regular, in: Self.shape)
        .environment(\.colorScheme, .dark)
        .accessibilityIdentifier("mac-switcher")
    }

    private func add() {
        guard MacConnection.url(for: host) != nil else { return }
        model.addMac(host: host)
        host = ""
        adding = false
        model.switchingMac = false
    }

    /// Where it is, or how the connection to it is doing.
    private func subtitle(_ mac: PhoneMac) -> String {
        guard mac.id == model.macID, !mac.isDemo else { return mac.isDemo ? mac.status : mac.host }
        return mac.status.isEmpty ? mac.host : mac.status
    }

    private var macs: [PhoneMac] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? model.macs : model.macs.filter { $0.name.lowercased().contains(q) || $0.host.contains(q) }
    }

    private func row<Trailing: View>(symbol: String, title: String, subtitle: String, selected: Bool,
                                     @ViewBuilder trailing: () -> Trailing, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 30, height: 30)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(title)
                    .font(.system(size: 16))
                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                trailing()
            }
            .padding(.horizontal, 10)
            .frame(height: 46)
            .background {
                if selected { RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.12)) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
