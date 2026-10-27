// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

import Foundation
import simd

enum HandyModelError: Error, LocalizedError, Sendable {
    /// The bundled STL is absent — a packaging/build regression, never a
    /// user-recoverable state (fail loudly).
    case missingFromBundle(String)
    /// A runtime-generated STL could not be written (disk full / sandbox).
    case generationWriteFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingFromBundle(let path):
            return "handy model is missing from the bundle: \(path)"
        case .generationWriteFailed(let id):
            return "handy model could not be generated: \(id)"
        }
    }
}

/// Minimal binary-STL mesh builder (pure Swift, no assets): boxes, solid
/// cylinders, annular tubes and pyramids with outward winding. Triangles
/// carry no explicit normal — the format's normals are advisory and the
/// engine's import repair recomputes them.
struct STLMesh: Sendable {
    struct Triangle: Sendable {
        var a: SIMD3<Float>
        var b: SIMD3<Float>
        var c: SIMD3<Float>
    }

    private(set) var triangles: [Triangle] = []

    mutating func addTriangle(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) {
        triangles.append(Triangle(a: a, b: b, c: c))
    }

    mutating func addQuad(
        _ a: SIMD3<Float>, _ b: SIMD3<Float>,
        _ c: SIMD3<Float>, _ d: SIMD3<Float>
    ) {
        addTriangle(a, b, c)
        addTriangle(a, c, d)
    }

    /// Axis-aligned box (engine z-up space).
    mutating func addBox(min m: SIMD3<Float>, max M: SIMD3<Float>) {
        let p000 = SIMD3(m.x, m.y, m.z), p100 = SIMD3(M.x, m.y, m.z)
        let p110 = SIMD3(M.x, M.y, m.z), p010 = SIMD3(m.x, M.y, m.z)
        let p001 = SIMD3(m.x, m.y, M.z), p101 = SIMD3(M.x, m.y, M.z)
        let p111 = SIMD3(M.x, M.y, M.z), p011 = SIMD3(m.x, M.y, M.z)
        addQuad(p000, p010, p110, p100)   // bottom (−z)
        addQuad(p001, p101, p111, p011)   // top (+z)
        addQuad(p000, p100, p101, p001)   // front (−y)
        addQuad(p010, p011, p111, p110)   // back (+y)
        addQuad(p000, p001, p011, p010)   // left (−x)
        addQuad(p100, p110, p111, p101)   // right (+x)
    }

    /// Solid cylinder along z (fan caps), CCW segments seen from +z.
    mutating func addCylinder(
        x: Float, y: Float, radius: Float,
        z0: Float, z1: Float, segments: Int = 24
    ) {
        var top: [SIMD3<Float>] = []
        var bottom: [SIMD3<Float>] = []
        for index in 0..<max(segments, 3) {
            let angle = Float(index) / Float(max(segments, 3)) * 2 * .pi
            let offset = SIMD3(cos(angle), sin(angle), 0) * radius
            top.append(SIMD3(x, y, z1) + offset)
            bottom.append(SIMD3(x, y, z0) + offset)
        }
        let count = top.count
        let topCenter = SIMD3(x, y, z1)
        let bottomCenter = SIMD3(x, y, z0)
        for index in 0..<count {
            let next = (index + 1) % count
            addQuad(top[index], bottom[index], bottom[next], top[next])
            addTriangle(topCenter, top[index], top[next])
            addTriangle(bottomCenter, bottom[next], bottom[index])
        }
    }

