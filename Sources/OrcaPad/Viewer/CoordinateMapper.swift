import OrcaBridge
import simd

/// The only engine↔viewer coordinate policy. Engine values are z-up;
/// Metal values are y-up with the engine y-axis mapped to viewer -z.
enum CoordinateMapper {
    static func viewerPoint(fromEngine point: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(point.x, point.z, -point.y)
    }

    static func engineDelta(fromViewer delta: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(delta.x, -delta.z, delta.y)
    }

    static func modelMatrix(
        transform: InstanceTransform,
        enginePivot: SIMD3<Float>
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
        return Math.translate(viewerPoint(fromEngine: engineAnchor))
            * Math.rotateY(angle)
            * Math.scale(scale)
    }
}
