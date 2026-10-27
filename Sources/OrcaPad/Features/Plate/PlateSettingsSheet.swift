// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

import OrcaBridge
import SwiftUI

/// Desktop PlateSettingsDialog (PlateSettingsDialog.cpp): per-plate print
/// overrides — bed type, print sequence, spiral vase mode and the
/// first/other-layer filament sequences. Every control offers "Default"
/// (= nil = follow the project settings); Save applies ONE replacement
/// mutation through `DocumentStore.applyPlateSettings` (the Bridge maps
/// them onto the plate's config; slicing consumes them automatically).
/// Self-loading sheet (HeightRangesSheet pattern): `load` runs on appear,
/// `onApply` commits.
struct PlateSettingsSheet: View {
    let plate: ScenePlate
    /// The printer's bed types (nil = presets not ready; the row explains).
    let bedType: BedTypeState?
    /// Filament slot count — the sequence editors offer T1..Tn.
    let filamentCount: Int
    let isBusy: Bool
    let load: () async -> EnginePlater.PlateSettings?
    let onApply: (EnginePlater.PlateSettings) -> Void

    /// Desktop ternary choices (same-as-global / on / off).
    private enum Ternary: Hashable {
        case defaultValue
        case on
        case off
    }

    /// One extruder slot of a sequence editor: 1-based extruder, its place
    /// in the order and whether it takes part (desktop's draggable shape
    /// list — chips reorder with up/down buttons, the check toggles use).
    private struct Slot: Identifiable {
        let id = UUID()
        let extruder: Int
        var enabled: Bool
    }

    @Environment(\.dismiss) private var dismiss
    @State private var bedTypeValue: Int?
    @State private var printSequence: Int?
    @State private var spiral: Ternary = .defaultValue
    @State private var firstLayer: [Slot] = []
    @State private var otherLayers: [Slot] = []
    @State private var loaded = false
    /// The engine read failed (the store already surfaced it) — the sheet
    /// stays read-only instead of silently offering defaults as truth.
    @State private var loadError = false

