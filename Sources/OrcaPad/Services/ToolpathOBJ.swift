// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

import OrcaBridge
import simd
import SwiftUI
import UIKit

enum ToolpathOBJError: Error, LocalizedError, Sendable {
    /// Nothing visible to export (empty layer range or all roles hidden).
    case nothingVisible
    /// The file could not be created or written.
    case write(String)

    var errorDescription: String? {
        switch self {
        case .nothingVisible:
            return "OBJ export: no visible extrusion segments"
        case .write(let detail):
            return "OBJ export: \(detail)"
        }
    }
}

/// Exports the Preview's VISIBLE toolpath as a Wavefront OBJ (board
/// §wave-b/4): one oriented box per extrusion segment sized by the
/// segment's line width and layer height, `g layer_N` groups per layer,
/// quad faces with 1-based file-wide indices, no normals/MTL (viewers
/// recompute). Coordinates stay in the engine's canonical frame
/// (z-up, millimetres).
///
/// Travels and point markers (retracts, seams, tool changes) are omitted —
/// they carry no width/height and would export as degenerate boxes; the
/// hidden-role and layer-range filters match exactly what the canvas
/// shows. Blocking and O(visible segments): run off the main actor
/// (BackgroundWork); all state is local, so concurrent exports are safe.
enum ToolpathOBJ {
    /// Writes `Documents/Exports/<baseName>.obj` (unique, never
    /// overwriting) and returns its URL.
    static func write(
        toolpath: GcodeToolpath,
        lowerLayer: Int,
        upperLayer: Int,
        hiddenRoles: Set<UInt8>,
        baseName: String
    ) throws -> URL {
        let outputURL = try EnginePaths.exportURL(name: baseName, pathExtension: "obj")
        do {
            guard FileManager.default.createFile(
                atPath: outputURL.path, contents: nil)
            else {
                throw ToolpathOBJError.write(
                    "could not create \(outputURL.lastPathComponent)")
            }
            let handle = try FileHandle(forWritingTo: outputURL)
            var writeError: ToolpathOBJError?
            do {
                try handle.write(contentsOf: Data(
                    "# OrcaPad toolpath export\n# z-up, millimetres\n".utf8))
                var nextIndex: UInt32 = 1  // OBJ indices are 1-based
                var boxes = 0
                var chunk = ""
                let lastLayer = min(
                    max(upperLayer, lowerLayer), toolpath.layers.count - 1)
                guard lowerLayer <= lastLayer else {
                    throw ToolpathOBJError.nothingVisible
                }
                for layerIndex in lowerLayer...lastLayer {
                    let layer = toolpath.layers[layerIndex]
                    chunk += "g layer_\(layerIndex + 1)\n"
                    let segmentRange = layer.firstSegment..<(layer.firstSegment + layer.segmentCount)
                    for index in segmentRange {
                        let segment = toolpath.segments[index]
                        guard segment.isExtrusion,
                            !hiddenRoles.contains(segment.role)
                        else { continue }
                        // Degenerate (zero-length) extrusions have no box —
                        // a geometric filter, not an error.
                        let direction = segment.end - segment.start
                        let length = simd_length(direction)
                        guard length > 1e-6 else { continue }
                        let (lines, advanced) = boxLines(
                            segment,
                            direction: direction / length,
                            firstIndex: nextIndex)
                        chunk += lines
                        nextIndex = advanced
                        boxes += 1
                        // Flush periodically so the buffer stays bounded
                        // on large toolpaths.
                        if chunk.utf8.count > 1 << 20 {
                            try handle.write(contentsOf: Data(chunk.utf8))
                            chunk = ""
                        }
                    }
                }
                try handle.write(contentsOf: Data(chunk.utf8))
                guard boxes > 0 else {
                    throw ToolpathOBJError.nothingVisible
                }
            } catch let error as ToolpathOBJError {
                writeError = error
            } catch {
                writeError = ToolpathOBJError.write(String(describing: error))
            }
            // Explicit close — a failed close after writes is a real
            // write failure, reported loudly (no silent discard).
            do {
                try handle.close()
            } catch {
                throw ToolpathOBJError.write(
                    "close: \(String(describing: error))")
            }
            if let writeError {
                throw writeError
            }
        } catch let error as ToolpathOBJError {
            // Nothing visible: remove the empty file again so the unique
            // name slot is not wasted.
            if case .nothingVisible = error {
                do {
                    try FileManager.default.removeItem(at: outputURL)
                } catch {
                    throw ToolpathOBJError.write(
                        "nothing visible, and the empty file could not be " +
                            "removed: \(String(describing: error))")
                }
            }
            throw error
        } catch {
            throw ToolpathOBJError.write(String(describing: error))
        }
        return outputURL
    }

    /// 8 `v` lines + 6 quad `f` lines for one extrusion segment's box.
    /// Returns the text plus the next free (1-based) OBJ vertex index.
    private static func boxLines(
        _ segment: ToolpathSegment,
        direction: SIMD3<Float>,
        firstIndex: UInt32
    ) -> (lines: String, nextIndex: UInt32) {
        let halfWidth = max(segment.width, 0.02) / 2
        let halfHeight = max(segment.height, 0.02) / 2
        // Orthonormal frame around the extrusion centerline: any reference
        // not parallel to the direction works.
        let reference = abs(direction.z) > 0.9
            ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 0, 1)
        let side = simd_normalize(simd_cross(reference, direction))
        let up = simd_cross(direction, side)

        func corner(
            _ base: SIMD3<Float>, _ alongWidth: Float, _ alongHeight: Float
        ) -> SIMD3<Float> {
            base + side * (alongWidth * halfWidth)
                + up * (alongHeight * halfHeight)
        }
        func vertex(_ point: SIMD3<Float>) -> String {
            String(format: "v %.3f %.3f %.3f\n", point.x, point.y, point.z)
        }

        let start = segment.start
        let end = segment.end
        let a = corner(start, -1, -1), b = corner(start, 1, -1)
        let c = corner(start, 1, 1), d = corner(start, -1, 1)
        let e = corner(end, -1, -1), f = corner(end, 1, -1)
        let g = corner(end, 1, 1), h = corner(end, -1, 1)

        let a1 = firstIndex, b1 = firstIndex + 1, c1 = firstIndex + 2
        let d1 = firstIndex + 3, e1 = firstIndex + 4, f1 = firstIndex + 5
        let g1 = firstIndex + 6, h1 = firstIndex + 7
        return (
            vertex(a) + vertex(b) + vertex(c) + vertex(d)
                + vertex(e) + vertex(f) + vertex(g) + vertex(h)
                + "f \(a1) \(d1) \(c1) \(b1)\n"   // start cap
                + "f \(e1) \(f1) \(g1) \(h1)\n"   // end cap
                + "f \(a1) \(b1) \(f1) \(e1)\n"
                + "f \(b1) \(c1) \(g1) \(f1)\n"
                + "f \(c1) \(d1) \(h1) \(g1)\n"
                + "f \(d1) \(a1) \(e1) \(h1)\n",
            firstIndex + 8
        )
    }
}

/// UIActivityViewController wrapper: `ShareLink` presents only from its own
/// button, but the OBJ export produces its URL asynchronously after a
/// background write — that share goes through this sheet.
struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(
            activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(
        _ controller: UIActivityViewController, context: Context
    ) {}
}
