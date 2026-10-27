// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

import OrcaBridge
import SwiftUI

/// Desktop object list "Edit Process Settings": per-object (or per-part /
/// modifier) setting overrides. Rows reuse the Prepare editor; adding an
/// override seeds it with the value the slice would use today (the resolved
/// preset config), like desktop. Presentation only: reads and writes go
/// through DocumentStore (engine-authoritative, undoable).
struct ObjectSettingsSheet: View {
    let objectID: ObjectID
    let volumeID: VolumeID?
    let title: String
    /// A quick-menu pick (frequent settings / object-list settings row):
    /// seeds this override with today's resolved value when absent.
    var preselectKey: String?

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var overrides: [String: String] = [:]
    @State private var allowedKeys: [String] = []
    @State private var resolved: [String: String] = [:]
    @State private var loadFailure: String?
    @State private var addPresented = false
    @State private var seededPreselect = false

    @State private var schemaIndex: [String: ConfigOptionSchema] = [:]

    private var document: DocumentStore { environment.document }

    var body: some View {
        NavigationStack {
            List {
                if let loadFailure {
                    Section {
                        Label(loadFailure, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
                Section {
                    if overrides.isEmpty {
                        Text("No overrides: this \(volumeID == nil ? "object" : "part") uses the process preset.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(sortedKeys, id: \.self) { key in
                        if let schema = schemaIndex[key], let value = overrides[key] {
                            SettingsEditorRowView(
                                row: SettingsEditorRow(schema: schema, value: value, isModified: true),
                                onCommit: { newValue in commit(key: key, value: newValue) },
                                onReset: { erase(key: key) },
                                onReject: { message in
                                    environment.status.report(
                                        .document,
                                        failure: .invariant(operation: "set \(key)", diagnostic: message)
                                    )
                                }
                            )
                        } else {
                            Text("\(key) = \(overrides[key] ?? "")")
                                .font(.caption.monospaced())
                        }
                    }
                } header: {
                    Text("Overrides")
                } footer: {
                    Text("Tap the reset arrow to remove an override. Changes are undoable.")
                }
                // Desktop object-level "Flush options" (PrintObjectConfig
                // booleans): object settings only — parts override
                // PrintRegionConfig, which does not define these keys.
                if !flushKeys.isEmpty {
                    Section {
                        ForEach(flushKeys, id: \.self) { key in
                            if let schema = schemaIndex[key] {
                                SettingsEditorRowView(
                                    row: SettingsEditorRow(
                                        schema: schema,
                                        value: flushValue(key),
                                        isModified: overrides[key] != nil
                                    ),
                                    onCommit: { newValue in
                                        commit(key: key, value: newValue)
                                    },
                                    onReset: { erase(key: key) },
                                    onReject: { message in
                                        environment.status.report(
                                            .document,
                                            failure: .invariant(
                                                operation: "set \(key)",
                                                diagnostic: message
                                            )
                                        )
                                    }
                                )
                            }
                        }
                    } header: {
                        Text("Flushing")
                    } footer: {
                        Text("Prime-tower purging targets for this object. Values start from today's resolved config; the reset arrow returns to it.")
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        addPresented = true
                    } label: {
                        Label("Add setting", systemImage: "plus")
                    }
                    .disabled(allowedKeys.isEmpty || document.isBusy)
                }
            }
            .sheet(isPresented: $addPresented) {
                OptionPicker(
                    keys: allowedKeys.filter { overrides[$0] == nil },
                    schema: schemaIndex
                ) { key in
                    addPresented = false
                    let seed = resolved[key] ?? schemaIndex[key]?.defaultValue ?? ""
                    commit(key: key, value: seed)
                }
            }
            .task(id: document.scene?.revision) { await reload() }
            .task { await loadStatic() }
        }
        .presentationDetents([.medium, .large])
    }

    private var sortedKeys: [String] {
        overrides.keys.sorted { lhs, rhs in
            let l = schemaIndex[lhs]?.label ?? lhs
            let r = schemaIndex[rhs]?.label ?? rhs
            return l.localizedCaseInsensitiveCompare(r) == .orderedAscending
        }
    }

    /// Desktop "Flush options" category at object level (engine definition
    /// order). The C side accepts these as object override keys — they are
    /// PrintObjectConfig members (orcapad_settings_keys object set); the
    /// list self-empties if a future engine build drops one.
    private var flushKeys: [String] {
        guard volumeID == nil else { return [] }
        return ["flush_into_infill", "flush_into_support", "flush_into_objects"]
            .filter { allowedKeys.contains($0) && schemaIndex[$0] != nil }
    }

    /// Today's effective flush toggle value: the override when present,
    /// else the resolved config the slice would use, else the schema
    /// default (flush_into_support defaults on, the others off).
    private func flushValue(_ key: String) -> String {
        if let value = overrides[key] { return value }
        if let value = resolved[key], !value.isEmpty { return value }
        return schemaIndex[key]?.defaultValue ?? "0"
    }

    private func reload() async {
        if let values = await document.settings(objectID: objectID, volumeID: volumeID) {
            overrides = values
            loadFailure = nil
        } else {
            loadFailure = "Could not read the overrides (see the banner)."
        }
    }

    /// Frequent-settings / settings-row pick: create the override now
    /// (desktop add_category_to_settings_from_frequent), seeded with the
    /// value the slice would use today. Runs once, after the static loader
    /// has the allowed keys and the resolved config.
    private func seedPreselect() async {
        guard let key = preselectKey, !seededPreselect,
              allowedKeys.contains(key), overrides[key] == nil else { return }
        let seed = resolved[key] ?? schemaIndex[key]?.defaultValue ?? ""
        guard !seed.isEmpty else { return }
        seededPreselect = true
        await document.setSetting(
            objectID: objectID, volumeID: volumeID, key: key, value: seed
        )
    }

    /// Allowed keys + today's resolved values (seeds for new overrides).
    private func loadStatic() async {
        switch ConfigSchema.index {
        case .success(let index):
            schemaIndex = index
        case .failure(let failure):
            environment.status.report(.document, failure: failure)
            return
        }
        let forVolume = volumeID != nil
        let keysResult = await BackgroundWork.run(operation: "read overridable keys") {
            try EnginePlater.settingsKeys(forVolume: forVolume)
        }
        switch keysResult {
        case .success(let keys):
            allowedKeys = keys.filter { schemaIndex[$0] != nil }
        case .failure(let failure):
            environment.status.report(.document, failure: failure)
        }
        guard let engine = environment.presets.engineForSlicing else { return }
        let resolvedResult = await BackgroundWork.run(operation: "read resolved config") {
            try engine.resolvedConfig().get()
        }
        switch resolvedResult {
        case .success(let json):
            do {
                guard let data = json.data(using: .utf8),
                      let values = try JSONSerialization.jsonObject(with: data) as? [String: String]
                else {
                    throw AppFailure.invariant(
                        operation: "read resolved config", diagnostic: "not a string map")
                }
                resolved = values
            } catch {
                environment.status.report(
                    .document, failure: AppFailure.wrap(error, operation: "read resolved config"))
            }
        case .failure(let failure):
            environment.status.report(.document, failure: failure)
        }
        // A frequent-settings pick waits for exactly this state (allowed
        // keys + resolved seeds) before creating its override.
        await reload()
        await seedPreselect()
    }

    private func commit(key: String, value: String) {
        Task {
            await document.setSetting(objectID: objectID, volumeID: volumeID, key: key, value: value)
        }
    }

    private func erase(key: String) {
        Task {
            await document.eraseSetting(objectID: objectID, volumeID: volumeID, key: key)
        }
    }
}

/// Searchable list of overridable options grouped by schema category.
private struct OptionPicker: View {
    let keys: [String]
    let schema: [String: ConfigOptionSchema]
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var grouped: [(category: String, keys: [String])] {
        let filtered = keys.filter { key in
            guard !query.isEmpty else { return true }
            let label = schema[key]?.label ?? key
            return label.localizedCaseInsensitiveContains(query)
                || key.localizedCaseInsensitiveContains(query)
        }
        let groups = Dictionary(grouping: filtered) { key in
            let category = schema[key]?.category ?? ""
            return category.isEmpty ? "Other" : category
        }
        return groups.keys.sorted().map { category in
            (category, groups[category, default: []].sorted {
                (schema[$0]?.label ?? $0).localizedCaseInsensitiveCompare(schema[$1]?.label ?? $1)
                    == .orderedAscending
            })
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(grouped, id: \.category) { group in
                    Section(group.category) {
                        ForEach(group.keys, id: \.self) { key in
                            Button {
                                onPick(key)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(schema[key]?.label?.isEmpty == false ? schema[key]?.label ?? key : key)
                                    Text(key)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $query)
            .navigationTitle("Add setting")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