    /// Annular tube along z (a standing ring — an actual hole, no CSG):
    /// outer wall outward, inner wall inward, annulus caps both ends.
    mutating func addTube(
        x: Float, y: Float, outerRadius: Float, innerRadius: Float,
        z0: Float, z1: Float, segments: Int = 24
    ) {
        guard outerRadius > innerRadius, innerRadius > 0 else { return }
        var outerTop: [SIMD3<Float>] = []
        var outerBottom: [SIMD3<Float>] = []
        var innerTop: [SIMD3<Float>] = []
        var innerBottom: [SIMD3<Float>] = []
        for index in 0..<max(segments, 3) {
            let angle = Float(index) / Float(max(segments, 3)) * 2 * .pi
            let direction = SIMD3(cos(angle), sin(angle), 0)
            outerTop.append(SIMD3(x, y, z1) + direction * outerRadius)
            outerBottom.append(SIMD3(x, y, z0) + direction * outerRadius)
            innerTop.append(SIMD3(x, y, z1) + direction * innerRadius)
            innerBottom.append(SIMD3(x, y, z0) + direction * innerRadius)
        }
        let count = outerTop.count
        for index in 0..<count {
            let next = (index + 1) % count
            addQuad(outerTop[index], outerBottom[index], outerBottom[next], outerTop[next])
            // inner wall: reversed winding → normals point toward the axis
            addQuad(innerTop[next], innerBottom[next], innerBottom[index], innerTop[index])
            addQuad(outerTop[index], outerTop[next], innerTop[next], innerTop[index])       // +z
            addQuad(outerBottom[index], innerBottom[index], innerBottom[next], outerBottom[next])  // −z
        }
    }

    /// 4-sided pyramid on the z=0 plane, centered on the origin.
    mutating func addPyramid(baseHalf: Float, height: Float) {
        let base = [
            SIMD3(-baseHalf, -baseHalf, 0),
            SIMD3(baseHalf, -baseHalf, 0),
            SIMD3(baseHalf, baseHalf, 0),
            SIMD3(-baseHalf, baseHalf, 0)
        ]
        let apex = SIMD3(0, 0, height)
        addQuad(base[0], base[3], base[2], base[1])   // bottom (−z)
        for index in 0..<4 {
            addTriangle(base[index], base[(index + 1) % 4], apex)
        }
    }

    /// Binary STL bytes: 80-byte header + uint32 LE triangle count + 50-byte
    /// triangles (12 float32 LE + uint16 attribute), the same format as the
    /// bundled wave-B models.
    func binarySTL() -> Data {
        var data = Data(capacity: 84 + triangles.count * 50)
        var header = Data("OrcaPad generated handy model".utf8)
        header.append(Data(repeating: 0, count: 80 - header.count))
        data.append(header)
        appendLE(UInt32(triangles.count), to: &data)
        for triangle in triangles {
            // Advisory normal (recomputed by every importer).
            let cross = simd_cross(triangle.b - triangle.a, triangle.c - triangle.a)
            let length = simd_length(cross)
            let normal = length > 1e-12 ? cross / length : SIMD3<Float>(0, 0, 0)
            appendLE(normal.x, to: &data)
            appendLE(normal.y, to: &data)
            appendLE(normal.z, to: &data)
            for point in [triangle.a, triangle.b, triangle.c] {
                appendLE(point.x, to: &data)
                appendLE(point.y, to: &data)
                appendLE(point.z, to: &data)
            }
            appendLE(UInt16(0), to: &data)
        }
        return data
    }

    private func appendLE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private func appendLE(_ value: Float, to data: inout Data) {
        appendLE(value.bitPattern, to: &data)
    }
}

/// OrcaPad's "Add handy models" (desktop MenuFactory ▸ Add Handy models
/// parity). Desktop ships 10 Draco `.drc` files, but the Draco decoder is
/// deliberately not in OrcaPad's engine closure (upstream `load_drc` is
/// loud-stubbed) — instead three tiny parametric binary STLs are bundled
/// under `Resources/Handy/` (generated by the wave-B script), and the two
/// newest models are generated IN PURE SWIFT at runtime (`STLMesh`, no
/// assets at all). Same menu shape, same one-click import, no decoder
/// dependency.
enum HandyModels {
    struct Entry: Identifiable, Sendable {
        let name: String
        let source: Source
        let summary: String

        /// Bundled binary STL under Resources/Handy/ (name without
        /// extension), or a runtime-generated mesh.
        enum Source: Sendable {
            case bundled(String)
            case generated(@Sendable () -> STLMesh)
        }

