// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

import OrcaBridge
import SwiftUI

/// Desktop GLGizmoBrimEars input window (PaintPanel pattern): ear diameter,
/// auto-detection parameters (max angle / detection length), Auto-generate,
/// Remove selected / Remove all and the brim-type hint. Presentation only —
/// the ear cache and mutations belong to DocumentStore.
struct BrimEarsPanel: View {
    /// Placed ears (count + selection state for the buttons).
    let earCount: Int
    let selectedIndex: Int?
    let isBusy: Bool
    /// Ear diameter in mm (desktop "Head diameter" = radius × 2; the engine
    /// default — initial_layer_line_width × 16 ≈ 6.5 mm on a 0.4 nozzle).
    @Binding var diameter: Double
    /// Auto-detect: contour corners past this angle (desktop default 125°).
    @Binding var maxAngleDeg: Double
    /// Auto-detect: corner detection length in mm (desktop default 1).
    @Binding var detectionLength: Double
    let onAutoGenerate: () -> Void
    let onRemoveSelected: () -> Void
    let onRemoveAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "ear")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                Text(headline)
                    .font(.callout.monospacedDigit().weight(.semibold))
                Spacer(minLength: 8)
                Button {
                    onAutoGenerate()
                } label: {
                    Label("Auto-generate", systemImage: "wand.and.rays")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .disabled(isBusy)
                Button(role: .destructive) {
                    onRemoveSelected()
                } label: {
                    Label("Remove selected", systemImage: "minus.circle")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .disabled(isBusy || selectedIndex == nil)
                Button(role: .destructive) {
                    onRemoveAll()
                } label: {
                    Label("Remove all", systemImage: "eraser")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .disabled(isBusy || earCount == 0)
            }
            HStack(spacing: 8) {
                Image(systemName: "circle.dotted")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Slider(value: $diameter, in: 1...20, step: 0.5)
                Text(String(format: "%.1f mm", diameter))
                    .font(.caption.monospacedDigit())
                    .frame(width: 60, alignment: .trailing)
                    .foregroundStyle(.secondary)
                Divider().frame(height: 20)
                Text("Max angle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Slider(value: $maxAngleDeg, in: 90...180, step: 1)
                Text(String(format: "%.0f°", maxAngleDeg))
                    .font(.caption.monospacedDigit())
                    .frame(width: 36, alignment: .trailing)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text("Detection length")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Slider(value: $detectionLength, in: 0.1...10, step: 0.1)
                Text(String(format: "%.1f mm", detectionLength))
                    .font(.caption.monospacedDigit())
                    .frame(width: 60, alignment: .trailing)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            Label(
                "Tap the object to add an ear at bed level; tap an ear to select it. "
                    + "Slicing uses the ears when brim type = Painted (brim ears).",
                systemImage: "info.circle"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 12)
        .disabled(isBusy)
    }

    private var headline: String {
        if earCount == 0 {
            return "no ears placed"
        }
        var text = "\(earCount) ear(s)"
        if selectedIndex != nil { text += " · 1 selected" }
        return text
    }
}
