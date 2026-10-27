// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

import OrcaBridge
import SwiftUI

/// Desktop Create Printer/Filament Preset wizards (ABI v41): pick a base
/// preset, override its identity fields, and let the engine clone it as a
/// user preset (which the engine activates). Presented from the preset
/// pages' Preset menu (PresetActionsMenu); typed failures surface through
/// the preset status line like every other preset operation.
///
/// Shared pieces: the base-preset picker reuses GroupedPickerList
/// (searchable, vendor-grouped) pushed inside the sheet's NavigationStack;
/// the name field carries the same existing-name guard as PresetSaveSheet.
private struct CreatePresetFormFooter: View {
    let existing: PresetEntry?

    var body: some View {
        if let existing {
            Text(existing.origin == .user
                 ? "Preset \"\(existing.name)\" already exists. Creating it again will overwrite it."
                 : "Overwriting a system profile is not allowed.")
                .foregroundStyle(existing.origin == .user ? Color.orange : Color.red)
        }
    }
}

/// "Create Filament Preset…": base filament (default = selected), name,
/// vendor and filament type (engine `filament_type` enum).
struct CreateFilamentSheet: View {
    let presets: PresetStore

    @Environment(\.dismiss) private var dismiss
    @State private var base = ""
    @State private var name = ""
    @State private var vendor = ""
    @State private var type = "PLA"

    /// Engine `filament_type` enum (schema-extracted; ABS … TPU).
    private var typeValues: [String] {
        if case .success(let index) = ConfigSchema.index,
           let values = index["filament_type"]?.enumValues, !values.isEmpty {
            return values
        }
        return ["PLA"]
    }

    private var existing: PresetEntry? {
        presets.filaments.first { $0.name == name }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        GroupedPickerList(
                            title: "Base Filament",
                            entries: presets.visibleEntries(for: .filament),
                            selected: base,
                            vendorPlaceholder: "Other"
                        ) { picked in
                            base = picked
                        }
                    } label: {
                        LabeledContent("Base preset") {
                            Text(base.isEmpty ? "Selected" : base)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    TextField("Preset name", text: $name)
                        .autocorrectionDisabled()
                    TextField("Vendor", text: $vendor)
                        .autocorrectionDisabled()
                    Picker("Type", selection: $type) {
                        ForEach(typeValues, id: \.self) { value in
                            Text(value).tag(value)
                        }
                    }
                } footer: {
                    CreatePresetFormFooter(existing: existing)
                }
                Section {
                    LabeledContent("Base vendor") {
                        Text(baseVendor)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Cloned from")
                } footer: {
                    Text("The new preset copies every setting of the base preset, then overrides vendor and type. It is saved as a user preset and selected.")
                }
            }
            .navigationTitle("Create Filament")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let chosenBase = base
                        let chosenName = name
                        let chosenVendor = vendor
                        let chosenType = type
                        Task {
                            if await presets.createFilament(
                                base: chosenBase.isEmpty ? nil : chosenBase,
                                name: chosenName,
                                vendor: chosenVendor,
                                filamentType: chosenType
                            ) {
                                dismiss()
                            }
                        }
                    }
                    .disabled(
                        name.trimmingCharacters(in: .whitespaces).isEmpty ||
                            existing.map { $0.origin != .user } ?? false
                    )
                }
            }
            .onAppear { prefill() }
        }
        .presentationDetents([.large])
    }

    /// Defaults from the edited filament dump while the base IS the current
    /// selection (the values the clone would carry anyway).
    private func prefill() {
        guard base.isEmpty else { return }
        base = presets.selection.filament
        let edited = presets.editedConfigs[.filament] ?? [:]
        if let vendorValue = edited["filament_vendor"]?.split(separator: ",").first {
            vendor = String(vendorValue)
        }
        if let typeValue = edited["filament_type"]?.split(separator: ",").first {
            let candidate = String(typeValue)
            if typeValues.contains(candidate) { type = candidate }
        }
    }

    private var baseVendor: String {
        guard base == presets.selection.filament,
              let vendorValue = presets.editedConfigs[.filament]?["filament_vendor"]?
                  .split(separator: ",").first
        else { return base.isEmpty ? "—" : base }
        return String(vendorValue)
    }
}

/// "Create Printer Preset…": base machine (default = selected), name,
/// model, variant and a 1…16 nozzle-diameter editor. The engine also clones
/// the selected process and filament presets with `compatible_printers`
/// carrying the new printer (reported in the status line).
struct CreatePrinterSheet: View {
    let presets: PresetStore

