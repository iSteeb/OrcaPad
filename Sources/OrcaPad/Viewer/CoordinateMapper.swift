// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

import OrcaBridge
import simd

/// The only engine↔viewer coordinate policy. Engine values are z-up,
/// millimetres, with the bed origin wherever the machine profile puts it
/// (origin placement is machine-dependent: most cartesians corner-origin
/// like 0..200, some beds e.g. FLSun deltas are centered with min<0). The
/// viewer frame re-anchors on the bed's printable-area CENTER — derived from
/// the polygon, never assumed — mapping the engine y-axis to viewer -z.
struct EngineBed: Equatable, Sendable {
    var minX: Float
    var minY: Float
    var maxX: Float
    var maxY: Float

    /// Fallback square used before presets are available (proof-path parity
    /// with the original centered 256 mm bed).
    static let fallback = EngineBed(
        minX: -128, minY: -128, maxX: 128, maxY: 128
    )

    init(minX: Float, minY: Float, maxX: Float, maxY: Float) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    init(volume: PrintVolume) {
        self.init(
            minX: Float(volume.minX),
            minY: Float(volume.minY),
            maxX: Float(volume.maxX),
            maxY: Float(volume.maxY)
        )
    }

    var center: SIMD2<Float> {
        SIMD2((minX + maxX) / 2, (minY + maxY) / 2)
    }

    var size: SIMD2<Float> {
        SIMD2(maxX - minX, maxY - minY)
    }
}

enum CoordinateMapper {
    /// Engine point → viewer point, re-anchored on the bed center. Object-local
    /// geometry (pivot-subtracted meshes) passes a zero bed center.
    static func viewerPoint(
        fromEngine point: SIMD3<Float>,
        bedCenter: SIMD2<Float>
    ) -> SIMD3<Float> {
        SIMD3(point.x - bedCenter.x, point.z, -(point.y - bedCenter.y))
    }

    /// Viewer delta → engine delta (constant bed shifts cancel; pure inverse
    /// of the axis mapping).
    static func engineDelta(fromViewer delta: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(delta.x, -delta.z, delta.y)
    }

    /// Engine axis → viewer axis as a 4x4: (x, y, z) → (x, z, -y).
    static let engineToViewer = simd_float4x4(columns: (
        SIMD4<Float>(1, 0, 0, 0),
        SIMD4<Float>(0, 0, -1, 0),
        SIMD4<Float>(0, 1, 0, 0),
        SIMD4<Float>(0, 0, 0, 1)
    ))

    /// Viewer axis → engine axis: (x, y, z) → (x, -z, y).
    static let viewerToEngine = simd_float4x4(columns: (
        SIMD4<Float>(1, 0, 0, 0),
        SIMD4<Float>(0, 0, 1, 0),
        SIMD4<Float>(0, -1, 0, 0),
        SIMD4<Float>(0, 0, 0, 1)
    ))

    /// World axis direction in the viewer frame.
    static func viewerAxis(_ axis: EngineAxis) -> SIMD3<Float> {
        switch axis {
        case .x: return SIMD3(1, 0, 0)
        case .y: return SIMD3(0, 0, -1)
        case .z: return SIMD3(0, 1, 0)
        }
    }

    /// Viewer model matrix for an instance from the ENGINE's own instance
    /// matrix. Uploaded vertices are viewer-local `L(p - pivot)`, so:
    /// `L · T(-bedCenter) · M_engine · T(pivot) · L⁻¹`. No Euler re-derivation.
    static func modelMatrix(
        engineMatrix: simd_float4x4,
        enginePivot: SIMD3<Float>,
        bedCenter: SIMD2<Float>
    ) -> simd_float4x4 {
        engineToViewer
            * EngineMatrix.translation(SIMD3(-bedCenter.x, -bedCenter.y, 0))
            * engineMatrix
            * EngineMatrix.translation(enginePivot)
            * viewerToEngine
    }
}

/// Small engine-frame (z-up) matrix helpers used for live gesture previews
/// composed on top of the engine's authoritative instance matrix.
enum EngineMatrix {
    static func float(_ m: simd_double4x4) -> simd_float4x4 {
        simd_float4x4(columns: (
            SIMD4<Float>(m.columns.0), SIMD4<Float>(m.columns.1),
            SIMD4<Float>(m.columns.2), SIMD4<Float>(m.columns.3)
        ))
    }

    static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(columns: (
            SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0),
            SIMD4(0, 0, 1, 0), SIMD4(t.x, t.y, t.z, 1)
        ))
    }

    static func scale(_ s: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(diagonal: SIMD4(s.x, s.y, s.z, 1))
    }

    /// Right-handed rotation about a world axis (engine frame).
    static func rotation(_ axis: EngineAxis, radians: Float) -> simd_float4x4 {
        let c = cos(radians), s = sin(radians)
        switch axis {
        case .x:
            return simd_float4x4(columns: (
                SIMD4(1, 0, 0, 0), SIMD4(0, c, s, 0), SIMD4(0, -s, c, 0), SIMD4(0, 0, 0, 1)))
        case .y:
            return simd_float4x4(columns: (
                SIMD4(c, 0, -s, 0), SIMD4(0, 1, 0, 0), SIMD4(s, 0, c, 0), SIMD4(0, 0, 0, 1)))
        case .z:
            return simd_float4x4(columns: (
                SIMD4(c, s, 0, 0), SIMD4(-s, c, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1)))
        }
    }

    static func origin(_ m: simd_float4x4) -> SIMD3<Float> {
        SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
    }
}
