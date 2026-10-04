import Foundation
import OrcaCore

/// Swift wrapper over the engine's plater session (Model-backed objects +
/// instances). Engine calls are blocking (add = admesh read/repair) and the
/// engine is not reentrant — every call funnels through an internal lock.
/// Filesystem paths stay Swift-owned (boundary rule).
///
/// Object/instance ids are INDICES; deletes renumber. Resync counts after
/// every mutation.
public final class EnginePlater: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSLock()

    public static func create() -> Result<EnginePlater, EngineError> {
        var h: OpaquePointer?
        let s = String(cString: orca_plater_new(&h))
        guard let h else { return .failure(EngineError(message: s)) }
        return .success(EnginePlater(handle: h))
    }

    private init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        if let h = handle { orca_plater_free(h) }
    }

    // MARK: - Transform type

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
    public func addSTL(path: String) -> Result<Int, EngineError> {
        lock.lock(); defer { lock.unlock() }
        guard let h = handle else { return .failure(EngineError(message: "plater freed")) }
        var id: Int32 = -1
        let s = path.withCString { String(cString: orca_plater_add_stl(h, $0, &id)) }
        guard id >= 0 else { return .failure(EngineError(message: s)) }
        return .success(Int(id))
    }

    public func objectCount() -> Result<Int, EngineError> {
        lock.lock(); defer { lock.unlock() }
        guard let h = handle else { return .failure(EngineError(message: "plater freed")) }
        var n: Int32 = 0
        _ = String(cString: orca_plater_object_count(h, &n))
        return .success(Int(n))
    }

    public func deleteObject(_ id: Int) -> Result<Void, EngineError> {
        lock.lock(); defer { lock.unlock() }
        guard let h = handle else { return .failure(EngineError(message: "plater freed")) }
        let s = String(cString: orca_plater_object_delete(h, Int32(id)))
        guard s.contains("ok") || s.contains("deleted") else {
            return .failure(EngineError(message: s))
        }
        return .success(())
    }

    // MARK: - Instances

    public func addInstance(objectID: Int) -> Result<Int, EngineError> {
        lock.lock(); defer { lock.unlock() }
        guard let h = handle else { return .failure(EngineError(message: "plater freed")) }
        var id: Int32 = -1
        let s = String(cString: orca_plater_instance_add(h, Int32(objectID), &id))
        guard id >= 0 else { return .failure(EngineError(message: s)) }
        return .success(Int(id))
    }

    public func deleteInstance(objectID: Int, instanceID: Int) -> Result<Void, EngineError> {
        lock.lock(); defer { lock.unlock() }
        guard let h = handle else { return .failure(EngineError(message: "plater freed")) }
        let s = String(cString: orca_plater_instance_delete(h, Int32(objectID), Int32(instanceID)))
        guard s.contains("deleted") else { return .failure(EngineError(message: s)) }
        return .success(())
    }

    public func instanceCount(objectID: Int) -> Result<Int, EngineError> {
        lock.lock(); defer { lock.unlock() }
        guard let h = handle else { return .failure(EngineError(message: "plater freed")) }
        var n: Int32 = 0
        _ = String(cString: orca_plater_instance_count(h, Int32(objectID), &n))
        return .success(Int(n))
    }

    public func setTransform(objectID: Int, instanceID: Int, _ t: Transform) -> Result<Void, EngineError> {
        lock.lock(); defer { lock.unlock() }
        guard let h = handle else { return .failure(EngineError(message: "plater freed")) }
        var ct = orca_instance_transform()
        ct.offset_x = t.offsetX; ct.offset_y = t.offsetY; ct.offset_z = t.offsetZ
        ct.rotation_z = t.rotationZ
        ct.scale = t.scale
        ct.anchor_x = t.anchorX; ct.anchor_y = t.anchorY; ct.anchor_z = t.anchorZ
        let s = String(cString: orca_plater_instance_set(h, Int32(objectID), Int32(instanceID), &ct))
        guard s.contains("ok") || s.contains("set") else {
            return .failure(EngineError(message: s))
        }
        return .success(())
    }

    /// NOTE: the anchor depends on the packed pivot — cheap (no slicing).
    public func getTransform(objectID: Int, instanceID: Int) -> Result<Transform, EngineError> {
        lock.lock(); defer { lock.unlock() }
        guard let h = handle else { return .failure(EngineError(message: "plater freed")) }
        var ct = orca_instance_transform()
        let s = String(cString: orca_plater_instance_get(h, Int32(objectID), Int32(instanceID), &ct))
        guard s.contains("ok") || s.contains("transform") else {
            return .failure(EngineError(message: s))
        }
        var t = Transform()
        t.offsetX = ct.offset_x; t.offsetY = ct.offset_y; t.offsetZ = ct.offset_z
        t.rotationZ = ct.rotation_z; t.scale = ct.scale
        t.anchorX = ct.anchor_x; t.anchorY = ct.anchor_y; t.anchorZ = ct.anchor_z
        return .success(t)
    }

    // MARK: - Mesh views (engine-owned memory: copy synchronously)

    /// Runs the body with a view into the engine's packed mesh buffers.
    /// Valid synchronously only — copy everything before returning.
    public func withMeshView<R>(objectID: Int, _ body: (orca_mesh_view) throws -> R) rethrows -> Result<R, EngineError> {
        lock.lock(); defer { lock.unlock() }
        guard let h = handle else { return .failure(EngineError(message: "plater freed")) }
        var v = orca_mesh_view()
        let s = String(cString: orca_plater_mesh_view(h, Int32(objectID), &v))
        guard s.contains("ok") || s.contains("mesh") else {
            return .failure(EngineError(message: s))
        }
        return .success(try body(v))
    }

    public func ensureOnBed() -> Result<Void, EngineError> {
        lock.lock(); defer { lock.unlock() }
        guard let h = handle else { return .failure(EngineError(message: "plater freed")) }
        let s = String(cString: orca_plater_ensure_on_bed(h))
        guard s.contains("bed") else { return .failure(EngineError(message: s)) }
        return .success(())
    }

    // MARK: - Slicing (blocking; call off-main)

    public struct SliceOutcome: Sendable {
        public let timeEstimateSeconds: Double
        public let gcodeBytes: Int
    }

    public func sliceToGcode(
        gcodePath: String,
        progress: @escaping @Sendable (Int, String) -> Void
    ) -> Result<SliceOutcome, EngineError> {
        final class ProgressBox: @unchecked Sendable {
            let cb: @Sendable (Int, String) -> Void
            init(_ cb: @escaping @Sendable (Int, String) -> Void) { self.cb = cb }
        }
        let box = ProgressBox(progress)
        let cCallback: orca_progress_fn? = { percent, message, raw in
            guard let raw else { return }
            let box = Unmanaged<ProgressBox>.fromOpaque(raw).takeUnretainedValue()
            box.cb(Int(percent), message.map { String(cString: $0) } ?? "")
        }

        lock.lock()
        guard let h = handle else {
            lock.unlock()
            return .failure(EngineError(message: "plater freed"))
        }
        var timeEstimate: Double = 0
        var gcodeBytes = 0
        // NOTE: the engine call may take minutes; the engine does not touch
        // the plater during it (single Print consumed), and the lock keeps
        // other API calls out until slicing completes.
        let status = gcodePath.withCString { gp in
            String(cString: orca_plater_slice_to_gcode(
                h, gp, cCallback,
                Unmanaged.passUnretained(box).toOpaque(),
                &timeEstimate, &gcodeBytes))
        }
        lock.unlock()

        guard status.contains("slice ok") else {
            return .failure(EngineError(message: status))
        }
        return .success(SliceOutcome(timeEstimateSeconds: timeEstimate, gcodeBytes: gcodeBytes))
    }
}
