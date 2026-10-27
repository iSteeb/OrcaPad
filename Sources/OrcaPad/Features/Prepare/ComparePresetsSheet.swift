// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

import OrcaBridge
import SwiftUI

/// Desktop "Compare presets" (DiffPresetDialog, UnsavedChangesDialog.cpp
/// 2143): pick two presets of one kind and see every option value side by
/// side, differences first. The engine dumps configs only for the SELECTED
/// preset of a kind (`orca_presets_config_dump` → PresetStore
/// `systemConfigs`), so the comparison briefly walks the live session:
/// select A → dump, select B → dump, restore.
///
/// Selecting resets edited working copies (PresetCollection::select_preset,
/// "resets all the edits done to the currently selected preset") and a
/// machine switch may re-resolve the filament/process — so the ORIGINAL
/// selection AND the unsaved edited values of every kind are captured
/// before the walk and restored after it (re-applied through the normal
/// `setValue` path, the same transfer cycle-0.16 ships for manual preset
/// switches). Engine calls are refused while slicing (the PresetStore busy
/// gate) — a compare never parks on the engine mutex behind a slice.
struct ComparePresetsSheet: View {
    let presets: PresetStore
    let kind: PresetKind

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var nameA = ""
    @State private var nameB = ""
    @State private var running = false
    @State private var failureText: String?
    @State private var result: Comparison?

    // MARK: Model

    /// One option row: schema label + key, and the two preset values.
    struct DiffRow: Identifiable, Equatable {
        let key: String
        let label: String
        let valueA: String
        let valueB: String
        let changed: Bool

        var id: String { key }
    }

