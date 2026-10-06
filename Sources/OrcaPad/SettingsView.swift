import OrcaBridge
import SwiftUI

/// Machine / filament / process pickers over the client preset store. The
/// store is the single owner of engine selection and persistence.
struct SettingsView: View {
    let presets: PresetStore

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                switch presets.phase {
                case .idle, .loading:
                    Text("loading presets…")
                        .foregroundStyle(.secondary)
                case .failed(let failure):
                    VStack(alignment: .leading, spacing: 10) {
                        Text("presets failed: \(failure.localizedDescription)")
                            .foregroundStyle(.red)
                        Button("Retry") {
                            Task { await presets.load() }
                        }
                    }
                case .ready:
                    presetSections
                }
            }
            .navigationTitle("Presets")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var presetSections: some View {
        presetSection(kind: .machine, title: "Machine", symbol: "printer")
        presetSection(kind: .filament, title: "Filament", symbol: "filament")
        presetSection(
            kind: .process,
            title: "Process",
            symbol: "slider.horizontal.3"
        )
    }

    private func presetSection(
        kind: PresetKind,
        title: String,
        symbol: String
    ) -> some View {
        Section(title) {
            NavigationLink {
                PickerList(
                    kind: kind,
                    names: presets.names(for: kind),
                    selected: presets.selectedName(for: kind)
                ) { name in
                    Task { await presets.select(kind: kind, name: name) }
                }
            } label: {
                row(
                    symbol,
                    presets.selectedName(for: kind).isEmpty
                        ? "not selected"
                        : presets.selectedName(for: kind)
                )
            }
        }
    }

    private func row(_ symbol: String, _ value: String) -> some View {
        Label(value, systemImage: symbol)
            .lineLimit(1)
    }
}

private struct PickerList: View {
    let kind: PresetKind
    let names: [String]
    let selected: String
    let onSelect: (String) -> Void

    @State private var search = ""
    @Environment(\.dismiss) private var dismiss

    private var filtered: [String] {
        search.isEmpty
            ? names
            : names.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        List(filtered, id: \.self) { name in
            Button {
                onSelect(name)
                dismiss()
            } label: {
                HStack {
                    Text(name)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    Spacer()
                    if name == selected {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.tint)
                    }
                }
            }
        }
        .searchable(
            text: $search,
            placement: .navigationBarDrawer(displayMode: .always)
        )
        .navigationTitle(title)
    }

    private var title: String {
        switch kind {
        case .machine: return "Machine"
        case .filament: return "Filament"
        case .process: return "Process"
        }
    }
}
