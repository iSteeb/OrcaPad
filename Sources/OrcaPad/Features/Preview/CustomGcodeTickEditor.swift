// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

import OrcaBridge
import SwiftUI

/// The ONE layer-tick editor behind both flows (desktop parity: the same
/// dialog adds and edits a tick): type picker, extruder + colour for
/// colour changes, extruder for tool changes, message for pause, raw
/// G-code text for custom. `template` ticks are read-only (the Bridge
/// rejects editing them — they come from imported projects).
struct CustomGcodeTickEditorSheet: View {
    enum Mode: Equatable {
        /// New tick at the top visible layer's height.
        case add(height: Double)
        /// Replace the existing tick at `printZ`.
        case edit(EnginePlater.CustomGcodeItem)
    }

    let mode: Mode
    /// Filament slot count (desktop sidebar list length).
    let slotCount: Int
    /// Receives the editor's result: kind, extruder, #rrggbb, extra text
    /// (pause message or custom G-code).
    let onSave: (
        _ kind: EnginePlater.CustomGcodeKind,
        _ extruder: Int,
        _ color: String,
        _ extra: String
    ) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var kind: EnginePlater.CustomGcodeKind = .pausePrint
    @State private var extruder = 1
    @State private var colorHex = "#FF0000"
    @State private var message = ""
    @State private var customText = ""

    /// Editable kinds (adding templates is a typed Bridge rejection).
    private static let editableKinds: [EnginePlater.CustomGcodeKind] = [
        .pausePrint, .colorChange, .toolChange, .custom,
    ]

    private var isTemplate: Bool {
        if case .edit(let tick) = mode, tick.kind == .template { return true }
        return false
    }

    /// Client-side mirror of the Bridge's argument validation, so Save
    /// never ships a request the engine would reject.
    private var rejection: String? {
        if isTemplate { return "Template ticks are read-only." }
        switch kind {
        case .custom:
            let trimmed = customText.trimmingCharacters(
                in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Custom G-code text is empty." : nil
        default:
            return nil
        }
    }

    private var height: Double {
        switch mode {
        case .add(let height): return height
        case .edit(let tick): return tick.printZ
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $kind) {
                        // A template tick keeps its (single, read-only)
                        // kind so the picker never shows an empty
                        // selection; every other kind is switchable.
                        ForEach(isTemplate ? [.template] : Self.editableKinds, id: \.self) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .disabled(isTemplate)
                    LabeledContent("Print height") {
                        Text(String(format: "%.2f mm", height))
                            .font(.callout.monospacedDigit())
                    }
                } header: {
                    Text("Tick")
                } footer: {
                    if case .add = mode {
                        Text("Runs at the top visible layer of the selected plate after re-slicing. Move the layer slider first to change the height.")
                    } else if isTemplate {
                        Text("Template ticks come from the project and cannot be edited.")
                    }
                }
                Section("Details") {
                    switch kind {
                    case .colorChange:
                        Picker("Extruder", selection: $extruder) {
                            ForEach(1...max(min(slotCount, 16), 1), id: \.self) { slot in
                                Text("Extruder \(slot)").tag(slot)
                            }
                        }
                        ColorPicker(
                            "Colour",
                            selection: Binding(
                                get: { Color(hex: colorHex) ?? .red },
                                set: { colorHex = Color.hexString($0) }
                            ),
                            supportsOpacity: false
                        )
                    case .toolChange:
                        Picker("Extruder", selection: $extruder) {
                            ForEach(1...max(min(slotCount, 16), 1), id: \.self) { slot in
                                Text("Extruder \(slot)").tag(slot)
                            }
                        }
                    case .pausePrint:
                        TextField(
                            "Message shown on the printer (optional)",
                            text: $message
                        )
                    case .template, .custom:
                        TextField(
                            "G-code (e.g. M300 S440 P200)",
                            text: $customText,
                            axis: .vertical
                        )
                        .font(.callout.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .lineLimit(3...8)
                    }
                }
                if let rejection {
                    Text(rejection)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle(isAdding ? "Add tick" : "Edit tick")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(rejection != nil)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear(perform: apply)
    }

    private var isAdding: Bool {
        if case .add = mode { return true }
        return false
    }

    /// Pre-fills from the mode: the edited tick's fields, or sensible
    /// defaults for a fresh tick.
    private func apply() {
        guard case .edit(let tick) = mode else { return }
        kind = tick.kind
        extruder = max(tick.extruder, 1)
        colorHex = tick.color.isEmpty ? "#FF0000" : tick.color
        message = tick.kind == .pausePrint ? tick.extra : ""
        customText = tick.kind == .custom ? tick.extra : ""
    }

    private func save() {
        let extra = kind == .pausePrint
            ? message : (kind == .custom ? customText : "")
        let color = kind == .colorChange ? colorHex : ""
        onSave(kind, extruder, color, extra)
        dismiss()
    }
}

/// Manage sheet for custom G-code templates (add / rename / edit / delete,
/// persisted through `CustomGcodeTemplatesStore`). Tapping a template in
/// the Tick menu inserts it as a CUSTOM tick; this sheet is where the
/// snippets themselves live.
struct CustomGcodeTemplatesSheet: View {
    let store: CustomGcodeTemplatesStore

    @Environment(\.dismiss) private var dismiss
    @State private var editing: EditTarget?

    /// New template vs. edit an existing one (sheet(item:)-driven).
    private struct EditTarget: Identifiable {
        let template: CustomGcodeTemplatesStore.Template?
        var id: UUID { template?.id ?? UUID() }
    }

    var body: some View {
        NavigationStack {
            List {
                if let loadError = store.loadError {
                    Section {
                        Label(
                            "Templates could not be loaded: \(loadError). Seed defaults are shown.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                }
                Section {
                    ForEach(store.templates) { template in
                        Button {
                            editing = EditTarget(template: template)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(template.name)
                                    .font(.subheadline.weight(.medium))
                                Text(template.gcode)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(role: .destructive) {
                                store.delete(id: template.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text("Templates")
                } footer: {
                    Text("Snippets for the Tick menu's “From template…” entries. Inserting one adds a custom G-code tick with the template's text.")
                }
            }
            .navigationTitle("G-code Templates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        editing = EditTarget(template: nil)
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(item: $editing) { target in
                TemplateEditorSheet(template: target.template) { name, gcode in
                    if let template = target.template {
                        store.update(id: template.id, name: name, gcode: gcode)
                    } else {
                        store.add(name: name, gcode: gcode)
                    }
                }
                .presentationDetents([.medium, .large])
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Name + G-code editor for one template (new or existing).
private struct TemplateEditorSheet: View {
    /// nil creates a new template.
    let template: CustomGcodeTemplatesStore.Template?
    let onSave: (_ name: String, _ gcode: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var gcode = ""
    @State private var attemptedInvalidSave = false

    private var invalid: Bool {
        name.trimmingCharacters(in: .whitespaces).isEmpty
            || gcode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                TextField(
                    "G-code (one command per line)",
                    text: $gcode,
                    axis: .vertical
                )
                .font(.callout.monospaced())
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .lineLimit(4...10)
                if attemptedInvalidSave {
                    Text("Name and G-code are required.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle(template == nil ? "New template" : "Edit template")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if invalid {
                            attemptedInvalidSave = true
                        } else {
                            onSave(name, gcode)
                            dismiss()
                        }
                    }
                }
            }
        }
        .onAppear {
            name = template?.name ?? ""
            gcode = template?.gcode ?? ""
        }
    }
}
