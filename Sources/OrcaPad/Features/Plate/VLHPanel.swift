// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

import OrcaBridge
import SwiftUI

/// Desktop variable layer height panel
/// (GLCanvas3D::LayersEditing::render_variable_layer_height_dialog,
/// GLCanvas3D.cpp:229 — PaintPanel pattern): the drag-adjust parameters
/// (action / thickness delta / band width), Adaptive (quality), Smooth
/// (radius + keep min), Reset and the current profile stats. Presentation
/// only — the engine calls and one-undo-step-per-action semantics live in
/// `DocumentStore`.
struct VLHPanel: View {
    /// Profile stats (nil = uniform — the object uses the process height).
    let stats: (minHeight: Double, maxHeight: Double, layerEstimate: Int)?
    /// Resolved process layer height (uniform display).
    let layerHeight: Double
    /// Resolved machine min/max (slider bounds context).
    let minLayerHeight: Double
    let maxLayerHeight: Double
    let isBusy: Bool
    /// Adjust parameters (store-owned; desktop `strength` + `band_width`).
    let thicknessDelta: Double
    let bandWidth: Double
    /// Engine LayerHeightEditActionType (0 increase, 1 decrease,
    /// 2 reduce, 3 smooth).
    let action: Int32
    let onChangeDelta: (Double) -> Void
    let onChangeBand: (Double) -> Void
    let onChangeAction: (Int32) -> Void
    let onAdaptive: (Double) -> Void
    let onSmooth: (_ radius: UInt32, _ keepMin: Bool) -> Void
    let onReset: () -> Void

    /// Desktop keeps quality/radius/keep-min as gizmo state
    /// (m_adaptive_quality 0.5, m_smooth_params), so the panel owns them.
    @State private var quality = 0.5
    @State private var radius = 3
    @State private var keepMin = false

    /// Desktop action labels (tooltip table, GLCanvas3D.cpp:316-322).
    private let actions: [(label: String, symbol: String, value: Int32)] = [
        ("Increase", "plus.circle", 0),
        ("Decrease", "minus.circle", 1),
        ("Reset to base", "arrow.uturn.backward.circle", 2),
        ("Smooth", "water.waves", 3),
    ]

    private var currentAction: (label: String, symbol: String, value: Int32) {
        actions.first { $0.value == action } ?? actions[0]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Row 1: stats + Reset.
            HStack(spacing: 8) {
                Image(systemName: "square.3.layers.3d.top.down.forward")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                Text(statsHeadline)
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(String(format: "machine %.2f–%.2f", minLayerHeight, maxLayerHeight))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Spacer(minLength: 8)
                Button(role: .destructive, action: onReset) {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .disabled(isBusy)
            }
            // Row 2: drag-adjust parameters — the action picker plus the
            // thickness-delta and band-width sliders (desktop strength +
            // mouse-wheel band).
            HStack(spacing: 8) {
                Menu {
                    ForEach(Array(actions.enumerated()), id: \.offset) { _, candidate in
                        Button {
                            onChangeAction(candidate.value)
                        } label: {
                            Label(candidate.label, systemImage: candidate.symbol)
                        }
                    }
                } label: {
                    Label(currentAction.label, systemImage: currentAction.symbol)
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                Image(systemName: "circle.dotted")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Slider(value: .init(
                    get: { thicknessDelta },
                    set: { onChangeDelta($0) }
                ), in: 0.001...0.05, step: 0.001)
                Text(String(format: "±%.3f", thicknessDelta))
                    .font(.caption.monospacedDigit())
                    .frame(width: 44, alignment: .trailing)
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.up.and.down.horizontal.line")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Slider(value: .init(
                    get: { bandWidth },
                    set: { onChangeBand($0) }
                ), in: 0.5...20, step: 0.5)
                Text(String(format: "%.1f", bandWidth))
                    .font(.caption.monospacedDigit())
                    .frame(width: 32, alignment: .trailing)
                    .foregroundStyle(.secondary)
            }
            // Row 3: Adaptive quality + Smooth radius/keep-min.
            HStack(spacing: 8) {
                Button {
                    onAdaptive(quality)
                } label: {
                    Label("Adaptive", systemImage: "wand.and.rays")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .disabled(isBusy)
                Slider(value: $quality, in: -0.1...1, step: 0.05)
                Text(qualityText)
                    .font(.caption.monospacedDigit())
                    .frame(width: 56, alignment: .trailing)
                    .foregroundStyle(.secondary)
                Divider().frame(height: 20)
                Button {
                    onSmooth(UInt32(radius), keepMin)
                } label: {
                    Label("Smooth", systemImage: "water")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .disabled(isBusy)
                Stepper("Radius", value: $radius, in: 1...200)
                    .fixedSize()
                Button {
                    keepMin.toggle()
                } label: {
                    Label("Keep min", systemImage: keepMin ? "checkmark.circle.fill" : "circle")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .tint(keepMin ? Color.accentColor : Color.secondary)
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 12)
        .disabled(isBusy)
    }

    /// Stats headline: the profile range + layer estimate, or the uniform
    /// process height (desktop's fixed-profile annotation is the slicing
    /// result; OrcaPad shows the curve numbers).
    private var statsHeadline: String {
        if let stats {
            return String(
                format: "%.2f–%.2f mm · ~%d layers",
                stats.minHeight, stats.maxHeight, stats.layerEstimate)
        }
        return String(format: "uniform · %.2f mm", layerHeight)
    }

    /// Desktop labels the slider "Quality / Speed" over 0..1 (the Bridge
    /// range is −0.1..1); the percent display maps that range to 0–100 %.
    private var qualityText: String {
        let percent = (quality + 0.1) / 1.1 * 100
        return String(format: "%.0f %%", percent)
    }
}

/// The VLH axis labels over the Plate 3D canvas: z ticks on the strip's
/// left edge, the layer-height axis under the strip and the live drag chip
/// (renderer-published through VLHLabelCenter — the MeasureLabelOverlay
/// pattern; non-interactive, touches pass through to the canvas).
struct VLHLabelOverlay: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(VLHLabelCenter.shared.labels) { label in
                Text(label.text)
                    .font(label.accent
                          ? .caption.weight(.semibold).monospacedDigit()
                          : .caption2.monospacedDigit())
                    .padding(.horizontal, label.accent ? 7 : 4)
                    .padding(.vertical, label.accent ? 3 : 1)
                    .foregroundStyle(label.accent ? Color.white : Color.secondary)
                    .background(
                        label.accent
                            ? Color.accentColor.opacity(0.85)
                            : Color(.systemBackground).opacity(0.55),
                        in: Capsule()
                    )
                    .position(x: label.point.x, y: label.point.y)
            }
        }
        .allowsHitTesting(false)
    }
}
