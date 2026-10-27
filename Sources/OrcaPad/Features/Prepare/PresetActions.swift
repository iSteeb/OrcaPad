// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

import OrcaBridge
import SwiftUI

/// Desktop preset-tab actions (Tab.cpp save / delete / reset buttons) for one
/// preset kind: Save as user preset (SavePresetDialog), Delete (user presets
/// only), Reset modifications.
struct PresetActionsMenu: View {
    let kind: PresetKind

    @Environment(AppEnvironment.self) private var environment
    @State private var savePresented = false
    @State private var deleteConfirmation = false
    /// Create Preset wizards (prepare create-wizards, ABI v41).
    @State private var createPresented = false
    /// Desktop filament-bar "Merge with…" (prepare.multi-filament).
    @State private var mergePresented = false

    private var presets: PresetStore { environment.presets }

    private var currentName: String {
        switch kind {
        case .machine: return presets.selection.machine
        case .filament: return presets.selection.filament
        case .process: return presets.selection.process
        }
    }

    var body: some View {
        let modified = presets.modifiedKeys(in: kind).count
        Menu {
            Button {
                savePresented = true
            } label: {
                Label(modified > 0 ? "Save \(modified) change(s) as preset…" : "Save as preset…",
                      systemImage: "square.and.arrow.down")
            }
            if modified > 0 {
                Button {
                    Task { await presets.resetKind(kind) }
                } label: {
                    Label("Discard \(modified) change(s)", systemImage: "arrow.uturn.backward")
                }
            }
            if presets.origin(of: kind) == .user {
                Divider()
                Button(role: .destructive) {
                    deleteConfirmation = true
                } label: {
                    Label("Delete preset", systemImage: "trash")
                }
            }
            // Desktop Create Preset wizards (prepare create-wizards).
            if kind == .machine || kind == .filament {
                Divider()
                Button {
                    createPresented = true
                } label: {
                    Label(
                        kind == .machine
                            ? "Create printer preset\u{2026}"
                            : "Create filament preset\u{2026}",
                        systemImage: "plus.square.on.square"
                    )
                }
            }
            // Desktop filament "Merge with…" (prepare.multi-filament):
            // the current filament absorbs another preset's per-slot values.
            if kind == .filament, presets.filaments.count > 1 {
                Button {
                    mergePresented = true
                } label: {
                    Label("Merge with\u{2026}", systemImage: "square.stack.3d.down.right")
                }
            }
        } label: {
            Label("Preset", systemImage: "ellipsis.circle")
        }
        .disabled(presets.isSelecting)
        .sheet(isPresented: $savePresented) {
            PresetSaveSheet(kind: kind, currentName: currentName, origin: presets.origin(of: kind))
        }
        .sheet(isPresented: $createPresented) {
            switch kind {
            case .machine: CreatePrinterSheet(presets: presets)
            case .filament: CreateFilamentSheet(presets: presets)
            case .process: EmptyView()
            }
        }
        .sheet(isPresented: $mergePresented) {
            MergeFilamentSheet(presets: presets)
        }
        .confirmationDialog(
            "Delete \"\(currentName)\"?",
            isPresented: $deleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                let name = currentName
                Task { await presets.deleteUserPreset(kind: kind, name: name) }
            }
        } message: {
            Text("The user preset file is removed. This cannot be undone.")
        }
    }
}

/// Desktop SavePresetDialog: name (validated by the engine-side rules on
/// save) and "Detach from system preset".
struct PresetSaveSheet: View {
    let kind: PresetKind
    let currentName: String
    let origin: PresetOrigin?

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var detach = false

    private var existing: PresetEntry? {
        let entries: [PresetEntry]
        switch kind {
        case .machine: entries = environment.presets.machines
        case .filament: entries = environment.presets.filaments
        case .process: entries = environment.presets.processes
        }
        return entries.first { $0.name == name }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Preset name", text: $name)
                        .autocorrectionDisabled()
                } footer: {
                    if let existing {
                        Text(existing.origin == .user
                             ? "Preset \"\(name)\" already exists. Saving will overwrite it."
                             : "Overwriting a system profile is not allowed.")
                            .foregroundStyle(existing.origin == .user ? Color.orange : Color.red)
                    }
                }
                if origin == .system {
                    Section {
                        Toggle("Detach from system preset", isOn: $detach)
                    } footer: {
                        Text("A detached preset no longer inherits updates of \"\(currentName)\".")
                    }
                }
            }
            .navigationTitle("Save preset")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let chosen = name
                        let detachChoice = detach
                        Task {
                            await environment.presets.saveUserPreset(
                                kind: kind, name: chosen, detach: detachChoice
                            )
                        }
                        dismiss()
                    }
                    .disabled(existing.map { $0.origin != .user } ?? false)
                }
            }
            .onAppear {
                // desktop default: system presets get a " - Copy" suffix
                name = origin == .user ? currentName : "\(currentName) - Copy"
            }
        }
        .presentationDetents([.medium])
    }
}
