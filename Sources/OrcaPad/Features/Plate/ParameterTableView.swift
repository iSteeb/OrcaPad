// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

import OrcaBridge
import SwiftUI

/// Desktop ObjectTableDialog ("Edit in Parameter Table"): the selected
/// objects' per-object setting overrides side by side. Rows are the union
/// of every override key, one column per object; a cell edits that object's
/// override through the normal typed editor (DocumentStore, undoable).
/// Presentation only — all reads/writes go through the stores.
struct ParameterTableView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    private var document: DocumentStore { environment.document }

    /// Column per selected object (whole-object overrides only, desktop
    /// parity: the table edits ModelObject::config).
    private var objects: [SceneObject] {
        let ids = document.selectedObjectIDs
        return (document.scene?.objects ?? []).filter { ids.contains($0.id) }
    }

    @State private var overridesByObject: [ObjectID: [String: String]] = [:]
    @State private var loadFailure: String?
    @State private var editingCell: Cell?

    private struct Cell: Identifiable {
        let objectID: ObjectID
        let key: String
        var id: String { "\(objectID)-\(key)" }
    }

    private var allKeys: [String] {
        var keys = Set<String>()
        for values in overridesByObject.values {
            keys.formUnion(values.keys)
        }
        return keys.sorted { FrequentSettings.label(for: $0) < FrequentSettings.label(for: $1) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if objects.count < 2 {
                    ContentUnavailableView(
                        "Select objects first",
                        systemImage: "tablecells",
                        description: Text(
                            "Select two or more objects (long-press or rectangle select), then open the parameter table."
                        )
                    )
                } else if let loadFailure {
                    ContentUnavailableView(
                        "Could not read settings",
                        systemImage: "exclamationmark.triangle",
                        description: Text(loadFailure)
                    )
                } else if allKeys.isEmpty {
                    ContentUnavailableView(
                        "No overrides",
                        systemImage: "slider.horizontal.3",
                        description: Text(
                            "None of the selected objects overrides the process preset. Copy settings between them via their context menus, or add overrides first."
                        )
                    )
                } else {
                    table
                }
            }
            .navigationTitle("Parameter table")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $editingCell) { cell in
                cellEditor(cell)
            }
            .task(id: document.scene?.revision) { await reload() }
        }
    }

    private var table: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    Text("")
                        .frame(width: 180, alignment: .leading)
                    ForEach(objects) { object in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(object.name)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                            Text("\(object.instances.count) instance(s)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .frame(width: 150, alignment: .leading)
                    }
                }
                Divider()
                ForEach(allKeys, id: \.self) { key in
                    GridRow {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(FrequentSettings.label(for: key))
                                .font(.caption)
                                .lineLimit(1)
                            Text(key)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 6)
                        .frame(width: 180, alignment: .leading)
                        ForEach(objects) { object in
                            cellButton(object: object, key: key)
                        }
                    }
                    Divider()
                }
            }
            .padding(.horizontal, 12)
        }
    }

    private func cellButton(object: SceneObject, key: String) -> some View {
        let value = overridesByObject[object.id]?[key]
        return Button {
            editingCell = Cell(objectID: object.id, key: key)
        } label: {
            Text(value ?? "—")
                .font(value == nil ? .caption : .caption.monospaced())
                .foregroundStyle(value == nil ? Color.secondary : Color.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: 150, alignment: .leading)
    }

    /// One typed editor for the cell's (object, key) — seeded from the
    /// resolved config when the override is new (desktop parity).
    private func cellEditor(_ cell: Cell) -> some View {
        CellEditorSheet(
            objectID: cell.objectID,
            key: cell.key,
            value: overridesByObject[cell.objectID]?[cell.key]
        )
    }

    private func reload() async {
        var loaded: [ObjectID: [String: String]] = [:]
        for object in objects {
            guard let values = await document.settings(
                objectID: object.id, volumeID: nil
            ) else {
                loadFailure = "Could not read the overrides of \(object.name)."
                return
            }
            loaded[object.id] = values
        }
        loadFailure = nil
        overridesByObject = loaded
    }
}

/// One cell's editor: the Prepare typed row for that single key.
private struct CellEditorSheet: View {
    let objectID: ObjectID
    let key: String
    let value: String?

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var resolvedValue = ""

    private var document: DocumentStore { environment.document }

    var body: some View {
        NavigationStack {
            List {
                switch (ConfigSchema.index, value ?? resolvedValue) {
                case (.success(let index), let current):
                    if let schema = index[key] {
                        SettingsEditorRowView(
                            row: SettingsEditorRow(
                                schema: schema,
                                value: current,
                                isModified: value != nil
                            ),
                            onCommit: { newValue in commit(newValue) },
                            onReset: { erase() },
                            onReject: { message in
                                environment.status.report(
                                    .document,
                                    failure: .invariant(
                                        operation: "set \(key)", diagnostic: message
                                    )
                                )
                            }
                        )
                    } else if value != nil {
                        Button("Remove override", role: .destructive) { erase() }
                    } else {
                        Text("This option is not editable here.")
                            .foregroundStyle(.secondary)
                    }
                case (.failure, _):
                    Text("The config schema is not available.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(FrequentSettings.label(for: key))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await loadSeed() }
        }
        .presentationDetents([.medium, .large])
    }

    private func loadSeed() async {
        guard value == nil,
              let engine = environment.presets.engineForSlicing else { return }
        let result = await BackgroundWork.run(operation: "read resolved config") {
            try engine.resolvedConfig().get()
        }
        guard case .success(let json) = result, let data = json.data(using: .utf8) else {
            environment.status.report(
                .document, failure: AppFailure.invariant(
                    operation: "read resolved config",
                    diagnostic: "the engine returned no config for the cell seed"
                )
            )
            return
        }
        do {
            guard let values = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
                throw AppFailure.invariant(
                    operation: "read resolved config", diagnostic: "not a string map")
            }
            resolvedValue = values[key] ?? ""
        } catch {
            environment.status.report(
                .document, failure: AppFailure.wrap(error, operation: "read resolved config"))
        }
    }

    private func commit(_ newValue: String) {
        Task {
            await document.setSetting(
                objectID: objectID, volumeID: nil, key: key, value: newValue
            )
        }
    }

    private func erase() {
        Task {
            await document.eraseSetting(objectID: objectID, volumeID: nil, key: key)
        }
    }
}
