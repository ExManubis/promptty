import Preferences
import SwiftUI

/// Shows the chosen theme with its swatch; opens a searchable list of every bundled theme.
struct ThemePicker: View {
    let title: String
    @Binding var selection: String
    let swatches: ThemeSwatches
    /// Restricts the list to light or dark themes when set.
    var prefersDark: Bool?

    @State private var presented = false

    var body: some View {
        LabeledContent(title) {
            Button { presented = true } label: {
                HStack(spacing: 8) {
                    ThemeSwatchView(swatch: swatches.swatch(for: selection))
                    Text(selection)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.borderless)
            .popover(isPresented: $presented, arrowEdge: .trailing) {
                ThemeList(selection: $selection, swatches: swatches, prefersDark: prefersDark) {
                    presented = false
                }
            }
            .accessibilityLabel("\(title): \(selection)")
        }
    }
}

struct ThemeList: View {
    @Binding var selection: String
    let swatches: ThemeSwatches
    let prefersDark: Bool?
    let onPick: () -> Void

    @State private var query = ""
    @State private var showAll = false

    private var names: [String] {
        swatches.catalog.names.filter { name in
            if !query.isEmpty, !name.localizedCaseInsensitiveContains(query) { return false }
            guard let prefersDark, !showAll, query.isEmpty else { return true }
            guard let bg = swatches.swatch(for: name)?.background else { return false }
            return (bg.luminance < 0.5) == prefersDark
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search themes", text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary))
            .padding(10)

            if prefersDark != nil, query.isEmpty {
                Toggle(prefersDark == true ? "Show light themes too" : "Show dark themes too", isOn: $showAll)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(names, id: \.self) { name in
                            Button {
                                selection = name
                                onPick()
                            } label: {
                                HStack(spacing: 10) {
                                    ThemeSwatchView(swatch: swatches.swatch(for: name))
                                    Text(name).lineLimit(1)
                                    Spacer()
                                    if name == selection {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(name == selection ? Color.accentColor.opacity(0.14) : .clear)
                                )
                            }
                            .buttonStyle(.plain)
                            .id(name)
                        }
                    }
                    .padding(6)
                }
                .onAppear { proxy.scrollTo(selection, anchor: .center) }
            }
        }
        .frame(width: 320, height: 420)
    }
}
