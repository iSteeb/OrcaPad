import Foundation
import OrcaCore

/// Swift↔C++ engine boundary, v2: real mesh loading + real slicing.
///
/// Boundary rules (LESSONS.md):
/// - Swift owns all filesystem paths; engine receives them as arguments.
/// - Every engine error surfaces as a string — never a crash, never silent.
/// - EngineMesh is main-thread confined after construction (handle lifetime).
/// Loud engine error (boundary rule: errors as values, never crashes).
public struct EngineError: Error, Sendable {
    public let message: String
}

public final class EngineMesh {
    private let handle: OpaquePointer?
    public let view: orca_mesh_view
    public let status: String

    private init(handle: OpaquePointer, view: orca_mesh_view, status: String) {
        self.handle = handle
        self.view = view
        self.status = status
    }

    /// Loads an STL through the engine. Failure carries the engine's loud
    /// error string — never a silent nil.
    public static func load(path: String) -> Result<EngineMesh, EngineError> {
        var h: OpaquePointer?
        var v = orca_mesh_view()
        let s = path.withCString { cPath in
            String(cString: orca_stl_load(cPath, &h, &v))
        }
        guard let h else { return .failure(EngineError(message: s)) }
        return .success(EngineMesh(handle: h, view: v, status: s))
    }

    deinit {
        if let h = handle { orca_mesh_free(h) }
    }

    public var triangleCount: Int { Int(view.index_count / 3) }

    /// Engine-space dimensions X×Y×Z (mm). Z is the printing height.
    public var dimensionsMM: SIMD3<Float> {
        // view bbox is viewer-space (x, y=height, z): report engine X×Y×Z.
        let sx = view.bbox_max.0 - view.bbox_min.0
        let sy = view.bbox_max.2 - view.bbox_min.2
        let sz = view.bbox_max.1 - view.bbox_min.1
        return SIMD3<Float>(sx, sy, sz)
    }

    public struct SliceReport: Sendable {
        public let levels: Int
        public let midIslands: Int
        public let midAreaMM2: Double
    }

    /// Runs OrcaSlicer's real slice_mesh_ex at `levels` z-heights.
    public func sliceReport(levels: Int = 8) -> SliceReport? {
        guard let h = handle else { return nil }
        var lv: Int32 = 0, isl: Int32 = 0
        var area: Double = 0
        _ = orca_slice_report(h, Int32(levels), &lv, &isl, &area)
        return SliceReport(levels: Int(lv), midIslands: Int(isl), midAreaMM2: area)
    }
}
