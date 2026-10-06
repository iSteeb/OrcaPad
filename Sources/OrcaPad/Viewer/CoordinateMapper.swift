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

    static func modelMatrix(
        transform: InstanceTransform,
        enginePivot: SIMD3<Float>,
        bedCenter: SIMD2<Float>
    ) -> simd_float4x4 {
        let scale = Float(transform.scale)
        let angle = Float(transform.rotationZ)
        let c = cos(angle)
        let s = sin(angle)
        let scaledPivot = enginePivot * scale
        let rotatedPivot = SIMD3<Float>(
            c * scaledPivot.x - s * scaledPivot.y,
            s * scaledPivot.x + c * scaledPivot.y,
            scaledPivot.z
        )
        let engineAnchor = SIMD3<Float>(
            Float(transform.offsetX),
            Float(transform.offsetY),
            Float(transform.offsetZ)
        ) + rotatedPivot
        return Math.translate(
            viewerPoint(fromEngine: engineAnchor, bedCenter: bedCenter)
        )
            * Math.rotateY(angle)
            * Math.scale(scale)
    }
}