        var id: String {
            switch source {
            case .bundled(let resource): return resource
            case .generated: return name
            }
        }
    }

    /// Menu contents (desktop order: calibration cube first).
    static let entries: [Entry] = [
        Entry(
            name: "Calibration Cube 20 mm",
            source: .bundled("orcapad-calibration-cube-20mm"),
            summary: "20×20×20 mm XYZ cube"
        ),
        Entry(
            name: "Cylinder Ø10 × 20",
            source: .bundled("orcapad-cylinder-d10-h20"),
            summary: "24-segment cylinder, 10 mm diameter"
        ),
        Entry(
            name: "Bridge Strip 60 mm",
            source: .bundled("orcapad-bridge-strip-60mm"),
            summary: "25 mm bridge between two towers"
        ),
        Entry(
            name: "Tolerance Test 0.3–0.7",
            source: .generated(toleranceTest),
            summary: "Peg + ring gauges, Ø0.3–0.7 mm fit test"
        ),
        Entry(
            name: "Calibration Pyramid 20 mm",
            source: .generated(calibrationPyramid),
            summary: "4-sided pyramid, 20 mm base and height"
        ),
    ]

    /// The importable STL of one entry: the bundled file, or the generated
    /// mesh written (overwritten) under Application Support.
    static func url(for entry: Entry) throws -> URL {
        switch entry.source {
        case .bundled(let resource):
            return try bundledURL(resource: resource)
        case .generated(let build):
            let url = try generatedFileURL(id: entry.id)
            do {
                try build().binarySTL().write(to: url, options: .atomic)
            } catch {
                throw HandyModelError.generationWriteFailed(entry.id)
            }
            return url
        }
    }

    /// The bundled STL of one resource. Bundle folder layout is preserved
    /// under `Resources/` (same access pattern as the license files).
    private static func bundledURL(resource: String) throws -> URL {
        let url = Bundle.module.bundleURL
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("Handy", isDirectory: true)
            .appendingPathComponent(resource)
            .appendingPathExtension("stl")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw HandyModelError.missingFromBundle(url.lastPathComponent)
        }
        return url
    }

    /// `Application Support/HandyGenerated/<id>.stl` — regenerated on every
    /// import (deterministic meshes, atomic replace).
    private static func generatedFileURL(id: String) throws -> URL {
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("HandyGenerated", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        } catch {
            throw HandyModelError.generationWriteFailed(id)
        }
        return directory.appendingPathComponent(id).appendingPathExtension("stl")
    }

    /// Desktop-gallery tolerance test, CSG-free adaptation: a 25×25×5 base
    /// plate with a row of test pegs (Ø0.3…0.7 mm, 5 mm tall) and a
    /// matching row of ring gauges with the same inner diameters — thread
    /// the pegs through the rings to read the clearance. Plain union mesh:
    /// base box + 5 cylinders + 5 annular tubes.
    private static func toleranceTest() -> STLMesh {
        var mesh = STLMesh()
        mesh.addBox(min: SIMD3(-12.5, -12.5, 0), max: SIMD3(12.5, 12.5, 5))
        let diameters: [Float] = [0.3, 0.4, 0.5, 0.6, 0.7]
        for (index, diameter) in diameters.enumerated() {
            let x = Float(-10 + index * 5)
            mesh.addCylinder(
                x: x, y: 6.25, radius: diameter / 2,
                z0: 5, z1: 10, segments: 16)
            mesh.addTube(
                x: x, y: -6.25,
                outerRadius: diameter / 2 + 1.5, innerRadius: diameter / 2,
                z0: 5, z1: 10, segments: 24)
        }
        return mesh
    }

    /// 4-sided calibration pyramid: 20×20 mm base, 20 mm height.
    private static func calibrationPyramid() -> STLMesh {
        var mesh = STLMesh()
        mesh.addPyramid(baseHalf: 10, height: 20)
        return mesh
    }
}
