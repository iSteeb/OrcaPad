// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

import Observation
import OrcaBridge
import SwiftUI

/// One published 3D object label (desktop GLCanvas3D::Labels::render,
/// GLCanvas3D.cpp:743-870): instance-anchored name chip in view POINTS of
/// the canvas — the SwiftUI overlay sits exactly over the canvas, so the
/// coordinates transfer 1:1.
struct ObjectLabel: Identifiable, Equatable, Sendable {
    let instanceID: InstanceID
    var id: InstanceID { instanceID }
    /// Object name + " (N)" for multi-instance objects (desktop
    /// `model_object->name` + instance suffix, GLCanvas3D.cpp:803-805).
    let text: String
    /// Projected world-bbox center (desktop anchors the same way,
    /// GLCanvas3D.cpp:835-843).
    let point: CGPoint
    /// Instance selection (desktop draws the selected chip's border
    /// orange, GLCanvas3D.cpp:846).
    let selected: Bool
}

/// Renderer → SwiftUI channel for the 3D object-labels overlay (View
/// menu "Labels", desktop GLCanvas3D.cpp:9253 → Plater.cpp:4494
/// show_view3D_labels).
///
/// The renderer is owned by MetalCanvas's coordinator and publishes from
/// its draw pass (main actor); the SwiftUI overlay above the canvas reads
/// `labels` and positions the chips. `update` drops identical frames so
/// an idle camera does not churn SwiftUI at 60 fps.
@MainActor
@Observable
final class ObjectLabelCenter {
    static let shared = ObjectLabelCenter()

    private(set) var labels: [ObjectLabel] = []

    private init() {}

    /// Publishes one frame's label set (empty = labels off / no objects).
    func update(_ labels: [ObjectLabel]) {
        guard labels != self.labels else { return }
        self.labels = labels
    }
}

/// Name chips over the Plate 3D canvas. Non-interactive: touches pass
/// through to the canvas gestures (the desktop ImGui labels set
/// ImGuiWindowFlags_NoMouseInputs, GLCanvas3D.cpp:845).
struct ObjectLabelsOverlay: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(ObjectLabelCenter.shared.labels) { label in
                Text(label.text)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .foregroundStyle(.primary)
                    .background(
                        .ultraThinMaterial,
                        in: Capsule()
                    )
                    .overlay(
                        Capsule().strokeBorder(
                            label.selected
                                ? Color.orange.opacity(0.9)
                                : Color.primary.opacity(0.25),
                            lineWidth: label.selected ? 1.5 : 0.5
                        )
                    )
                    .position(x: label.point.x, y: label.point.y)
            }
        }
        .allowsHitTesting(false)
    }
}
