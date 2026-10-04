import Foundation
import OrcaCore

/// Preset kinds (must match orca_core.h).
public enum PresetKind: Int, Sendable {
    case machine = 0
    case filament = 1
    case process = 2
}

/// Swift wrapper over the engine's system-preset bundle (upstream
/// PresetBundle: machines / filaments / processes, inheritance resolved by
/// upstream code). Loading walks ~12k JSON files — create OFF-main.
/// Not reentrant: internal lock serializes engine calls.
public final class EnginePresets: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSLock()

    public static func create(dataDir: String) -> Result<EnginePresets, EngineError> {
        var h: OpaquePointer?
        let s = dataDir.withCString { String(cString: orca_presets_new($0, &h)) }
        guard let h else { return .failure(EngineError(message: s)) }
        return .success(EnginePresets(handle: h))
    }

    private init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        if let h = handle { orca_presets_free(h) }
    }

    /// Raw handle for the plater's with-presets slice call (used while the
    /// plater holds its own lock; UI serializes preset mutations anyway).
    var rawHandle: OpaquePointer? {
        lock.lock(); defer { lock.unlock() }
        return handle
    }

    /// All system preset names of a kind, sorted as the engine returns them.
    public func names(kind: PresetKind) -> Result<[String], EngineError> {
        lock.lock(); defer { lock.unlock() }
        guard let h = handle else { return .failure(EngineError(message: "presets freed")) }
        var count: Int32 = 0
        _ = String(cString: orca_presets_list_count(h, Int32(kind.rawValue), &count))
        var out: [String] = []
        out.reserveCapacity(Int(count))
        for i in 0..<count {
            var namePtr: UnsafePointer<CChar>?
            _ = String(cString: orca_presets_list_name(h, Int32(kind.rawValue), i, &namePtr))
            if let namePtr { out.append(String(cString: namePtr)) }
        }
        return .success(out)
    }

    /// Selects machine + filament + process by exact name (loud on miss).
    public func select(machine: String, filament: String, process: String) -> Result<Void, EngineError> {
        lock.lock(); defer { lock.unlock() }
        guard let h = handle else { return .failure(EngineError(message: "presets freed")) }
        let s = machine.withCString { m in
            filament.withCString { f in
                process.withCString { p in
                    String(cString: orca_presets_select(h, m, f, p))
                }
            }
        }
        guard s.contains("selected") else { return .failure(EngineError(message: s)) }
        return .success(())
    }

    public func current(kind: PresetKind) -> Result<String, EngineError> {
        lock.lock(); defer { lock.unlock() }
        guard let h = handle else { return .failure(EngineError(message: "presets freed")) }
        var namePtr: UnsafePointer<CChar>?
        _ = String(cString: orca_presets_current(h, Int32(kind.rawValue), &namePtr))
        guard let namePtr else { return .failure(EngineError(message: "no current preset")) }
        return .success(String(cString: namePtr))
    }
}
