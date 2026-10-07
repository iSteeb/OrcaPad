import Foundation
import OrcaBridgeCore

/// Preset kinds (must match `orca_bridge.h`).
public enum PresetKind: Int32, Sendable {
    case machine = 0
    case filament = 1
    case process = 2
}

/// Where a listed preset comes from (desktop preset combo grouping).
public enum PresetOrigin: UInt8, Sendable {
    case system = 0
    case user = 1
    /// Embedded in a loaded project.
    case project = 2
    /// Loaded from a file's configuration.
    case external = 3
}

public struct PresetEntry: Sendable {
    public let name: String
    public let vendor: String
    public let isCompatible: Bool
    public let origin: PresetOrigin
}

public struct PrintVolume: Equatable, Sendable {
    public let minX: Double
    public let minY: Double
    public let maxX: Double
    public let maxY: Double

    public var width: Double { maxX - minX }
    public var depth: Double { maxY - minY }
    public var centerX: Double { (minX + maxX) / 2 }
    public var centerY: Double { (minY + maxY) / 2 }
}

/// Plate (bed) type state; values are the engine's `Slic3r::BedType`
/// (1 = Cool Plate …). Labels come from the `curr_bed_type` schema option.
public struct BedTypeState: Equatable, Sendable {
    public let current: Int32
    public let machineDefault: Int32
    /// Valid values: 1..<count (the engine's btCount).
    public let count: Int32
    /// Desktop shows the plate selector only when true.
    public let selectable: Bool
    public let supported: [Int32]
}

