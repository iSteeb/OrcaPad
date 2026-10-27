// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

import OrcaBridge
import SwiftUI

/// Desktop layer-height ranges editor (object list "Height ranges"): a
/// list of z-ranges, each with its own layer height, applied as ONE
/// replacement mutation through `DocumentStore.setHeightRanges` (the
/// engine's `ModelObject::layer_config_ranges`). Presentation only —
/// the document store owns the engine call, one undoable mutation per
/// Apply, failures surface through the status banner.
struct HeightRangesSheet: View {
    let objectID: ObjectID
    let objectName: String
    /// The object's own z span (scene snapshot mesh bounds) — field hints
    /// and client-side sanity only; the engine stays the authority.
    let zSpan: ClosedRange<Double>
    /// The ranges the object carries today. The contracted read
    /// (`EnginePlater.objectHeightRanges`) is a facade instance method no
    /// view can reach yet, so this starts empty until the coordinator
    /// wires a store read — until then the editor drafts from scratch and
    /// Apply REPLACES the engine state (a destructive edge documented on
    /// the Apply button).
    var initialRanges: [EnginePlater.HeightRange] = []
    /// Loads current ranges when the sheet appears (coordinator wiring:
    /// sheet(item:) closures are synchronous; the sheet fetches itself).
    var loadRanges: (() async -> [EnginePlater.HeightRange])? = nil

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [DraftRange] = []
    @State private var rejection: String?
    /// Resolved process `layer_height` — the seed for new rows.
    @State private var defaultLayerHeight: String?

    /// One editable z-range (string fields so the user can type freely;
    /// parsed and validated on Apply).
    struct DraftRange: Identifiable {
        let id = UUID()
        var minZ: String
        var maxZ: String
        var layerHeight: String
    }

