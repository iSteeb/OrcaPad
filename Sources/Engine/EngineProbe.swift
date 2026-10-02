import Foundation
import OrcaCore

/// Swift↔C++ engine boundary. Currently: the STL round-trip probe against
/// real OrcaSlicer code (admesh read + repair). Grows into the full
/// Model/Print/Preset API as the engine subset expands.
public enum EngineProbe {
    public static func status() -> String {
        var facets: Int32 = 0
        var volume: Float = 0
        let result = String(cString: orca_core_stl_probe(&facets, &volume))
        return "\(result) · \(facets) tris · \(String(format: "%.0f", volume)) mm³"
    }
}
