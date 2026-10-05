import SwiftUI
import Engine

/// Machine / filament / process pickers over the engine's system preset
/// bundle. Selection persists (@AppStorage) and is pushed into the engine
/// (PresetBundle) on every change — slicing reads it from there.
struct SettingsView: View {
    let presets: EnginePresets
    let onError: (String) -> Void

    @AppStorage("preset.machine") private var machine = ""
    @AppStorage("preset.filament") private var filament = ""
    @AppStorage("preset.process") private var process = ""

    @State private var machines: [String] = []
    @State private var filaments: [String] = []
    @State private var processes: [String] = []
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            List {
                if !loaded {
                    Text("loading presets…")
                        .foregroundStyle(.secondary)
                } else {
                    Section("Machine") {
                        NavigationLink { PickerList(kind: .machine, names: machines, selected: $machine, onSelect: applySelection) } label: {
                            row("printer", machine.isEmpty ? "not selected" : machine)
                        }
                    }
                    Section("Filament") {
                        NavigationLink { PickerList(kind: .filament, names: filaments, selected: $filament, onSelect: applySelection) } label: {
                            row("filament", filament.isEmpty ? "not selected" : filament)
                        }
                    }
                    Section("Process") {
                        NavigationLink { PickerList(kind: .process, names: processes, selected: $process, onSelect: applySelection) } label: {
                            row("slider.horizontal.3", process.isEmpty ? "not selected" : process)
                        }
                    }
                }
            }
            .navigationTitle("Presets")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear { loadIfNeeded() }
    }

    @Environment(\.dismiss) private var dismiss

    private func row(_ symbol: String, _ value: String) -> some View {
        HStack {
            Label(value, systemImage: symbol)
                .lineLimit(1)
        }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        switch presets.names(kind: .machine) {
        case .failure(let err): onError("presets (machines) FAILED: \(err.message)")
        case .success(let list): machines = list
        }
        switch presets.names(kind: .filament) {
        case .failure(let err): onError("presets (filaments) FAILED: \(err.message)")
        case .success(let list): filaments = list
        }
        switch presets.names(kind: .process) {
        case .failure(let err): onError("presets (processes) FAILED: \(err.message)")
        case .success(let list): processes = list
        }
        // First run: adopt the bundle's defaults so slicing always has a
        // complete selection.
        if machine.isEmpty, case .success(let m) = presets.current(kind: .machine) { machine = m }
        if filament.isEmpty, case .success(let f) = presets.current(kind: .filament) { filament = f }
        if process.isEmpty, case .success(let p) = presets.current(kind: .process) { process = p }
        applySelection()
    }

    private func applySelection() {
        guard !machine.isEmpty, !filament.isEmpty, !process.isEmpty else { return }
        switch presets.select(machine: machine, filament: filament, process: process) {
        case .failure(let err): onError("preset select FAILED: \(err.message)")
        case .success: break
        }
    }
}

/// Searchable single-choice list for one preset kind.
private struct PickerList: View {
    let kind: PresetKind
    let names: [String]
    @Binding var selected: String
    let onSelect: () -> Void

    @State private var search = ""
    @Environment(\.dismiss) private var dismiss

    private var filtered: [String] {
        search.isEmpty ? names : names.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        List(filtered, id: \.self) { name in
            Button {
                selected = name
                onSelect()
                dismiss()
            } label: {
                HStack {
                    Text(name).lineLimit(1).foregroundStyle(.primary)
                    Spacer()
                    if name == selected {
                        Image(systemName: "checkmark").foregroundStyle(.tint)
                    }
                }
            }
        }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always))
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
