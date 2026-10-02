import Foundation
import OrcaCore

/// Swift↔C++ engine boundary. Currently: the STL round-trip probe against
/// real OrcaSlicer code (admesh read + repair). Grows into the full
/// Model/Print/Preset API as the engine subset expands.
///
/// Boundary rule: Swift owns all filesystem paths (sandbox-aware); the
/// engine receives them as arguments and never hardcodes locations.
public enum EngineProbe {
    public static func status() -> String {
        var facets: Int32 = 0
        var volume: Float = 0
        let dir = FileManager.default.temporaryDirectory.path
        let result = dir.withCString { dirC in
            String(cString: orca_core_stl_probe(dirC, &facets, &volume))
        }
        return "\(result) · \(facets) tris · \(String(format: "%.0f", volume)) mm³"
    }
}
