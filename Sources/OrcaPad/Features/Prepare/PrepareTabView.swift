import OrcaBridge
import SwiftUI

/// Prepare tab (desktop parity): printer and filament presets with their
/// settings screens, the process preset with its desktop pages inline
/// (Quality / Strength / Speed / Support / Multimaterial / Others), a
/// Simple/Advanced/Expert filter, and the Slice action in the toolbar.
struct PrepareTabView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var modeFilter: SettingsModeFilter = .simple
    @State private var search = ""
    @State private var showAllProcesses = false

    private var presets: PresetStore { environment.presets }

    var body: some View {
        NavigationStack {
            Group {
                switch presets.phase {
                case .idle, .loading:
                    ProgressView("loading presets…")
                case .failed(let failure):
                    ContentUnavailableView {
                        Label("Presets unavailable", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(failure.localizedDescription)
                    } actions: {
                        Button("Retry") { Task { await presets.load() } }
                    }
                case .ready:
                    editor
                }
            }
            .navigationTitle("Prepare")
            .toolbar {
                ToolbarItem(placement: .primaryAction) { sliceButton }
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic))
        }
    }

    // MARK: Slice action (desktop parity: top toolbar)

    private var sliceButton: some View {
        Button {
            Task {
                await environment.slicing.run(
                    document: environment.document,
                    presets: presets
                )
            }
        } label: {
            if let progress = environment.slicing.progress {
                ProgressView(value: Double(progress.percent), total: 100)
                    .frame(width: 72)
            } else {
                Label("Slice", systemImage: "scissors")
                    .font(.headline)
            }
        }
        .disabled(
            environment.document.scene?.objects.isEmpty != false ||
                environment.document.isBusy ||
                presets.isSelecting
        )
    }

    // MARK: Editor

    private var editor: some View {
        List {
            Section {
                Picker("Mode", selection: $modeFilter) {
                    ForEach(SettingsModeFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
            }

            printerSection
            filamentSection
            processSection
            SettingsPagesSections(kind: .process, filter: modeFilter, search: search)

            Section {
                NavigationLink {
                    ResolvedConfigView(presets: presets)
                } label: {
                    Label("Resolved configuration", systemImage: "doc.text.magnifyingglass")
                }
            } footer: {
                sliceFooter
            }
        }
    }

    private var printerSection: some View {
        Section("Printer") {
            NavigationLink {
                GroupedPickerList(
                    title: "Printer",
                    entries: presets.machines,
                    selected: presets.selection.machine,
                    vendorPlaceholder: "Other manufacturers"
                ) { name in
                    Task { await presets.select(kind: .machine, name: name) }
                }
            } label: {
                presetLabel(presets.selection.machine, symbol: "printer")
            }
            NavigationLink {
                SettingsPagesScreen(kind: .machine, title: "Printer settings")
            } label: {
                settingsLabel("Printer settings", kind: .machine)
            }
            if let bedType = presets.bedType {
                PlateTypeRow(state: bedType) { value in
                    Task { await presets.setBedType(value) }
                }
                .disabled(presets.isSelecting)
            }
            if let volume = presets.printVolume {
                LabeledContent("Print volume") {
                    Text(String(format: "%.0f × %.0f mm", volume.width, volume.depth))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var filamentSection: some View {
        Section("Filament") {
            NavigationLink {
                GroupedPickerList(
                    title: "Filament",
                    entries: presets.filaments,
                    selected: presets.selection.filament,
                    vendorPlaceholder: "Generic filaments"
                ) { name in
                    Task { await presets.select(kind: .filament, name: name) }
                }
            } label: {
                presetLabel(presets.selection.filament, symbol: "circle.dotted.circle")
            }
            NavigationLink {
                SettingsPagesScreen(kind: .filament, title: "Filament settings")
            } label: {
                settingsLabel("Filament settings", kind: .filament)
            }
        }
    }

    private var processSection: some View {
        Section {
            NavigationLink {
                GroupedPickerList(
                    title: "Process",
                    entries: showAllProcesses
                        ? presets.processes
                        : presets.processes.filter(\.isCompatible),
                    selected: presets.selection.process,
                    vendorPlaceholder: "Generic processes"
                ) { name in
                    Task { await presets.select(kind: .process, name: name) }
                }
            } label: {
                presetLabel(presets.selection.process, symbol: "slider.horizontal.3")
            }
            Toggle("Show incompatible processes", isOn: $showAllProcesses)
                .font(.caption)
            let modified = presets.modifiedKeys(in: .process).count
            if modified > 0 {
                Button("Reset \(modified) modified process settings") {
                    Task { await presets.resetKind(.process) }
                }
                .font(.caption)
            }
        } header: {
            Text("Process")
        }
    }

    private func presetLabel(_ name: String, symbol: String) -> some View {
        Label(name.isEmpty ? "Not selected" : name, systemImage: symbol)
            .lineLimit(1)
    }

    private func settingsLabel(_ title: String, kind: PresetKind) -> some View {
        let modified = presets.modifiedKeys(in: kind).count
        return HStack {
            Label(title, systemImage: "gearshape")
            Spacer()
            if modified > 0 {
                Text("\(modified) modified")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    @ViewBuilder
    private var sliceFooter: some View {
        if let failure = environment.slicing.lastFailure {
            Text("Last slice failed: \(failure.localizedDescription)")
                .foregroundStyle(.red)
        } else if let outcome = environment.slicing.lastOutcome {
            Text(
                "G-code ready — \(outcome.outputURL.lastPathComponent) · ~" +
                    "\(Int(outcome.result.timeEstimateSeconds / 60)) min"
            )
        }
    }
}

/// Desktop sidebar "Plate type" (project `curr_bed_type`): bed temperatures
/// are chosen by it. Machines without selectable plates show the engine's
/// fixed default read-only. Labels come from the engine schema.
private struct PlateTypeRow: View {
    let state: BedTypeState
    let onSelect: (Int32) -> Void

    var body: some View {
        switch ConfigSchema.index {
        case .failure(let failure):
            Label(failure.localizedDescription, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        case .success(let index):
            let labels = index["curr_bed_type"]?.enumLabels ?? []
            if labels.count != Int(state.count) - 1 {
                Label(
                    "Plate type: schema has \(labels.count) labels, engine has \(state.count - 1) types",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.red)
            } else if state.selectable {
                Picker(selection: Binding(
                    get: { state.current },
                    set: { onSelect($0) }
                )) {
                    ForEach(state.supported, id: \.self) { value in
                        Text(label(value, labels)).tag(value)
                    }
                } label: {
                    Label("Plate type", systemImage: "square.grid.3x3.square")
                }
            } else {
                LabeledContent {
                    Text(label(state.current, labels)).foregroundStyle(.secondary)
                } label: {
                    Label("Plate type", systemImage: "square.grid.3x3.square")
                }
            }
        }
    }

    /// Engine BedType v (1-based) ↔ schema enum index v-1 (count verified).
    private func label(_ value: Int32, _ labels: [String]) -> String {
        labels[Int(value) - 1]
    }
}
