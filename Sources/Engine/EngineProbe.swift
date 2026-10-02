import Foundation
import CxxProbe

/// Swift↔C++ interop gate. This is the seed of the engine boundary: when
/// libslic3r lands it grows into the real Model/Print/Preset API surface.
public enum EngineProbe {
    public static func status() -> String {
        let version = String(cString: cxx_probe_version())
        let stl = cxx_probe_stl_test(6)
        return "\(version) · STL ok (\(stl))"
    }
}