    @Environment(\.dismiss) private var dismiss
    @State private var base = ""
    @State private var name = ""
    @State private var model = ""
    @State private var variant = ""
    /// Nozzle diameters as typed (validated on Create; at least one).
    @State private var nozzles: [String] = ["0.4"]

    private static let maxNozzles = 16

    private var existing: PresetEntry? {
        presets.machines.first { $0.name == name }
    }

    /// Parses the typed diameters; nil when any is not a positive number.
    private var parsedNozzles: [Double]? {
        var values: [Double] = []
        for token in nozzles {
            let normalized = token
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: ",", with: ".")
            guard let value = Double(normalized), value > 0 else { return nil }
            values.append(value)
        }
        return values.isEmpty ? nil : values
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        GroupedPickerList(
                            title: "Base Printer",
                            entries: presets.visibleEntries(for: .machine),
                            selected: base,
                            vendorPlaceholder: "Other"
                        ) { picked in
                            base = picked
                        }
                    } label: {
                        LabeledContent("Base preset") {
                            Text(base.isEmpty ? "Selected" : base)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    TextField("Preset name", text: $name)
                        .autocorrectionDisabled()
                    TextField("Model (required)", text: $model)
                        .autocorrectionDisabled()
                    TextField("Variant", text: $variant)
                        .autocorrectionDisabled()
                } footer: {
                    CreatePresetFormFooter(existing: existing)
                }
                Section {
                    ForEach(Array(nozzles.indices), id: \.self) { index in
                        HStack {
                            TextField("Nozzle \(index + 1)", text: nozzleBinding(index))
                                .keyboardType(.numbersAndPunctuation)
                                .autocorrectionDisabled()
                                .font(.callout.monospaced())
                            Button {
                                guard nozzles.count > 1 else { return }
                                nozzles.remove(at: index)
                            } label: {
                                Image(systemName: "minus.circle")
                                    .foregroundStyle(nozzles.count > 1 ? Color.red : Color.secondary)
                            }
                            .buttonStyle(.borderless)
                            .disabled(nozzles.count <= 1)
                        }
                    }
                    Button {
                        guard nozzles.count < Self.maxNozzles else { return }
                        nozzles.append(nozzles.last ?? "0.4")
                    } label: {
                        Label("Add nozzle", systemImage: "plus.circle")
                    }
                    .disabled(nozzles.count >= Self.maxNozzles)
                } header: {
                    Text("Nozzle diameters (mm)")
                } footer: {
                    Text("The new preset carries the listed diameters (one entry per extruder for multi-extruder machines). 1–\(Self.maxNozzles) positive values.")
                }
            }
            .navigationTitle("Create Printer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let chosenBase = base
                        let chosenName = name
                        let chosenModel = model
                        let chosenVariant = variant
                        let chosenNozzles = parsedNozzles ?? []
                        Task {
                            if await presets.createPrinter(
                                base: chosenBase.isEmpty ? nil : chosenBase,
                                name: chosenName,
                                model: chosenModel,
                                variant: chosenVariant,
                                nozzleDiameters: chosenNozzles
                            ) {
                                dismiss()
                            }
                        }
                    }
                    .disabled(
                        name.trimmingCharacters(in: .whitespaces).isEmpty ||
                            model.trimmingCharacters(in: .whitespaces).isEmpty ||
                            parsedNozzles == nil ||
                            (existing.map { $0.origin != .user } ?? false)
                    )
                }
            }
            .onAppear { prefill() }
        }
        .presentationDetents([.large])
    }

    /// Defaults from the edited machine dump while the base IS the current
    /// selection (model, variant, nozzle diameters of the active printer).
    private func prefill() {
        guard base.isEmpty else { return }
        base = presets.selection.machine
        let edited = presets.editedConfigs[.machine] ?? [:]
        if let modelValue = edited["printer_model"], !modelValue.isEmpty {
            model = modelValue
        }
        if let variantValue = edited["printer_variant"], !variantValue.isEmpty {
            variant = variantValue
        }
        if let nozzleValue = edited["nozzle_diameter"] {
            let tokens = nozzleValue.split(separator: ",").map(String.init)
            let allPositive = !tokens.isEmpty && tokens.allSatisfy {
                Double($0.trimmingCharacters(in: .whitespaces)).map { $0 > 0 } ?? false
            }
            if allPositive { nozzles = tokens }
        }
    }

    private func nozzleBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { index < nozzles.count ? nozzles[index] : "" },
            set: { if index < nozzles.count { nozzles[index] = $0 } }
        )
    }
}
