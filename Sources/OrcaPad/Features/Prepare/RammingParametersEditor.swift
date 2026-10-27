// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

import SwiftUI

/// Desktop RammingDialog parity for `filament_ramming_parameters`: the
/// option is ONE string per filament — "<line width %> <spacing %>
/// <speed per 0.25 s segment>… | <volume> <speed>…" (the
/// chart buttons are the volume→speed pairs after the "|"). Desktop
/// edits it as a draggable chart; OrcaPad edits the same sections as a
/// table with steppers (add/remove rows, one Apply commit through the same
/// per-key path the generic editors use).
///
/// Rendered by SettingsPagesView only for the single-extruder (scalar)
/// case — desktop's dialog also edits slot 0 only; multi-filament vectors
/// keep the raw serialized editor.
struct RammingParametersEditor: View {
    static let optionKey = "filament_ramming_parameters"

    let value: String
    let onCommit: (String) -> Void

    @State private var editingPresented = false
    @State private var draft = Parameters()

    // MARK: value model

    struct Segment: Equatable {
        var volume: Double
        var speed: Double
    }

    struct Parameters: Equatable {
        /// Ramming line width multiplicator (%).
        var lineWidthPercent: Double = 120
        /// Ramming line spacing multiplicator (%).
        var spacingPercent: Double = 100
        /// Extrusion speed per 0.25 s step of the ramming line (the part
        /// the engine consumes).
        var speeds: [Double] = []
        /// Chart buttons: cumulative volume (mm³) → speed.
        var segments: [Segment] = []

        /// Parses the desktop serialization; nil when malformed.
        static func parse(_ serialized: String) -> Parameters? {
            let halves = serialized.split(
                separator: "|", maxSplits: 1, omittingEmptySubsequences: false
            )
            guard halves.count == 1 || halves.count == 2 else { return nil }
            let leftTokens = halves[0].split(separator: " ").map(String.init)
            guard leftTokens.count >= 2,
                  let lineWidth = Double(leftTokens[0]),
                  let spacing = Double(leftTokens[1])
            else { return nil }
            var speeds: [Double] = []
            for token in leftTokens.dropFirst(2) {
                guard let speed = Double(token) else { return nil }
                speeds.append(speed)
            }
            var segments: [Segment] = []
            if halves.count == 2 {
                let rightTokens = halves[1].split(separator: " ").map(String.init)
                guard rightTokens.count % 2 == 0 else { return nil }
                var index = 0
                while index < rightTokens.count {
                    guard let volume = Double(rightTokens[index]),
                          let speed = Double(rightTokens[index + 1])
                    else { return nil }
                    segments.append(Segment(volume: volume, speed: speed))
                    index += 2
                }
            }
            return Parameters(
                lineWidthPercent: lineWidth,
                spacingPercent: spacing,
                speeds: speeds,
                segments: segments
            )
        }

        /// Desktop `RammingPanel::get_parameters` serialization: two
        /// multiplicators, the speed series, "|" then the volume→speed
        /// pairs.
        var serialized: String {
            var tokens = [Self.number(lineWidthPercent), Self.number(spacingPercent)]
            tokens.append(contentsOf: speeds.map(Self.number))
            var result = tokens.joined(separator: " ")
            if !segments.isEmpty {
                result += "|" + segments
                    .map { " \(Self.number($0.volume)) \(Self.number($0.speed))" }
                    .joined()
            }
            return result
        }

        static func number(_ value: Double) -> String {
            String(format: "%g", value)
        }
    }

    private var current: Parameters? {
        Parameters.parse(value)
    }

    // MARK: inline row (summary + sheet entry, like the multiline editor)

    var body: some View {
        Button {
            if let parsed = current {
                draft = parsed
            }
            editingPresented = true
        } label: {
            Label(summary, systemImage: "chart.bar.doc.horizontal")
                .font(.caption)
        }
        .buttonStyle(.bordered)
        .sheet(isPresented: $editingPresented) { editorSheet }
    }

    private var summary: String {
        guard let parsed = current else { return "Edit" }
        return "\(parsed.speeds.count) steps \u{00b7} \(parsed.segments.count) segments"
    }

