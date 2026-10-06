import OrcaBridge
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
    /// Machine bed grid from the selected printer's print volume, rendered in
    /// the bed-centered viewer frame. `bed` is in engine (z-up) millimetres;
    /// minor lines every 16 mm, bright border.
    static func bedGrid(for bed: EngineBed, minor: Float = 16) -> [VertexPC] {
        let center = bed.center
        var verts: [VertexPC] = []
        let dim = SIMD4<Float>(0.14, 0.15, 0.18, 1)   // minor grid lines
        let bright = SIMD4<Float>(0.34, 0.36, 0.42, 1) // border

        func viewer(_ x: Float, _ y: Float) -> SIMD3<Float> {
            CoordinateMapper.viewerPoint(
                fromEngine: SIMD3(x, y, 0),
                bedCenter: center
            )
        }

        let step = minor > 0 ? minor : 16
        // Lines of constant engine x
        var x = bed.minX
        while x <= bed.maxX {
            let isEdge = x == bed.minX || x == bed.maxX
            let c = isEdge ? bright : dim
            verts.append(VertexPC(position: viewer(x, bed.minY), color: c))
            verts.append(VertexPC(position: viewer(x, bed.maxY), color: c))
            x += step
        }
        // Lines of constant engine y
        var y = bed.minY
        while y <= bed.maxY {
            let isEdge = y == bed.minY || y == bed.maxY
            let c = isEdge ? bright : dim
            verts.append(VertexPC(position: viewer(bed.minX, y), color: c))
            verts.append(VertexPC(position: viewer(bed.maxX, y), color: c))
            y += step
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
    /// Expands an owned engine-space mesh into viewer-space, per-face
    /// duplicated vertices with flat normals. The object pivot is removed
    /// here and restored by CoordinateMapper.modelMatrix per instance.
    static func expandFlat(mesh: SceneMesh) -> (verts: [VertexPNC], idx: [UInt32]) {
        guard !mesh.positions.isEmpty,
              !mesh.indices.isEmpty,
              mesh.indices.count.isMultiple(of: 3),
              mesh.indices.allSatisfy({ Int($0) < mesh.positions.count }) else {
            return ([], [])
        }
        func point(_ index: Int) -> SIMD3<Float> {
            // Object-local frame: the pivot is already subtracted and the
            // bed anchor is applied per-instance by CoordinateMapper.
            CoordinateMapper.viewerPoint(
                fromEngine: mesh.positions[index] - mesh.pivot,
                bedCenter: .zero
            )
        }
        var verts: [VertexPNC] = []
        verts.reserveCapacity(mesh.indices.count)
        for triangle in 0..<(mesh.indices.count / 3) {
            let a = point(Int(mesh.indices[triangle * 3]))
            let b = point(Int(mesh.indices[triangle * 3 + 1]))
            let c = point(Int(mesh.indices[triangle * 3 + 2]))
            var normal = simd_cross(b - a, c - a)
            let length = simd_length(normal)
            normal = length > 1e-12
                ? normal / length
                : SIMD3<Float>(repeating: 0)
            verts.append(VertexPNC(position: a, normal: normal))
            verts.append(VertexPNC(position: b, normal: normal))
            verts.append(VertexPNC(position: c, normal: normal))
        }
        // Face-duplicated vertices need sequential indices.
        return (verts, (0..<verts.count).map { UInt32($0) })
    }
}
