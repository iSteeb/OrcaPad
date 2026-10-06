import OrcaBridge
import SwiftUI

/// Machine / filament / process pickers over the client preset store.
/// Machines and filaments are grouped by manufacturer (engine vendor);
/// processes default to the engine's compatibility flags for the selected
/// machine. The store remains the single owner of selection + persistence.
struct SettingsView: View {
    let presets: PresetStore

    @Environment(\.dismiss) private var dismiss
    @State private var showIncompatibleProcesses = false

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
        machineSection
        filamentSection
        processSection
    }

    private func entryRow(_ symbol: String, _ value: String) -> some View {
        Label(value, systemImage: symbol)
            .lineLimit(1)
    }

    // MARK: Machines (grouped by manufacturer)

    private var machineSection: some View {
        Section("Machine") {
            NavigationLink {
                GroupedPickerList(
                    title: "Machine",
                    entries: presets.machines,
                    selected: presets.selection.machine,
                    vendorPlaceholder: "Other manufacturers"
                ) { name in
                    Task {
                        await presets.select(kind: .machine, name: name)
                    }
                }
            } label: {
                let name = presets.selection.machine
                entryRow("printer", name.isEmpty ? "not selected" : name)
            }
        }
    }

    // MARK: Filaments (grouped by manufacturer)

    private var filamentSection: some View {
        Section("Filament") {
            NavigationLink {
                GroupedPickerList(
                    title: "Filament",
                    entries: presets.filaments,
                    selected: presets.selection.filament,
                    vendorPlaceholder: "Generic filaments"
                ) { name in
                    Task {
                        await presets.select(kind: .filament, name: name)
                    }
                }
            } label: {
                let name = presets.selection.filament
                entryRow("filament", name.isEmpty ? "not selected" : name)
            }
        }
    }

    // MARK: Processes (filtered by engine machine compatibility)

    private var processSection: some View {
        Section {
            NavigationLink {
                GroupedPickerList(
                    title: "Process",
                    entries: visibleProcesses,
                    selected: presets.selection.process,
                    vendorPlaceholder: "Generic processes"
                ) { name in
                    Task {
                        await presets.select(kind: .process, name: name)
                    }
                }
            } label: {
                let name = presets.selection.process
                entryRow("slider.horizontal.3", name.isEmpty ? "not selected" : name)
            }
        } header: {
            Text("Process")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if !showIncompatibleProcesses {
                    Text("Showing processes compatible with the selected machine.")
                }
                Toggle("Show all processes", isOn: $showIncompatibleProcesses)
                    .font(.caption)
            }
        }
    }

    private var visibleProcesses: [PresetEntry] {
        showIncompatibleProcesses
            ? presets.processes
            : presets.processes.filter(\.isCompatible)
    }
}

/// Searchable single-choice list grouped by manufacturer (engine vendor).
private struct GroupedPickerList: View {
    let title: String
    let entries: [PresetEntry]
    let selected: String
    let vendorPlaceholder: String
    let onSelect: (String) -> Void

    @State private var search = ""
    @Environment(\.dismiss) private var dismiss

    private struct Group: Identifiable {
        let vendor: String
        let entries: [PresetEntry]
        var id: String { vendor }
    }

    private var groups: [Group] {
        let filtered = search.isEmpty
            ? entries
            : entries.filter {
                $0.name.localizedCaseInsensitiveContains(search) ||
                    $0.vendor.localizedCaseInsensitiveContains(search)
            }
        let byVendor = Dictionary(grouping: filtered) { entry in
            entry.vendor.isEmpty ? vendorPlaceholder : entry.vendor
        }
        return byVendor
            .map { Group(vendor: $0.key, entries: $0.value) }
            .sorted { $0.vendor < $1.vendor }
    }

    var body: some View {
        List {
            ForEach(groups) { group in
                Section(group.vendor) {
                    ForEach(group.entries, id: \.name) { entry in
                        Button {
                            onSelect(entry.name)
                            dismiss()
                        } label: {
                            HStack {
                                Text(entry.name)
                                    .lineLimit(1)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if entry.name == selected {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                } else if !entry.isCompatible {
                                    Image(systemName: "exclamationmark.triangle")
                                        .foregroundStyle(.secondary)
                                        .font(.caption)
                                }
                            }
                        }
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
}
