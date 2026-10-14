// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

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
    /// Desktop UnsavedChangesDialog: a selection waiting for a decision
    /// about the modified preset it would replace.
    @State private var pendingSelection: PendingSelection?

    private struct PendingSelection: Identifiable {
        let kind: PresetKind
        let name: String
        let modified: Int
        var id: String { "\(kind.rawValue)|\(name)" }
    }

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
            .confirmationDialog(
                "Unsaved changes",
                isPresented: Binding(
                    get: { pendingSelection != nil },
                    set: { if !$0 { pendingSelection = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingSelection
            ) { pending in
                Button("Discard \(pending.modified) change(s) and switch", role: .destructive) {
                    Task { await presets.select(kind: pending.kind, name: pending.name) }
                }
                Button("Keep editing", role: .cancel) {}
            } message: { pending in
                Text("The current preset has \(pending.modified) modified setting(s). Save them as a user preset from the preset menu first, or discard them.")
            }
        }
    }

    // MARK: Slice action (desktop parity: top toolbar)

    @ViewBuilder
    private var sliceButton: some View {
        if environment.slicing.isSlicing {
            Button {
                environment.slicing.cancel()
            } label: {
                HStack(spacing: 6) {
                    ProgressView(
                        value: Double(environment.slicing.progress?.percent ?? 0),
                        total: 100
                    )
                    .frame(width: 64)
                    Image(systemName: "xmark.circle.fill")
                }
            }
            .accessibilityLabel("Cancel slicing")
        } else {
            Menu {
                Button {
                    Task {
                        await environment.slicing.run(
                            document: environment.document,
                            presets: presets
                        )
                    }
                } label: {
                    Label("Slice", systemImage: "scissors")
                }
                if environment.document.plates.count > 1 {
                    Button {
                        Task {
                            await environment.slicing.runAll(
                                document: environment.document,
                                presets: presets
                            )
                        }
                    } label: {
                        Label(
                            "Slice All Plates",
                            systemImage: "square.stack.3d.up.fill"
                        )
                    }
                }
            } label: {
                Label("Slice", systemImage: "scissors")
                    .font(.headline)
            } primaryAction: {
                Task {
                    await environment.slicing.run(
                        document: environment.document,
                        presets: presets
                    )
                }
            }
            .disabled(
                environment.document.scene?.objects.isEmpty != false ||
                    environment.document.isBusy ||
                    presets.isSelecting
            )
        }
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
                    requestSelect(.machine, name)
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
                    requestSelect(.filament, name)
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
                    requestSelect(.process, name)
                }
            } label: {
                presetLabel(presets.selection.process, symbol: "slider.horizontal.3")
            }
            Toggle("Show incompatible processes", isOn: $showAllProcesses)
                .font(.caption)
            HStack {
                Text("Process preset")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                PresetActionsMenu(kind: .process)
                    .font(.caption)
            }
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

    /// Selecting another preset discards the edited copy (engine
    /// select_preset), so modified presets ask first — desktop parity.
    private func requestSelect(_ kind: PresetKind, _ name: String) {
        let modified = presets.modifiedKeys(in: kind).count
        let current: String
        switch kind {
        case .machine: current = presets.selection.machine
        case .filament: current = presets.selection.filament
        case .process: current = presets.selection.process
        }
        if modified > 0 && name != current {
            pendingSelection = PendingSelection(kind: kind, name: name, modified: modified)
        } else {
            Task { await presets.select(kind: kind, name: name) }
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
            HStack {
                Text(
                    "G-code ready — \(outcome.outputURL.lastPathComponent) · ~" +
                        "\(Int(outcome.result.timeEstimateSeconds / 60)) min"
                )
                Spacer()
                ShareLink(item: outcome.outputURL) {
                    Label("Export G-code", systemImage: "square.and.arrow.up")
                }
                .font(.caption.weight(.semibold))
            }
            SliceWarningsList(warnings: outcome.result.warnings)
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

/// Desktop slicing notifications parity: engine warnings after a slice, with
/// the desktop's texts for coded G-code warnings (Plater.cpp
/// get_slice_warning_string, GLCanvas3D.cpp conflict text).
struct SliceWarningsList: View {
    let warnings: [SliceWarning]

    init(warnings: [SliceWarning]) {
        // Desktop shows no text for "not_generate_timelapse" (Plater.cpp).
        self.warnings = warnings.filter { $0.code != "not_generate_timelapse" }
    }

    var body: some View {
        if !warnings.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: warning.level == .critical
                              ? "exclamationmark.octagon.fill"
                              : warning.level == .warning ? "exclamationmark.triangle.fill" : "info.circle")
                            .foregroundStyle(warning.level == .critical ? Color.red
                                             : warning.level == .warning ? Color.orange : Color.secondary)
                        Text(Self.text(for: warning))
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.top, 6)
        }
    }

    static func text(for warning: SliceWarning) -> String {
        let params = warning.detail.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        switch warning.code {
        case "bed_temperature_too_high_than_filament":
            return "The current hot bed temperature is relatively high. The nozzle may be clogged when printing this filament in a closed enclosure. Please open the front door and/or remove the upper glass."
        case "the_actual_nozzle_hrc_smaller_than_the_required_nozzle_hrc":
            return "The nozzle hardness required by the filament is higher than the default nozzle hardness of the printer. Please replace the hardened nozzle or filament, otherwise, the nozzle will be attrited or damaged."
        case "not_support_traditional_timelapse":
            return "Enabling traditional timelapse photography may cause surface imperfections. It is recommended to change to smooth mode."
        case "smooth_timelapse_without_prime_tower":
            return "Smooth mode for timelapse is enabled, but the prime tower is off, which may cause print defects. Please enable the prime tower, re-slice and print again."
        case "gcode_path_conflict" where params.count == 4:
            let z = Double(params[2]).map { String(format: "%.2f", $0) } ?? params[2]
            return "Conflicts of G-code paths have been found at layer \(params[3]), Z = \(z)mm. Please separate the conflicted objects farther (\(params[0]) <-> \(params[1]))."
        default:
            let base = warning.message.isEmpty ? warning.code : warning.message
            return warning.source == .objectStep && !warning.detail.isEmpty
                ? "\(warning.detail): \(base)" : base
        }
    }
}
