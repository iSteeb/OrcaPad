// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

import Observation
import simd
import OrcaBridge
import SwiftUI

// MARK: - Camera orientation channel (renderer → navigator overlay)

/// The camera's orbit angles (viewer frame) at the last drawn frame.
struct CameraOrientation: Equatable, Sendable {
    var yaw: Float
    var pitch: Float
}

/// Renderer → SwiftUI channel for the 3D navigator (ObjectLabelCenter
/// pattern): the renderer publishes from its draw pass (main actor), the
/// navigator overlay redraws the cube. `update` drops identical frames so
/// an idle camera does not churn SwiftUI at 60 fps.
@MainActor
@Observable
final class CameraOrientationCenter {
    static let shared = CameraOrientationCenter()

    private(set) var orientation = CameraOrientation(yaw: -0.65, pitch: 0.42)

    private init() {}

    /// Publishes the current camera orientation.
    func update(_ orientation: CameraOrientation) {
        guard orientation != self.orientation else { return }
        self.orientation = orientation
    }
}

// MARK: - 3D navigator cube (desktop "Show 3D Navigator")

/// Small corner cube mirroring the camera's orientation with tappable face
/// labels (Top / Bottom / Front / Rear / Left / Right — desktop Show 3D
/// Navigator parity). Pure SwiftUI: the cube edges are projected from the
/// published camera yaw/pitch each frame; a face tap applies the matching
/// desktop camera view preset. No Metal involved.
struct NavigatorCube: View {
    let onSelect: (CameraViewPreset) -> Void

    /// Half cube edge length in points.
    private let half: CGFloat = 26

    /// One labeled cube face: the viewer-frame outward direction of the
    /// face (engine axes mapped through CoordinateMapper's
    /// (x, y, z)e→(x, z, −y)v) and the camera preset a tap applies.
    private struct Face {
        let label: String
        let preset: CameraViewPreset
        let direction: SIMD3<Float>
    }

    private let faces: [Face] = [
        Face(label: "Top", preset: .top, direction: SIMD3(0, 1, 0)),
        Face(label: "Front", preset: .front, direction: SIMD3(0, 0, 1)),   // engine −Y
        Face(label: "Right", preset: .right, direction: SIMD3(1, 0, 0)),  // engine +X
        Face(label: "Rear", preset: .rear, direction: SIMD3(0, 0, -1)),   // engine +Y
        Face(label: "Left", preset: .left, direction: SIMD3(-1, 0, 0)),
        Face(label: "Bottom", preset: .bottom, direction: SIMD3(0, -1, 0)),
    ]

    /// Reading the center's orientation in `body` subscribes this view to
    /// the renderer's per-frame publication (ObjectLabelsOverlay pattern).
    private var orientation: CameraOrientation {
        CameraOrientationCenter.shared.orientation
    }

    var body: some View {
        Canvas { context, _ in
            let corners = cubeCorners()
            // 12 cube edges (corner indices over ±x ±y ±z bits).
            let edges: [(Int, Int)] = [
                (0, 1), (1, 3), (3, 2), (2, 0),  // -z face
                (4, 5), (5, 7), (7, 6), (6, 4),  // +z face
                (0, 4), (1, 5), (2, 6), (3, 7),
            ]
            for (a, b) in edges {
                var path = Path()
                path.move(to: corners[a])
                path.addLine(to: corners[b])
                context.stroke(
                    path,
                    with: .color(Color.secondary.opacity(0.55)),
                    lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
        .overlay {
            // Face labels at the projected face centers: front-facing
            // labels are bright and tappable, back-facing ones dim (like
            // the desktop navigator's far-side hint).
            ForEach(faces, id: \.label) { face in
                let projected = project(face.direction)
                Button {
                    onSelect(face.preset)
                } label: {
                    Text(face.label)
                        .font(.system(size: 8, weight: .semibold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .foregroundStyle(facing(face.direction) ? Color.primary : Color.secondary)
                        .background(
                            Color(.systemBackground).opacity(
                                facing(face.direction) ? 0.75 : 0.35),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .opacity(facing(face.direction) ? 1 : 0.55)
                .position(x: projected.x, y: projected.y)
                .disabled(!facing(face.direction))
            }
        }
        .frame(width: 92, height: 92)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial)
                .opacity(0.55)
        }
    }

    // MARK: Projection (viewer frame → cube-local 2D)

    /// Camera basis from yaw/pitch (OrbitCamera's eye geometry): screen
    /// right/up for a direction d place it as (dot(d, right), dot(d, up)).
    private var cameraBasis: (right: SIMD3<Float>, up: SIMD3<Float>,
                              forward: SIMD3<Float>) {
        let cp = cos(orientation.pitch)
        let forward = -simd_normalize(SIMD3<Float>(
            cp * cos(orientation.yaw), sin(orientation.pitch), cp * sin(orientation.yaw)))
        let worldUp = SIMD3<Float>(0, 1, 0)
        let right = simd_normalize(simd_cross(forward, worldUp))
        let up = simd_cross(right, forward)
        return (right, up, forward)
    }

    /// Projects a cube-local direction onto the view's 2D points (the
    /// view is fixed at 92×92; its center is the anchor).
    private func project(_ direction: SIMD3<Float>) -> CGPoint {
        let basis = cameraBasis
        let dotRight: Float = simd_dot(direction, basis.right)
        let dotUp: Float = simd_dot(direction, basis.up)
        // Slight perspective foreshortening toward the back.
        let depth: Float = simd_dot(direction, basis.forward)
        let scale: Float = 1 - 0.18 * max(depth, 0)
        let px: CGFloat = 46 + CGFloat(dotRight) * half * CGFloat(scale)
        let py: CGFloat = 46 - CGFloat(dotUp) * half * CGFloat(scale)
        return CGPoint(x: px, y: py)
    }

    /// Whether a face's outward direction points toward the camera.
    private func facing(_ direction: SIMD3<Float>) -> Bool {
        simd_dot(direction, cameraBasis.forward) < 0
    }

    /// The 8 projected cube corners (bit order x, y, z over ±half).
    private func cubeCorners() -> [CGPoint] {
        var points: [CGPoint] = []
        points.reserveCapacity(8)
        for bits in 0..<8 {
            let sx: Float = bits & 1 != 0 ? 1 : -1
            let sy: Float = bits & 2 != 0 ? 1 : -1
            let sz: Float = bits & 4 != 0 ? 1 : -1
            points.append(project(SIMD3(sx, sy, sz)))
        }
        return points
    }
}
