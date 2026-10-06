import Foundation
import OrcaBridgeCore

/// Swift wrapper over the engine's plater session (Model-backed objects +
/// instances). Engine calls are blocking and the engine is not reentrant, so
/// every call funnels through an internal lock.
///
/// Object/instance IDs remain indices temporarily; Architecture Gate A
/// replaces them with stable engine-issued IDs.
public final class EnginePlater: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSLock()

    public static func create() -> Result<EnginePlater, BridgeError> {
        let operation = "EnginePlater.create"
        if let error = bridgeABIFailure(operation: operation) {
            return .failure(error)
        }
        var handle: OpaquePointer?
        if let error = bridgeFailure(operation: operation, call: {
            orca_plater_new(&handle)
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
        return .success(EnginePlater(handle: handle))
    }

    private init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        if let handle { orca_plater_free(handle) }
    }

    public struct Transform: Sendable {
        public var offsetX: Double = 0
        public var offsetY: Double = 0
        public var offsetZ: Double = 0
        public var rotationZ: Double = 0
        public var scale: Double = 1
        /// Instance-matrix-transformed packing pivot (engine space) — the
        /// point that sits at (anchorX, anchorZ, -anchorY) in viewer space.
        public var anchorX: Double = 0
        public var anchorY: Double = 0
        public var anchorZ: Double = 0

        public init() {}
    }

    // MARK: - Objects

    /// Blocking (STL load + repair) — call off-main.
    public func addSTL(path: String) -> Result<Int, BridgeError> {
        let operation = "EnginePlater.addSTL"
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return .failure(invalidHandle(operation)) }
        var objectID: Int32 = -1
        if let error = bridgeFailure(operation: operation, call: {
            path.withCString { orca_plater_add_stl(handle, $0, &objectID) }
        }) {
            return .failure(error)
        }
        guard objectID >= 0 else {
            return .failure(.local(
                .internalInvariant,
                operation: operation,
                diagnostic: "\(operation): Bridge succeeded with an invalid object ID"
            ))
        }
        return .success(Int(objectID))
    }

    public func objectCount() -> Result<Int, BridgeError> {
        let operation = "EnginePlater.objectCount"
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return .failure(invalidHandle(operation)) }
        var count: Int32 = 0
        if let error = bridgeFailure(operation: operation, call: {
            orca_plater_object_count(handle, &count)
        }) {
            return .failure(error)
        }
        return .success(Int(count))
    }

    public func deleteObject(_ id: Int) -> Result<Void, BridgeError> {
        let operation = "EnginePlater.deleteObject"
        guard let objectID = Int32(exactly: id) else {
            return .failure(invalidID(operation, label: "object", value: id))
        }
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return .failure(invalidHandle(operation)) }
        if let error = bridgeFailure(operation: operation, call: {
            orca_plater_object_delete(handle, objectID)
        }) {
            return .failure(error)
        }
        return .success(())
    }

    // MARK: - Instances

    public func addInstance(objectID: Int) -> Result<Int, BridgeError> {
        let operation = "EnginePlater.addInstance"
        guard let objectID = Int32(exactly: objectID) else {
            return .failure(invalidID(operation, label: "object", value: objectID))
        }
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return .failure(invalidHandle(operation)) }
        var instanceID: Int32 = -1
        if let error = bridgeFailure(operation: operation, call: {
            orca_plater_instance_add(handle, objectID, &instanceID)
        }) {
            return .failure(error)
        }
        guard instanceID >= 0 else {
            return .failure(.local(
                .internalInvariant,
                operation: operation,
                diagnostic: "\(operation): Bridge succeeded with an invalid instance ID"
            ))
        }
        return .success(Int(instanceID))
    }

    public func deleteInstance(
        objectID: Int,
        instanceID: Int
    ) -> Result<Void, BridgeError> {
        let operation = "EnginePlater.deleteInstance"
        guard let objectID = Int32(exactly: objectID) else {
            return .failure(invalidID(operation, label: "object", value: objectID))
        }
        guard let instanceID = Int32(exactly: instanceID) else {
            return .failure(invalidID(operation, label: "instance", value: instanceID))
        }
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return .failure(invalidHandle(operation)) }
        if let error = bridgeFailure(operation: operation, call: {
            orca_plater_instance_delete(handle, objectID, instanceID)
        }) {
            return .failure(error)
        }
        return .success(())
    }

    public func instanceCount(objectID: Int) -> Result<Int, BridgeError> {
        let operation = "EnginePlater.instanceCount"
        guard let objectID = Int32(exactly: objectID) else {
            return .failure(invalidID(operation, label: "object", value: objectID))
        }
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return .failure(invalidHandle(operation)) }
        var count: Int32 = 0
        if let error = bridgeFailure(operation: operation, call: {
            orca_plater_instance_count(handle, objectID, &count)
        }) {
            return .failure(error)
        }
        return .success(Int(count))
    }

    public func setTransform(
        objectID: Int,
        instanceID: Int,
        _ transform: Transform
    ) -> Result<Void, BridgeError> {
        let operation = "EnginePlater.setTransform"
        guard let objectID = Int32(exactly: objectID) else {
            return .failure(invalidID(operation, label: "object", value: objectID))
        }
        guard let instanceID = Int32(exactly: instanceID) else {
            return .failure(invalidID(operation, label: "instance", value: instanceID))
        }
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return .failure(invalidHandle(operation)) }
        var value = orca_instance_transform()
        value.offset_x = transform.offsetX
        value.offset_y = transform.offsetY
        value.offset_z = transform.offsetZ
        value.rotation_z = transform.rotationZ
        value.scale = transform.scale
        value.anchor_x = transform.anchorX
        value.anchor_y = transform.anchorY
        value.anchor_z = transform.anchorZ
        if let error = bridgeFailure(operation: operation, call: {
            orca_plater_instance_set(handle, objectID, instanceID, &value)
        }) {
            return .failure(error)
        }
        return .success(())
    }

    public func getTransform(
        objectID: Int,
        instanceID: Int
    ) -> Result<Transform, BridgeError> {
        let operation = "EnginePlater.getTransform"
        guard let objectID = Int32(exactly: objectID) else {
            return .failure(invalidID(operation, label: "object", value: objectID))
        }
        guard let instanceID = Int32(exactly: instanceID) else {
            return .failure(invalidID(operation, label: "instance", value: instanceID))
        }
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return .failure(invalidHandle(operation)) }
        var value = orca_instance_transform()
        if let error = bridgeFailure(operation: operation, call: {
            orca_plater_instance_get(handle, objectID, instanceID, &value)
        }) {
            return .failure(error)
        }
        var transform = Transform()
        transform.offsetX = value.offset_x
        transform.offsetY = value.offset_y
        transform.offsetZ = value.offset_z
        transform.rotationZ = value.rotation_z
        transform.scale = value.scale
        transform.anchorX = value.anchor_x
        transform.anchorY = value.anchor_y
        transform.anchorZ = value.anchor_z
        return .success(transform)
    }

    // MARK: - Mesh views (engine-owned memory: copy synchronously)

    public func withMeshView<R>(
        objectID: Int,
        _ body: (orca_mesh_view) throws -> R
    ) rethrows -> Result<R, BridgeError> {
        let operation = "EnginePlater.withMeshView"
        guard let objectID = Int32(exactly: objectID) else {
            return .failure(invalidID(operation, label: "object", value: objectID))
        }
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return .failure(invalidHandle(operation)) }
        var view = orca_mesh_view()
        if let error = bridgeFailure(operation: operation, call: {
            orca_plater_mesh_view(handle, objectID, &view)
        }) {
            return .failure(error)
        }
        return .success(try body(view))
    }

    public func ensureOnBed() -> Result<Void, BridgeError> {
        let operation = "EnginePlater.ensureOnBed"
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return .failure(invalidHandle(operation)) }
        if let error = bridgeFailure(operation: operation, call: {
            orca_plater_ensure_on_bed(handle)
        }) {
            return .failure(error)
        }
        return .success(())
    }

    // MARK: - Slicing (blocking; call off-main)

    public struct SliceOutcome: Sendable {
        public let timeEstimateSeconds: Double
        public let gcodeBytes: Int64
    }

    public func sliceToGcode(
        gcodePath: String,
        progress: @escaping @Sendable (Int, String) -> Void
    ) -> Result<SliceOutcome, BridgeError> {
        sliceInternal(gcodePath: gcodePath, presets: nil, progress: progress)
    }

    public func sliceToGcode(
        presets: EnginePresets,
        gcodePath: String,
        progress: @escaping @Sendable (Int, String) -> Void
    ) -> Result<SliceOutcome, BridgeError> {
        sliceInternal(gcodePath: gcodePath, presets: presets, progress: progress)
    }

    private func sliceInternal(
        gcodePath: String,
        presets: EnginePresets?,
        progress: @escaping @Sendable (Int, String) -> Void
    ) -> Result<SliceOutcome, BridgeError> {
        final class ProgressBox: @unchecked Sendable {
            let callback: @Sendable (Int, String) -> Void
            init(_ callback: @escaping @Sendable (Int, String) -> Void) {
                self.callback = callback
            }
        }

        let operation = presets == nil
            ? "EnginePlater.sliceToGcode"
            : "EnginePlater.sliceToGcodeWithPresets"
        let box = ProgressBox(progress)
        let callback: orca_progress_fn? = { percent, message, raw in
            guard let raw else { return }
            let box = Unmanaged<ProgressBox>.fromOpaque(raw).takeUnretainedValue()
            box.callback(Int(percent), message.map { String(cString: $0) } ?? "")
        }

        lock.lock(); defer { lock.unlock() }
        guard let handle else { return .failure(invalidHandle(operation)) }
        var timeEstimate: Double = -1
        var gcodeBytes: Int64 = -1
        let context = Unmanaged.passUnretained(box).toOpaque()
        let error: BridgeError?
        if let presets {
            switch presets.withRawHandle(operation: operation, { presetHandle in
                bridgeFailure(operation: operation) {
                    gcodePath.withCString { path in
                        orca_plater_slice_to_gcode_with_presets(
                            handle,
                            presetHandle,
                            path,
                            callback,
                            context,
                            &timeEstimate,
                            &gcodeBytes
                        )
                    }
                }
            }) {
            case .success(let bridgeError): error = bridgeError
            case .failure(let bridgeError): return .failure(bridgeError)
            }
        } else {
            error = bridgeFailure(operation: operation) {
                gcodePath.withCString { path in
                    orca_plater_slice_to_gcode(
                        handle,
                        path,
                        callback,
                        context,
                        &timeEstimate,
                        &gcodeBytes
                    )
                }
            }
        }
        if let error { return .failure(error) }
        guard timeEstimate >= 0, gcodeBytes >= 0 else {
            return .failure(.local(
                .internalInvariant,
                operation: operation,
                diagnostic: "\(operation): Bridge succeeded with invalid slice outputs"
            ))
        }
        return .success(SliceOutcome(
            timeEstimateSeconds: timeEstimate,
            gcodeBytes: gcodeBytes
        ))
    }

    private func invalidHandle(_ operation: String) -> BridgeError {
        .local(
            .invalidHandle,
            operation: operation,
            diagnostic: "\(operation): plater handle is unavailable"
        )
    }

    private func invalidID(
        _ operation: String,
        label: String,
        value: Int
    ) -> BridgeError {
        .local(
            .invalidArgument,
            operation: operation,
            diagnostic: "\(operation): \(label) ID \(value) is outside the Bridge range"
        )
    }
}
