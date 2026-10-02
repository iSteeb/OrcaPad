import simd

// MARK: - Vertex formats (must match the vertex descriptors in Renderer)

/// Lit triangle vertices: position + normal.
struct VertexPNC: Sendable {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
}

/// Unlit line vertices: position + color.
struct VertexPC: Sendable {
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

// MARK: - Engine mesh → viewer mesh

extension Geometry {
    /// Expands an indexed position-only mesh (engine output) into per-face
    /// duplicated vertices with flat normals — the viewer's lit format.
    static func expandFlat(positions: UnsafePointer<Float>?, positionCount: Int,
                           indices: UnsafePointer<UInt32>?, indexCount: Int)
        -> (verts: [VertexPNC], idx: [UInt32])
    {
        guard let positions, let indices, positionCount > 0, indexCount > 0 else { return ([], []) }
        let src = UnsafeBufferPointer(start: positions, count: positionCount * 3)
        let ip = UnsafeBufferPointer(start: indices, count: indexCount)
        func point(_ i: Int) -> SIMD3<Float> {
            SIMD3<Float>(src[i * 3], src[i * 3 + 1], src[i * 3 + 2])
        }
        var verts: [VertexPNC] = []
        verts.reserveCapacity(indexCount)
        for t in 0..<(indexCount / 3) {
            let a = point(Int(ip[t * 3]))
            let b = point(Int(ip[t * 3 + 1]))
            let c = point(Int(ip[t * 3 + 2]))
            var n = simd_cross(b - a, c - a)
            let len = simd_length(n)
            n = len > 1e-12 ? n / len : SIMD3<Float>(repeating: 0)
            verts.append(VertexPNC(position: a, normal: n))
            verts.append(VertexPNC(position: b, normal: n))
            verts.append(VertexPNC(position: c, normal: n))
        }
        return (verts, Array(ip))
    }
}