    private var document: DocumentStore { environment.document }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if rows.isEmpty {
                        Text(initialRanges.isEmpty
                             ? "No height ranges — every layer uses the process layer height."
                             : "All ranges removed. Apply clears the object's ranges.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach($rows) { $row in
                        HeightRangeRow(row: $row)
                    }
                    .onDelete { rows.remove(atOffsets: $0) }
                    Button {
                        rows.append(newRow())
                    } label: {
                        Label("Add range", systemImage: "plus")
                    }
                    .disabled(document.isBusy)
                } header: {
                    Text(objectName.isEmpty ? "Ranges" : "\(objectName) · Ranges")
                } footer: {
                    Text("Object z span: \(format(zSpan.lowerBound)) … \(format(zSpan.upperBound)) mm. Each range prints with its own layer height instead of the process default.")
                }
                if let rejection {
                    Section {
                        Label(rejection, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("Height ranges")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(applyTitle, action: apply)
                        .disabled(rows.isEmpty && initialRanges.isEmpty || document.isBusy)
                }
            }
        }
        .onAppear {
            rows = initialRanges.map { range in
                DraftRange(
                    minZ: format(range.minZ),
                    maxZ: format(range.maxZ),
                    layerHeight: format(range.layerHeight)
                )
            }
        }
        .task { await loadDefaultLayerHeight() }
        .task {
            if let loadRanges, rows.isEmpty {
                let loaded = await loadRanges()
                if !loaded.isEmpty {
                    rows = loaded.map { range in
                        DraftRange(
                            minZ: String(range.minZ),
                            maxZ: String(range.maxZ),
                            layerHeight: String(range.layerHeight))
                    }
                }
            }
        }
.presentationDetents([.medium, .large])
    }

    /// Contextual Apply label: a replacement mutation, never ambiguous.
    private var applyTitle: String {
        switch rows.count {
        case 0: return "Remove all ranges"
        case 1: return "Apply 1 range"
        default: return "Apply \(rows.count) ranges"
        }
    }

    /// Seeds a new range after the last one (or at the object's base).
    private func newRow() -> DraftRange {
        let start = rows.last.flatMap { Double($0.maxZ) } ?? zSpan.lowerBound
        let width = max(zSpan.upperBound - start, 0) > 0
            ? min(10.0, zSpan.upperBound - start) : 10.0
        return DraftRange(
            minZ: format(start),
            maxZ: format(start + width),
            layerHeight: defaultLayerHeight ?? ""
        )
    }

    /// The resolved process layer height (seed for new rows), read exactly
    /// like the object-settings sheet reads its resolved seeds.
    private func loadDefaultLayerHeight() async {
        guard let engine = environment.presets.engineForSlicing else { return }
        let result = await BackgroundWork.run(operation: "read layer height") { () -> String in
            let json = try engine.resolvedConfig().get()
            guard let data = json.data(using: .utf8),
                  let values = try JSONSerialization.jsonObject(with: data) as? [String: String]
            else {
                throw AppFailure.invariant(
                    operation: "read layer height", diagnostic: "not a string map")
            }
            return values["layer_height"] ?? ""
        }
        switch result {
        case .success(let value):
            defaultLayerHeight = value.isEmpty ? nil : value
        case .failure(let failure):
            environment.status.report(.document, failure: failure)
        }
    }

    /// Validates every row, then applies the whole list as ONE replacement
    /// mutation. A committed mutation always advances the document
    /// revision, so the sheet closes only when the engine really applied
    /// it — a typed rejection keeps the draft for editing.
    private func apply() {
        var parsed: [(index: Int, minZ: Double, maxZ: Double, layerHeight: Double)] = []
        for (index, row) in rows.enumerated() {
            guard let minZ = number(row.minZ),
                  let maxZ = number(row.maxZ),
                  let layerHeight = number(row.layerHeight) else {
                rejection = "Range \(index + 1): every field must be a number"
                return
            }
            guard minZ < maxZ else {
                rejection = "Range \(index + 1): start must be below end"
                return
            }
            guard layerHeight > 0 else {
                rejection = "Range \(index + 1): layer height must be positive"
                return
            }
            parsed.append((index, minZ, maxZ, layerHeight))
        }
        let ordered = parsed.sorted { $0.minZ < $1.minZ }
        for (lhs, rhs) in zip(ordered, ordered.dropFirst()) where rhs.minZ < lhs.maxZ {
            rejection = "Ranges \(lhs.index + 1) and \(rhs.index + 1) overlap"
            return
        }
        rejection = nil
        let ranges = parsed.map { pair in
            EnginePlater.HeightRange(
                minZ: pair.minZ, maxZ: pair.maxZ, layerHeight: pair.layerHeight
            )
        }
        let revisionBefore = document.scene?.revision
        Task {
            _ = await document.setHeightRanges(objectID: objectID, ranges: ranges)
            if document.scene?.revision != revisionBefore {
                dismiss()
            }
        }
    }

    /// Accepts the localized decimal separator like every numeric field
    /// (comma-normalizing), matching the settings editor's tolerance.
    private func number(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: "."))
    }

    private func format(_ value: Double) -> String {
        value.rounded() == value
            ? String(Int(value))
            : String(format: "%.3g", value)
    }
}

/// One z-range row: start / end / layer height fields (mm).
private struct HeightRangeRow: View {
    @Binding var row: HeightRangesSheet.DraftRange

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                field("from z", text: $row.minZ)
                Text("to").foregroundStyle(.secondary).font(.caption)
                field("to z", text: $row.maxZ)
                Text("mm").foregroundStyle(.secondary).font(.caption)
            }
            HStack(spacing: 8) {
                Text("Layer height")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                field("0.2", text: $row.layerHeight)
                Text("mm").foregroundStyle(.secondary).font(.caption)
            }
        }
        .padding(.vertical, 2)
    }

    private func field(_ prompt: String, text: Binding<String>) -> some View {
        TextField(prompt, text: text)
            .keyboardType(.numbersAndPunctuation)
            .multilineTextAlignment(.trailing)
            .font(.callout.monospacedDigit())
            .frame(width: 72)
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
    }
}
