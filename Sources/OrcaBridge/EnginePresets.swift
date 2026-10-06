import Foundation
import OrcaBridgeCore

/// Preset kinds (must match `orca_bridge.h`).
public enum PresetKind: Int32, Sendable {
    case machine = 0
    case filament = 1
    case process = 2
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

    private func invalidHandle(_ operation: String) -> BridgeError {
        .local(
            .invalidHandle,
            operation: operation,
            diagnostic: "\(operation): presets handle is unavailable"
        )
    }
}