    var body: some View {
        NavigationStack {
            Form {
                loadErrorBanner
                bedTypeSection
                Section {
                    Picker("Sequence", selection: $printSequence) {
                        Text("Default").tag(Int?.none)
                        Text("By layer").tag(Int?.some(0))
                        Text("By object").tag(Int?.some(1))
                    }
                    Picker("Spiral vase mode", selection: $spiral) {
                        Text("Default").tag(Ternary.defaultValue)
                        Text("On").tag(Ternary.on)
                        Text("Off").tag(Ternary.off)
                    }
                } footer: {
                    Text("Default follows the project process settings for this plate.")
                }
                if filamentCount > 1 {
                    Section {
                        sequenceEditor($firstLayer)
                    } header: {
                        Text("First layer filament sequence")
                    } footer: {
                        Text("The extruder order of the first layer. Unchecked extruders keep the default order.")
                    }
                    Section {
                        sequenceEditor($otherLayers)
                    } header: {
                        Text("Other layer filament sequence")
                    } footer: {
                        Text("The extruder order of every layer after the first.")
                    }
                }
            }
            .navigationTitle("\(plate.name) · Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: apply)
                        .disabled(isBusy || !loaded || loadError)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task { await loadSettings() }
    }

    // MARK: Load-failure banner

    @ViewBuilder
    private var loadErrorBanner: some View {
        if loadError {
            Label("The plate settings could not be read — try again.",
                  systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .font(.caption)
        }
    }

    // MARK: Bed type (desktop "Same as Global Plate Type" + the printer's types)

    @ViewBuilder
    private var bedTypeSection: some View {
        switch (bedType, ConfigSchema.index) {
        case (.some(let state), .success(let index)):
            let labels = index["curr_bed_type"]?.enumLabels ?? []
            Section {
                if state.selectable, !state.supported.isEmpty {
                    Picker("Bed type", selection: $bedTypeValue) {
                        Text("Default").tag(Int?.none)
                        ForEach(state.supported, id: \.self) { value in
                            Text(bedTypeLabel(value, labels, count: state.count))
                                .tag(Int?.some(Int(value)))
                        }
                    }
                } else {
                    LabeledContent("Bed type") {
                        Text("One type").foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("Default uses the project plate type (Prepare tab).")
            }
        case (_, .failure(let failure)):
            Section("Bed type") {
                Label(failure.localizedDescription, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        case (.none, _):
            Section("Bed type") {
                Label("Presets are not loaded — bed type unavailable",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
    }

    /// Engine BedType v (1-based) ↔ schema enum index v-1
    /// (verified count, PlateTypeRow logic).
    private func bedTypeLabel(_ value: Int32, _ labels: [String], count: Int32) -> String {
        guard labels.count == Int(count) - 1,
              value >= 1, Int(value) <= labels.count else {
            return "Type \(value)"
        }
        return labels[Int(value) - 1]
    }

    // MARK: Sequence editors (desktop drag canvas)

    private func sequenceEditor(_ slots: Binding<[Slot]>) -> some View {
        ForEach(slots) { $slot in
            HStack(spacing: 10) {
                Button {
                    $slot.wrappedValue.enabled.toggle()
                } label: {
                    Image(systemName: slot.enabled
                          ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(slot.enabled ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(slot.enabled ? "Exclude extruder" : "Include extruder")
                Text("T\(slot.extruder)")
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                Spacer()
                moveButtons(slots, id: slot.id)
            }
        }
    }

    /// Reorder chips with up/down buttons (desktop drags shapes).
    @ViewBuilder
    private func moveButtons(_ slots: Binding<[Slot]>, id: UUID) -> some View {
        let index = slots.wrappedValue.firstIndex { $0.id == id }
        HStack(spacing: 2) {
            Button {
                guard let index, index > 0 else { return }
                slots.wrappedValue.swapAt(index, index - 1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(index == nil || index == 0)
            Button {
                guard let index, index < slots.wrappedValue.count - 1 else { return }
                slots.wrappedValue.swapAt(index, index + 1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(index == nil || index == slots.wrappedValue.count - 1)
        }
        .font(.caption)
    }

    // MARK: Load / apply

    private func loadSettings() async {
        if let settings = await load() {
            bedTypeValue = settings.bedType
            printSequence = settings.printSequence
            if let spiralMode = settings.spiralMode {
                spiral = spiralMode ? .on : .off
            } else {
                spiral = .defaultValue
            }
            firstLayer = Self.slots(
                sequence: settings.firstLayerSequence, extruders: filamentCount)
            otherLayers = Self.slots(
                sequence: settings.otherLayerSequence, extruders: filamentCount)
        } else {
            loadError = true
        }
        loaded = true
    }

    /// Enabled slots carry the loaded order; the remaining extruders follow
    /// unchecked so the user can add them without retyping.
    private static func slots(sequence: [Int]?, extruders: Int) -> [Slot] {
        let order = sequence ?? []
        var result: [Slot] = order
            .filter { $0 >= 1 && $0 <= extruders }
            .map { Slot(extruder: $0, enabled: true) }
        for extruder in 1...max(extruders, 1) where !order.contains(extruder) {
            result.append(Slot(extruder: extruder, enabled: false))
        }
        return result
    }

    private func apply() {
        dismiss()
        onApply(EnginePlater.PlateSettings(
            bedType: bedTypeValue,
            printSequence: printSequence,
            spiralMode: spiral == .defaultValue ? nil : spiral == .on,
            firstLayerSequence: Self.sequence(firstLayer),
            otherLayerSequence: Self.sequence(otherLayers)
        ))
    }

    /// The enabled extruders in displayed order; empty = default order.
    private static func sequence(_ slots: [Slot]) -> [Int]? {
        let enabled = slots.filter(\.enabled).map(\.extruder)
        return enabled.isEmpty ? nil : enabled
    }
}