    // MARK: sheet

    private var editorSheet: some View {
        NavigationStack {
            Form {
                Section {
                    stepperRow(
                        "Line width",
                        value: $draft.lineWidthPercent,
                        range: 10...300,
                        step: 5,
                        suffix: "%"
                    )
                    stepperRow(
                        "Spacing",
                        value: $draft.spacingPercent,
                        range: 10...300,
                        step: 5,
                        suffix: "%"
                    )
                } header: {
                    Text("Ramming line")
                } footer: {
                    Text("Multiplicators of the ramming line width and step, in percent of the nozzle width.")
                }
                Section {
                    ForEach(Array(draft.speeds.indices), id: \.self) { index in
                        HStack {
                            stepperRow(
                                "Step \(index + 1)",
                                value: speedBinding(index),
                                range: 0...30,
                                step: 0.5
                            )
                            removeButton { draft.speeds.remove(at: index) }
                        }
                    }
                    Button {
                        draft.speeds.append(draft.speeds.last ?? 6.6)
                    } label: {
                        Label("Add step", systemImage: "plus.circle")
                    }
                } header: {
                    Text("Speed series")
                } footer: {
                    Text("Extrusion speed for every 0.25 s piece of the ramming line (mm\u{00b3}/s).")
                }
                Section {
                    ForEach(Array(draft.segments.indices), id: \.self) { index in
                        HStack {
                            stepperRow(
                                "Volume",
                                value: segmentVolumeBinding(index),
                                range: 0...20,
                                step: 0.05,
                                suffix: "mm\u{00b3}"
                            )
                            stepperRow(
                                "Speed",
                                value: segmentSpeedBinding(index),
                                range: 0...30,
                                step: 0.5
                            )
                            removeButton { draft.segments.remove(at: index) }
                        }
                    }
                    Button {
                        let last = draft.segments.last
                        draft.segments.append(Segment(
                            volume: (last?.volume ?? 0) + 0.5,
                            speed: last?.speed ?? 6.6
                        ))
                    } label: {
                        Label("Add segment", systemImage: "plus.circle")
                    }
                } header: {
                    Text("Segments (volume \u{2192} speed)")
                } footer: {
                    Text("Ramming denotes the rapid extrusion just before a tool change in a single-extruder MM printer. Incorrect adjustment will likely lead to jams or extruder wheel grinding into filament (expert-level setting).")
                }
            }
            .navigationTitle("Ramming")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { editingPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        let serialized = draft.serialized
                        if serialized != value { onCommit(serialized) }
                        editingPresented = false
                    }
                    .disabled(draft.speeds.isEmpty)
                }
            }
        }
        .presentationDetents([.large])
    }

    // MARK: sheet helpers

    private func stepperRow(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        suffix: String = ""
    ) -> some View {
        HStack {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(Parameters.number(value.wrappedValue))\(suffix.isEmpty ? "" : " \(suffix)")")
                .font(.callout.monospacedDigit())
            Stepper("", value: value, in: range, step: step)
                .labelsHidden()
        }
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "minus.circle")
                .foregroundStyle(Color.red)
        }
        .buttonStyle(.borderless)
    }

    private func speedBinding(_ index: Int) -> Binding<Double> {
        Binding(
            get: { index < draft.speeds.count ? draft.speeds[index] : 0 },
            set: { if index < draft.speeds.count { draft.speeds[index] = $0 } }
        )
    }

    private func segmentVolumeBinding(_ index: Int) -> Binding<Double> {
        Binding(
            get: { index < draft.segments.count ? draft.segments[index].volume : 0 },
            set: {
                if index < draft.segments.count {
                    draft.segments[index].volume = $0
                }
            }
        )
    }

    private func segmentSpeedBinding(_ index: Int) -> Binding<Double> {
        Binding(
            get: { index < draft.segments.count ? draft.segments[index].speed : 0 },
            set: {
                if index < draft.segments.count {
                    draft.segments[index].speed = $0
                }
            }
        )
    }
}
