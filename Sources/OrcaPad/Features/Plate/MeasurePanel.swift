// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

import OrcaBridge
import SwiftUI

/// Desktop GLGizmoMeasure readout panel (bottom bar, PaintPanel pattern):
/// distance / per-axis delta / angle between the two picked features plus
/// circle radius and plane area of the picks. The mm/in toggle is shared
/// with the 3D midpoint label (@AppStorage "units.inches"). Presentation
/// only — the measure session belongs to DocumentStore.
struct MeasurePanel: View {
    /// Picked features, slots A and B (nil until picked).
    let features: [EnginePlater.SurfaceFeature?]
    let result: EnginePlater.FeatureMeasurement?
    let onClear: () -> Void

    @AppStorage("units.inches") private var inches = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "ruler")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                headline
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Spacer(minLength: 8)
                Picker("Units", selection: $inches) {
                    Text("mm").tag(false)
                    Text("in").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 96)
                Button(role: .destructive, action: onClear) {
                    Label("Clear", systemImage: "xmark.circle")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
            }
            if result != nil || radius != nil || area != nil {
                HStack(spacing: 14) {
                    if let result {
                        if result.hasXYZ {
                            Text("ΔX \(length(result.xyz.x)) · ΔY \(length(result.xyz.y)) · ΔZ \(length(result.xyz.z))")
                        }
                        if result.hasAngle {
                            Text("∠ \(String(format: "%.1f°", result.angleRadians * 180 / .pi))")
                        }
                    }
                    if let radius {
                        Text("R \(length(radius))")
                    }
                    if let area {
                        Text("A \(areaText(area))")
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 12)
    }

    /// Headline row: the distance once measured, else a tap hint.
    private var headline: Text {
        if let result, result.hasDistance {
            return Text(length(result.distance))
        }
        if features.contains(where: { $0 != nil }) {
            return Text("Tap a second feature…")
        }
        return Text("Tap a point, edge, circle or face")
    }

    /// The first picked circle feature's radius, if any.
    private var radius: Double? {
        features.compactMap { $0 }.first { $0.kind == .circle }?.radius
    }

    /// The first picked plane feature's area (mm²), if any.
    private var area: Double? {
        features.compactMap { $0 }.first { $0.kind == .plane }?.area
    }

    /// mm/in formatting (the 3D label uses the same conversion).
    private func length(_ millimetres: Double) -> String {
        if inches {
            return String(format: "%.3f in", millimetres / 25.4)
        }
        return String(format: "%.2f mm", millimetres)
    }

    private func areaText(_ squareMillimetres: Double) -> String {
        if inches {
            return String(format: "%.2f in²", squareMillimetres / 645.16)
        }
        return String(format: "%.1f mm²", squareMillimetres)
    }
}

/// The measure distance chip at the projected measurement midpoint
/// (renderer-published through MeasureLabelCenter — the ObjectLabelsOverlay
/// pattern; non-interactive, touches pass through to the canvas).
struct MeasureLabelOverlay: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            if let label = MeasureLabelCenter.shared.label {
                Text(label.text)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .foregroundStyle(.white)
                    .background(Color.accentColor.opacity(0.85), in: Capsule())
                    .position(x: label.point.x, y: label.point.y)
            }
        }
        .allowsHitTesting(false)
    }
}

extension DocumentStore {
    /// Canvas measure-tap entry: routes the renderer's pick (merged-mesh
    /// triangle + raw object-space point, ABI v40) into the store's
    /// session handler.
    func handleMeasureTap(_ pick: Renderer.FacePick) async {
        await handleMeasureTap(
            objectID: pick.objectID,
            triangleIndex: pick.triangleIndex,
            objectPoint: pick.objectPoint
        )
    }
}
