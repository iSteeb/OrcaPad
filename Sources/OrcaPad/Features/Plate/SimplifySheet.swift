// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

import SwiftUI

/// Desktop Simplify gizmo (GLGizmoSimplify subset): decimate the selected
/// object's mesh by ratio or toward a triangle count, with the desktop
/// quality presets as the quadric max error (Fine 0.001 / Standard 0.01 /
/// Coarse 0.1 / Aggressive 1.0). Presentation only — the mutation runs
/// through `DocumentStore.simplifySelected` (one undo step).
struct SimplifySheet: View {
    let objectName: String
    /// Current merged-mesh triangle count (snapshot index count / 3).
    let triangleCount: Int
    let isBusy: Bool
    let onApply: (_ useCount: Bool, _ wantedCount: UInt32, _ maxError: Double) -> Void

    /// Decimation ratio % / wanted triangle count (desktop radio buttons).
    private enum Mode: Hashable {
        case ratio
        case count
    }

    /// Desktop quadric-quality presets (GLGizmoSimplify max error).
    private enum Quality: Double, CaseIterable, Identifiable {
        case fine = 0.001
        case standard = 0.01
        case coarse = 0.1
        case aggressive = 1.0

        var id: Double { rawValue }

        var label: String {
            switch self {
            case .fine: return "Fine"
            case .standard: return "Standard"
            case .coarse: return "Coarse"
            case .aggressive: return "Aggressive"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .ratio
    @State private var ratioPercent = 50.0
    @State private var wantedCountText = ""
    @State private var quality: Quality = .standard
    @State private var rejection: String?

    private var wantedCount: UInt32? {
        guard let parsed = UInt32(wantedCountText.trimmingCharacters(in: .whitespaces)),
              parsed > 0, Int(parsed) < triangleCount
        else { return nil }
        return parsed
    }

    /// Live triangle-count estimate: current × (100 − ratio) / 100 in ratio
    /// mode, the typed count itself in count mode.
    private var estimate: Int? {
        mode == .ratio
            ? Int((Double(triangleCount) * (100 - ratioPercent) / 100).rounded())
            : wantedCount.map(Int.init)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Simplify \(objectName)") {
                    Picker("Mode", selection: $mode) {
                        Text("Decimate ratio").tag(Mode.ratio)
                        Text("Triangle count").tag(Mode.count)
                    }
                    .pickerStyle(.segmented)
                    if mode == .ratio {
                        VStack(alignment: .leading) {
                            Text("Ratio")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack {
                                Slider(value: $ratioPercent, in: 5...95, step: 1)
                                Text(String(format: "%.0f%%", ratioPercent))
                                    .font(.caption.monospacedDigit())
                                    .frame(width: 44, alignment: .trailing)
                            }
                        }
                        Picker("Quality", selection: $quality) {
                            ForEach(Quality.allCases) { candidate in
                                Text("\(candidate.label) (\(candidate.rawValue))")
                                    .tag(candidate)
                            }
                        }
                        .pickerStyle(.segmented)
                    } else {
                        HStack {
                            Text("Triangles")
                                .foregroundStyle(.secondary)
                            TextField("e.g. \(max(triangleCount / 2, 1))", text: $wantedCountText)
                                .keyboardType(.numberPad)
                                .font(.callout.monospacedDigit())
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 120)
                                .textFieldStyle(.roundedBorder)
                            Text("of \(triangleCount)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    if let rejection {
                        Label(rejection, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                    Button(role: .destructive) {
                        apply()
                    } label: {
                        Label("Simplify", systemImage: "arrow.down.right.and.arrow.up.left")
                    }
                    .disabled(isBusy || triangleCount == 0)
                } footer: {
                    Text(footerText)
                }
            }
            .navigationTitle("Simplify")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var footerText: String {
        let estimateNote: String
        if let estimate {
            estimateNote = "Current mesh: \(triangleCount) triangles → about \(estimate)."
        } else {
            estimateNote = "Current mesh: \(triangleCount) triangles."
        }
        return "\(estimateNote) Quadric edge collapse in one undo step; quality = allowed error (smaller keeps more detail)."
    }

    private func apply() {
        rejection = nil
        switch mode {
        case .ratio:
            guard ratioPercent >= 5, ratioPercent <= 95 else {
                rejection = "Ratio must be between 5% and 95%"
                return
            }
            dismiss()
            onApply(false, 0, quality.rawValue)
        case .count:
            guard let count = wantedCount else {
                rejection = "Enter a triangle count between 1 and \(max(triangleCount - 1, 1))"
                return
            }
            dismiss()
            onApply(true, count, 0)
        }
    }
}