    struct Comparison: Equatable {
        let nameA: String
        let nameB: String
        /// Task spec: changed keys first.
        let changed: [DiffRow]
        let identical: [DiffRow]
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(pickerTitle, selection: $nameA) {
                        ForEach(presets.names(for: kind), id: \.name) { entry in
                            Text(entry.name).tag(entry.name)
                        }
                    }
                    Picker("Compare with", selection: $nameB) {
                        ForEach(presets.names(for: kind), id: \.name) { entry in
                            Text(entry.name).tag(entry.name)
                        }
                    }
                    Button {
                        Task { await runCompare() }
                    } label: {
                        HStack {
                            Label("Compare", systemImage: "square.split.2x1")
                            Spacer()
                            if running { ProgressView() }
                        }
                    }
                    .disabled(
                        running || nameA.isEmpty || nameA == nameB
                            || !presets.isReady || presets.isSelecting
                            || presets.isEngineBusy
                    )
                } header: {
                    Text(kindTitle)
                } footer: {
                    Text("Comparing briefly selects each preset to read its config from the engine, then restores the current selection and unsaved settings.")
                }
                if let failureText {
                    Section {
                        Label(failureText, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                if let result {
                    resultSections(result)
                }
            }
            .navigationTitle("Compare presets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                if nameA.isEmpty {
                    nameA = presets.selectedName(for: kind)
                }
                if nameB.isEmpty,
                   let other = presets.names(for: kind)
                    .first(where: { $0.name != nameA })?.name {
                    nameB = other
                }
            }
        }
        .presentationDetents([.large])
    }

    private var pickerTitle: String {
        switch kind {
        case .machine: return "Printer preset"
        case .filament: return "Filament preset"
        case .process: return "Process preset"
        }
    }

    private var kindTitle: String {
        switch kind {
        case .machine: return "Printer presets"
        case .filament: return "Filament presets"
        case .process: return "Process presets"
        }
    }

    // MARK: Result list

    @ViewBuilder
    private func resultSections(_ result: Comparison) -> some View {
        Section {
            if result.changed.isEmpty {
                Label("The presets define identical values.", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            } else {
                ForEach(result.changed) { row in
                    diffRow(row, changed: true)
                }
            }
        } header: {
            Text("\(result.changed.count) difference(s)")
        }
        if !result.identical.isEmpty {
            Section {
                // Hundreds of equal keys exist between presets; they stay
                // one tap away instead of scrolling the differences off
                // screen.
                DisclosureGroup("\(result.identical.count) identical values") {
                    ForEach(result.identical) { row in
                        diffRow(row, changed: false)
                    }
                }
            } header: {
                Text("\(result.nameA) vs \(result.nameB)")
            }
        }
    }

    /// Desktop DiffPreset grid columns: option | left | right, the changed
    /// values emphasized.
    private func diffRow(_ row: DiffRow, changed: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.label)
                    .font(.caption.weight(changed ? .semibold : .regular))
                    .lineLimit(1)
                Text(row.key)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.valueA)
                    .font(.caption.monospaced())
                    .foregroundStyle(changed ? Color.primary : Color.secondary)
                Text(row.valueB)
                    .font(.caption.monospaced())
                    .foregroundStyle(changed ? Color.primary : Color.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
    }

    // MARK: Compare run

    private func runCompare() async {
        guard presets.isReady, !presets.isSelecting, !presets.isEngineBusy else {
            failureText = "Presets are busy (slicing or selecting) — try again in a moment."
            return
        }
        let originalSelection = presets.selection
        let originalEdited = presets.editedConfigs
        let originalSystem = presets.systemConfigs
        let originalName = presets.selectedName(for: kind)

        running = true
        failureText = nil
        result = nil
        defer { running = false }

        // Walk: dump A, then B — through the store's own select path (busy
        // gates, refresh of every dump) or the already-loaded dump when the
        // preset IS the current selection (no engine call at all).
        var selectedNow = originalName
        func dump(of name: String, whenCurrent cached: [String: String]?) async -> [String: String]? {
            if name == selectedNow { return cached ?? presets.systemConfigs[kind] ?? [:] }
            await presets.select(kind: kind, name: name)
            guard presets.selectedName(for: kind) == name else { return nil }
            selectedNow = name
            return presets.systemConfigs[kind] ?? [:]
        }

        let dumpA = await dump(of: nameA, whenCurrent: originalSystem[kind])
        // B == the original selection is answered by the captured dump; a
        // B equal to A is blocked by the Compare button.
        let dumpB = await dump(of: nameB, whenCurrent: originalSystem[kind])

        // Restore ALWAYS — a failed dump must not leave the session on a
        // compare preset either.
        await restore(
            originalSelection: originalSelection,
            originalName: originalName,
            originalEdited: originalEdited,
            originalSystem: originalSystem
        )

        guard let dumpA, let dumpB else {
            failureText = "One preset could not be selected for the comparison (see the status log)."
            return
        }
        result = Self.build(nameA: nameA, dumpA: dumpA, nameB: nameB, dumpB: dumpB)
    }

    /// Puts the live session back exactly where it was: the kind's preset
    /// (plus filament/process a machine switch re-resolved) and every
    /// captured unsaved edited value. A restore that cannot return to the
    /// original state is reported loudly, never papered over.
    private func restore(
        originalSelection: PresetSelection,
        originalName: String,
        originalEdited: [PresetKind: [String: String]],
        originalSystem: [PresetKind: [String: String]]
    ) async {
        if presets.selectedName(for: kind) != originalName {
            await presets.select(kind: kind, name: originalName)
        }
        if kind == .machine {
            // selectMachine resolves a compatible filament/process; both go
            // back to what was selected before the compare.
            if presets.selection.filament != originalSelection.filament {
                await presets.select(kind: .filament, name: originalSelection.filament)
            }
            if presets.selection.process != originalSelection.process {
                await presets.select(kind: .process, name: originalSelection.process)
            }
        }
        // Unsaved edited values (any kind — a machine walk resets all three
        // edited copies): re-apply each captured modification through the
        // ordinary setValue path.
        for kindItem in PresetKind.allCases {
            guard let edited = originalEdited[kindItem],
                  let system = originalSystem[kindItem]
            else { continue }
            for (key, value) in edited where system[key] != value {
                await presets.setValue(
                    kind: kindItem, key: key, serializedValue: value)
            }
            // A key present in the system dump but ABSENT from the edited
            // dump is a removal the public API cannot re-apply — report it
            // instead of silently dropping the user's edit state.
            let removed = system.keys.filter { edited[$0] == nil }
            if !removed.isEmpty {
                environment.status.report(.presets, failure: .invariant(
                    operation: "compare presets",
                    diagnostic: "\(removed.count) removed setting(s) of the " +
                        "\(kindItem == .machine ? "printer" : kindItem == .filament ? "filament" : "process") " +
                        "preset could not be restored after the comparison"
                ))
            }
        }
        if presets.selection != originalSelection {
            environment.status.report(.presets, failure: .invariant(
                operation: "compare presets",
                diagnostic: "the original preset selection was not restored after the comparison"
            ))
        }
    }

    /// Union of both dumps, split into changed-first rows. Labels and enum
    /// value names come from the generated schema when it knows the key.
    private static func build(
        nameA: String, dumpA: [String: String],
        nameB: String, dumpB: [String: String]
    ) -> Comparison {
        let index: [String: ConfigOptionSchema]
        if case .success(let dictionary) = ConfigSchema.index {
            index = dictionary
        } else {
            index = [:]
        }
        var changed: [DiffRow] = []
        var identical: [DiffRow] = []
        for key in Set(dumpA.keys).union(dumpB.keys).sorted() {
            let rawA = dumpA[key]
            let rawB = dumpB[key]
            let row = DiffRow(
                key: key,
                label: index[key]?.label ?? key,
                valueA: display(rawA, key: key, index: index),
                valueB: display(rawB, key: key, index: index),
                changed: rawA != rawB
            )
            if row.changed {
                changed.append(row)
            } else {
                identical.append(row)
            }
        }
        return Comparison(
            nameA: nameA, nameB: nameB, changed: changed, identical: identical)
    }

    /// Serialized config value → display text: enum values become their
    /// schema labels ("enable" → "Enable"); everything else shows raw;
    /// missing keys show as not set.
    private static func display(
        _ raw: String?, key: String, index: [String: ConfigOptionSchema]
    ) -> String {
        guard let raw else { return "not set" }
        guard let option = index[key],
              let values = option.enumValues,
              let labels = option.enumLabels,
              values.count == labels.count,
              let position = values.firstIndex(of: raw)
        else { return raw }
        return labels[position]
    }
}
