import simd

// MARK: - Vertex formats (must match the vertex descriptors in Renderer)

/// Lit triangle vertices: position + normal.
struct VertexPNC {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
}

/// Unlit line vertices: position + color.
struct VertexPC {
    var position: SIMD3<Float>
    var color: SIMD4<Float>
}

// MARK: - Geometry builders

enum Geometry {
    /// Bambu-P1-style square bed grid, centred on origin in the XZ plane.
    static func bedGrid(size: Float = 256, minor: Float = 16) -> [VertexPC] {
        var verts: [VertexPC] = []
        let half = size / 2
        let dim = SIMD4<Float>(0.14, 0.15, 0.18, 1)   // minor grid lines
        let bright = SIMD4<Float>(0.34, 0.36, 0.42, 1) // border

        var i: Float = -half
        while i <= half {
            let isEdge = (i == -half || i == half)
            let c = isEdge ? bright : dim
            // Lines parallel to Z (varying X)
            verts.append(VertexPC(position: SIMD3<Float>(i, 0, -half), color: c))
            verts.append(VertexPC(position: SIMD3<Float>(i, 0, half), color: c))
            // Lines parallel to X (varying Z)
            verts.append(VertexPC(position: SIMD3<Float>(-half, 0, i), color: c))
            verts.append(VertexPC(position: SIMD3<Float>(half, 0, i), color: c))
            i += minor
        }
        return verts
    }

    /// Unit cube centred on the origin (scaled/positioned by the model matrix).
    static func unitCube() -> (vertices: [VertexPNC], indices: [UInt32]) {
        // (normal, tangent, bitangent) per face — consistent quad corners.
        let faces: [(n: SIMD3<Float>, t: SIMD3<Float>, b: SIMD3<Float>)] = [
            (SIMD3(0, 0, 1), SIMD3(1, 0, 0), SIMD3(0, 1, 0)),
            (SIMD3(0, 0, -1), SIMD3(-1, 0, 0), SIMD3(0, 1, 0)),
            (SIMD3(1, 0, 0), SIMD3(0, 0, -1), SIMD3(0, 1, 0)),
            (SIMD3(-1, 0, 0), SIMD3(0, 0, 1), SIMD3(0, 1, 0)),
            (SIMD3(0, 1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, -1)),
            (SIMD3(0, -1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 1)),
        ]
        var verts: [VertexPNC] = []
        var indices: [UInt32] = []
        let h: Float = 0.5
        for f in faces {
            let center = f.n * h
            let base = UInt32(verts.count)
            for (u, v) in [(-1.0, -1.0), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0)] {
                let p = center + f.t * (Float(u) * h) + f.b * (Float(v) * h)
                verts.append(VertexPNC(position: p, normal: f.n))
            }
            indices.append(contentsOf: [0, 1, 2, 0, 2, 3].map { $0 + base })
        }
        return (verts, indices)
    }
}