/// Swift wrapper over the engine's system-preset bundle. Loading walks the
/// bundled profile tree and is blocking; create it off the main thread.
public final class EnginePresets: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSLock()

    public static func create(dataDir: String) -> Result<EnginePresets, BridgeError> {
        let operation = "EnginePresets.create"
        if let error = bridgeABIFailure(operation: operation) {
            return .failure(error)
        }
        var handle: OpaquePointer?
        if let error = bridgeFailure(operation: operation, call: {
            dataDir.withCString { orca_presets_new($0, &handle) }
        }) {
            return .failure(error)
        }
        guard let handle else {
            return .failure(.local(
                .internalInvariant,
                operation: operation,
                diagnostic: "\(operation): Bridge succeeded without returning a handle"
            ))
        }
        return .success(EnginePresets(handle: handle))
    }

    private init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        if let handle { orca_presets_free(handle) }
    }

    /// Keeps the presets session locked for the complete Bridge operation.
    /// `EnginePlater` always acquires its own lock first, establishing the
    /// only cross-session lock order: plater → presets.
    func withLockedHandle<Value>(
        _ body: (OpaquePointer) throws -> Value
    ) throws -> Value {
        try lock.withLock {
            guard let handle else {
                throw invalidHandle("EnginePresets.withLockedHandle")
            }
            return try body(handle)
        }
    }

    func withRawHandle<Value>(
        operation: String,
        _ body: (OpaquePointer) -> Value
    ) -> Result<Value, BridgeError> {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return .failure(invalidHandle(operation)) }
        return .success(body(handle))
    }

    public func names(kind: PresetKind) -> Result<[String], BridgeError> {
        let countOperation = "EnginePresets.names.count"
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return .failure(invalidHandle(countOperation)) }

        var count: Int32 = 0
        if let error = bridgeFailure(operation: countOperation, call: {
            orca_presets_list_count(handle, kind.rawValue, &count)
        }) {
            return .failure(error)
        }
        guard count >= 0 else {
            return .failure(.local(
                .internalInvariant,
                operation: countOperation,
                diagnostic: "\(countOperation): Bridge returned a negative preset count"
            ))
        }

        var names: [String] = []
        names.reserveCapacity(Int(count))
        for index in 0..<count {
            let operation = "EnginePresets.names.item"
            var owned = orca_owned_string()
            if let error = bridgeFailure(operation: operation, call: {
                orca_presets_list_name(
                    handle,
                    kind.rawValue,
                    index,
                    &owned
                )
            }) {
                orca_owned_string_dispose(&owned)
                return .failure(error)
            }
            switch consumeBridgeString(&owned, operation: operation) {
            case .success(let name): names.append(name)
            case .failure(let error): return .failure(error)
            }
        }
        return .success(names)
    }

    public func select(
        machine: String,
        filament: String,
        process: String
    ) -> Result<Void, BridgeError> {
        let operation = "EnginePresets.select"
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return .failure(invalidHandle(operation)) }
        if let error = bridgeFailure(operation: operation, call: {
            machine.withCString { machineName in
                filament.withCString { filamentName in
                    process.withCString { processName in
                        orca_presets_select(
                            handle,
                            machineName,
                            filamentName,
                            processName
                        )
                    }
                }
            }
        }) {
            return .failure(error)
        }
        return .success(())
    }

    public func current(kind: PresetKind) -> Result<String, BridgeError> {
        let operation = "EnginePresets.current"
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return .failure(invalidHandle(operation)) }
        var owned = orca_owned_string()
        if let error = bridgeFailure(operation: operation, call: {
            orca_presets_current(handle, kind.rawValue, &owned)
        }) {
            orca_owned_string_dispose(&owned)
            return .failure(error)
        }
        return consumeBridgeString(&owned, operation: operation)
    }

    /// Full preset metadata (name, manufacturer, engine compatibility flag)
    /// in the same stable order as `names(kind:)`.
    public func entries(kind: PresetKind) -> Result<[PresetEntry], BridgeError> {
        let countOperation = "EnginePresets.entries.count"
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return .failure(invalidHandle(countOperation)) }

        var count: Int32 = 0
        if let error = bridgeFailure(operation: countOperation, call: {
            orca_presets_list_count(handle, kind.rawValue, &count)
        }) {
            return .failure(error)
        }
        guard count >= 0 else {
            return .failure(.local(
                .internalInvariant,
                operation: countOperation,
                diagnostic: "\(countOperation): Bridge returned a negative preset count"
            ))
        }

        var result: [PresetEntry] = []
        result.reserveCapacity(Int(count))
        for index in 0..<count {
            let operation = "EnginePresets.entries.item"
            var entry = orca_preset_entry()
            if let error = bridgeFailure(operation: operation, call: {
                orca_presets_list_entry(
                    handle,
                    kind.rawValue,
                    index,
                    &entry
                )
            }) {
                orca_preset_entry_dispose(&entry)
                return .failure(error)
            }
            defer { orca_preset_entry_dispose(&entry) }
            let name: String
            switch consumeBridgeString(&entry.name, operation: operation) {
            case .success(let value): name = value
            case .failure(let error): return .failure(error)
            }
            let vendor: String
            switch consumeBridgeString(&entry.vendor, operation: operation) {
            case .success(let value): vendor = value
            case .failure(let error): return .failure(error)
            }
            guard let origin = PresetOrigin(rawValue: entry.origin) else {
                return .failure(.local(
                    .internalInvariant,
                    operation: operation,
                    diagnostic: "\(operation): unknown preset origin \(entry.origin)"
                ))
            }
            result.append(PresetEntry(
                name: name,
                vendor: vendor,
                isCompatible: entry.compatible != 0,
                origin: origin
            ))
        }
        return .success(result)
    }

    /// Axis-aligned bounding rectangle of the selected machine's bed.
    public func printVolume() -> Result<PrintVolume, BridgeError> {
        let operation = "EnginePresets.printVolume"
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return .failure(invalidHandle(operation)) }
        var minX = 0.0, minY = 0.0, maxX = 0.0, maxY = 0.0
        if let error = bridgeFailure(operation: operation, call: {
            orca_presets_print_volume(handle, &minX, &minY, &maxX, &maxY)
        }) {
            return .failure(error)
        }
        guard maxX > minX, maxY > minY,
              minX.isFinite, minY.isFinite,
              maxX.isFinite, maxY.isFinite else {
            return .failure(.local(
                .internalInvariant,
                operation: operation,
                diagnostic: "\(operation): Bridge returned a degenerate print volume"
            ))
        }
        return .success(PrintVolume(minX: minX, minY: minY, maxX: maxX, maxY: maxY))
    }

    public func bedType() -> Result<BedTypeState, BridgeError> {
        let operation = "EnginePresets.bedType"
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return .failure(invalidHandle(operation)) }
        var raw = orca_bed_type_state()
        if let error = bridgeFailure(operation: operation, call: {
            orca_presets_bed_type(handle, &raw)
        }) {
            return .failure(error)
        }
        guard raw.count > 1, raw.count <= 32,
              (1..<raw.count).contains(raw.current),
              (1..<raw.count).contains(raw.machine_default) else {
            return .failure(.local(
                .internalInvariant,
                operation: operation,
                diagnostic: "\(operation): Bridge returned an out-of-range bed type state"
            ))
        }
        let supported = (1..<raw.count).filter { raw.supported_mask & (1 << UInt32($0)) != 0 }
        return .success(BedTypeState(
            current: raw.current,
            machineDefault: raw.machine_default,
            count: raw.count,
            selectable: raw.selectable != 0,
            supported: supported
        ))
    }

    public func setBedType(_ value: Int32) -> Result<Void, BridgeError> {
        let operation = "EnginePresets.setBedType"
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return .failure(invalidHandle(operation)) }
        if let error = bridgeFailure(operation: operation, call: {
            orca_presets_set_bed_type(handle, value)
        }) {
            return .failure(error)
        }
        return .success(())
    }

    /// The complete resolved configuration exactly as slicing will consume
    /// it, as a JSON object string of { "key": "value" }.
    public func resolvedConfig() -> Result<String, BridgeError> {
        let operation = "EnginePresets.resolvedConfig"
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return .failure(invalidHandle(operation)) }
        var owned = orca_owned_string()
        if let error = bridgeFailure(operation: operation, call: {
            orca_presets_resolved_config(handle, &owned)
        }) {
            orca_owned_string_dispose(&owned)
            return .failure(error)
        }
        return consumeBridgeString(&owned, operation: operation)
    }

    /// Desktop-parity override: writes `serializedValue` into the working
    /// (edited) preset of `kind`; `full_config()` merges edited presets, so
    /// the next slice consumes it by construction.
    public func setValue(
        kind: PresetKind,
        key: String,
        serializedValue: String
    ) -> Result<Void, BridgeError> {
        let operation = "EnginePresets.setValue"
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return .failure(invalidHandle(operation)) }
        if let error = bridgeFailure(operation: operation, call: {
            key.withCString { keyPointer in
                serializedValue.withCString { valuePointer in
                    orca_presets_set_value(
                        handle, kind.rawValue, keyPointer, valuePointer
                    )
                }
            }
        }) {
            return .failure(error)
        }
        return .success(())
    }

    /// Restores one key of the edited preset from the selected system preset.
    public func resetValue(
        kind: PresetKind,
        key: String
    ) -> Result<Void, BridgeError> {
        let operation = "EnginePresets.resetValue"
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return .failure(invalidHandle(operation)) }
        if let error = bridgeFailure(operation: operation, call: {
            key.withCString { keyPointer in
                orca_presets_reset_value(handle, kind.rawValue, keyPointer)
            }
        }) {
            return .failure(error)
        }
        return .success(())
    }

    /// Restores the whole edited preset of `kind` from its selection.
    public func resetKind(_ kind: PresetKind) -> Result<Void, BridgeError> {
        let operation = "EnginePresets.resetKind"
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return .failure(invalidHandle(operation)) }
        if let error = bridgeFailure(operation: operation, call: {
            orca_presets_reset_kind(handle, kind.rawValue)
        }) {
            return .failure(error)
        }
        return .success(())
    }

    /// Desktop "Save preset": the edited preset of `kind` becomes user
    /// preset `name` (persisted under the data dir) and is selected.
    public func saveUser(kind: PresetKind, name: String, detach: Bool) -> Result<Void, BridgeError> {
        let operation = "EnginePresets.saveUser"
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return .failure(invalidHandle(operation)) }
        if let error = bridgeFailure(operation: operation, call: {
            name.withCString { orca_presets_save_user(handle, kind.rawValue, $0, detach ? 1 : 0) }
        }) {
            return .failure(error)
        }
        return .success(())
    }

    /// Desktop "Delete preset" (user presets only).
    public func deleteUser(kind: PresetKind, name: String) -> Result<Void, BridgeError> {
        let operation = "EnginePresets.deleteUser"
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return .failure(invalidHandle(operation)) }
        if let error = bridgeFailure(operation: operation, call: {
            name.withCString { orca_presets_delete_user(handle, kind.rawValue, $0) }
        }) {
            return .failure(error)
        }
        return .success(())
    }

    /// Serialized key→value dictionary of either the edited or the selected
    /// system preset config of `kind` (the client diffs the two to detect
    /// modified values).
    public func configDump(
        kind: PresetKind,
        edited: Bool
    ) -> Result<[String: String], BridgeError> {
        let operation = "EnginePresets.configDump"
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return .failure(invalidHandle(operation)) }
        var owned = orca_owned_string()
        if let error = bridgeFailure(operation: operation, call: {
            orca_presets_config_dump(
                handle, kind.rawValue, edited ? 1 : 0, &owned
            )
        }) {
            orca_owned_string_dispose(&owned)
            return .failure(error)
        }
        switch consumeBridgeString(&owned, operation: operation) {
        case .success(let json):
            guard let data = json.data(using: .utf8) else {
                return .failure(.local(
                    .internalInvariant,
                    operation: operation,
                    diagnostic: "config dump is not valid UTF-8"
                ))
            }
            do {
                return .success(try JSONDecoder().decode(
                    [String: String].self,
                    from: data
                ))
            } catch {
                return .failure(.local(
                    .internalInvariant,
                    operation: operation,
                    diagnostic: "config dump is not a JSON object of strings: " +
                        String(reflecting: error)
                ))
            }
        case .failure(let error):
            return .failure(error)
        }
    }

    private func invalidHandle(_ operation: String) -> BridgeError {
        .local(
            .invalidHandle,
            operation: operation,
            diagnostic: "\(operation): presets handle is unavailable"
        )
    }
}
