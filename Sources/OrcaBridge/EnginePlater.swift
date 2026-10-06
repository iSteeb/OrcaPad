import Foundation
@preconcurrency import OrcaBridgeCore
import simd

/// One authoritative C++ document session. Mutable engine state never escapes
/// this type; callers receive owned, revisioned snapshots.
public final class EnginePlater: @unchecked Sendable {
    public enum Mutation: Sendable {
        case importModel(path: String, bedCenter: SIMD2<Double>)
        case deleteObject(ObjectID)
        case addInstance(objectID: ObjectID)
        case deleteInstance(objectID: ObjectID, instanceID: InstanceID)
        case setTransform(
            objectID: ObjectID,
            instanceID: InstanceID,
            transform: InstanceTransform
        )
        case ensureOnBed
    }

    public struct MutationResult: Sendable {
        public let snapshot: SceneSnapshot
        public let createdObjectID: ObjectID?
        public let createdInstanceID: InstanceID?

        fileprivate init(
            snapshot: SceneSnapshot,
            createdObjectID: ObjectID? = nil,
            createdInstanceID: InstanceID? = nil
        ) {
            self.snapshot = snapshot
            self.createdObjectID = createdObjectID
            self.createdInstanceID = createdInstanceID
        }
    }

    private let handle: OpaquePointer
    private let lock = NSLock()

    public init() throws {
        try BridgeResult.validateABI()
        var pointer: OpaquePointer?
        try BridgeResult.consume(orca_plater_new(&pointer), operation: "create document")
        guard let pointer else {
            throw BridgeError.local(
                .internalInvariant,
                operation: "create document",
                diagnostic: "Bridge returned success without a document handle"
            )
        }
        handle = pointer
    }

    deinit {
        orca_plater_free(handle)
    }

    public func snapshot() throws -> SceneSnapshot {
        try lock.withLock {
            try snapshotLocked()
        }
    }

    /// Applies exactly one engine mutation and returns the complete scene at
    /// the resulting revision while retaining the document lock throughout.
    public func apply(_ mutation: Mutation) throws -> MutationResult {
        try lock.withLock {
            var mutationRevision: UInt64 = 0
            var createdObjectID: ObjectID?
            var createdInstanceID: InstanceID?

            switch mutation {
            case .importModel(let path, let bedCenter):
                var rawObjectID: UInt64 = 0
                let result = path.withCString { pathPointer in
                    orca_plater_add_stl(
                        handle,
                        pathPointer,
                        bedCenter.x,
                        bedCenter.y,
                        &rawObjectID,
                        &mutationRevision
                    )
                }
                try BridgeResult.consume(result, operation: "import model")
                createdObjectID = try Self.objectID(
                    rawObjectID,
                    operation: "import model"
                )

            case .deleteObject(let objectID):
                try BridgeResult.consume(
                    orca_plater_object_delete(
                        handle,
                        objectID.rawValue,
                        &mutationRevision
                    ),
                    operation: "delete object \(objectID)"
                )

            case .addInstance(let objectID):
                var rawInstanceID: UInt64 = 0
                try BridgeResult.consume(
                    orca_plater_instance_add(
                        handle,
                        objectID.rawValue,
                        &rawInstanceID,
                        &mutationRevision
                    ),
                    operation: "add instance to object \(objectID)"
                )
                createdInstanceID = try Self.instanceID(
                    rawInstanceID,
                    operation: "add instance"
                )

            case .deleteInstance(let objectID, let instanceID):
                try BridgeResult.consume(
                    orca_plater_instance_delete(
                        handle,
                        objectID.rawValue,
                        instanceID.rawValue,
                        &mutationRevision
                    ),
                    operation: "delete instance \(instanceID)"
                )

            case .setTransform(let objectID, let instanceID, let transform):
                var rawTransform = orca_instance_transform(
                    offset_x: transform.offsetX,
                    offset_y: transform.offsetY,
                    offset_z: transform.offsetZ,
                    rotation_z: transform.rotationZ,
                    scale: transform.scale
                )
                try BridgeResult.consume(
                    orca_plater_instance_set(
                        handle,
                        objectID.rawValue,
                        instanceID.rawValue,
                        &rawTransform,
                        &mutationRevision
                    ),
                    operation: "set transform for instance \(instanceID)"
                )

            case .ensureOnBed:
                try BridgeResult.consume(
                    orca_plater_ensure_on_bed(handle, &mutationRevision),
                    operation: "ensure scene on bed"
                )
            }

            let scene = try snapshotLocked()
            guard scene.revision.rawValue == mutationRevision else {
                throw BridgeError.local(
                    .internalInvariant,
                    operation: "apply document mutation",
                    diagnostic: "Mutation returned revision \(mutationRevision), snapshot returned \(scene.revision.rawValue)"
                )
            }
            return MutationResult(
                snapshot: scene,
                createdObjectID: createdObjectID,
                createdInstanceID: createdInstanceID
            )
        }
    }

    public func slice(
        to outputPath: String,
        progress: @escaping @Sendable (Int, String) -> Void
    ) throws -> SliceResult {
        try lock.withLock {
            try Self.withProgressContext(progress) { callback, context in
                var time = 0.0
                var bytes: Int64 = 0
                let result = outputPath.withCString { outputPointer in
                    orca_plater_slice_to_gcode(
                        handle,
                        outputPointer,
                        callback,
                        context,
                        &time,
                        &bytes
                    )
                }
                try BridgeResult.consume(result, operation: "slice document")
                return SliceResult(timeEstimateSeconds: time, gcodeBytes: bytes)
            }
        }
    }

    public func slice(
        to outputPath: String,
        presets: EnginePresets,
        progress: @escaping @Sendable (Int, String) -> Void
    ) throws -> SliceResult {
        try Self.withLockedHandles(plater: self, presets: presets) { platerHandle, presetHandle in
            try Self.withProgressContext(progress) { callback, context in
                var time = 0.0
                var bytes: Int64 = 0
                let result = outputPath.withCString { outputPointer in
                    orca_plater_slice_to_gcode_with_presets(
                        platerHandle,
                        presetHandle,
                        outputPointer,
                        callback,
                        context,
                        &time,
                        &bytes
                    )
                }
                try BridgeResult.consume(
                    result,
                    operation: "slice document with presets"
                )
                return SliceResult(timeEstimateSeconds: time, gcodeBytes: bytes)
            }
        }
    }

    private func snapshotLocked() throws -> SceneSnapshot {
        var rawSnapshot = orca_scene_snapshot()
        try BridgeResult.consume(
            orca_plater_snapshot(handle, &rawSnapshot),
            operation: "read scene snapshot"
        )
        defer { orca_scene_snapshot_dispose(&rawSnapshot) }

        guard rawSnapshot.document_id != 0 else {
            throw Self.invariant(
                operation: "read scene snapshot",
                "Bridge returned an invalid document ID"
            )
        }
        guard rawSnapshot.object_count >= 0 else {
            throw Self.invariant(
                operation: "read scene snapshot",
                "Bridge returned a negative object count"
            )
        }
        let objectCount = Int(rawSnapshot.object_count)
        if objectCount > 0, rawSnapshot.objects == nil {
            throw Self.invariant(
                operation: "read scene snapshot",
                "Bridge returned objects without storage"
            )
        }

        var objects: [SceneObject] = []
        objects.reserveCapacity(objectCount)
        if let objectPointer = rawSnapshot.objects {
            for objectIndex in 0..<objectCount {
                let rawObject = objectPointer[objectIndex]
                let objectID = try Self.objectID(
                    rawObject.id,
                    operation: "read scene snapshot"
                )
                let name = try Self.borrowedString(
                    rawObject.name,
                    operation: "read name for object \(objectID)"
                )
                guard rawObject.mesh_revision != 0 else {
                    throw Self.invariant(
                        operation: "read scene snapshot",
                        "Object \(objectID) has an invalid mesh revision"
                    )
                }
                guard rawObject.position_count > 0,
                      let positionPointer = rawObject.positions,
                      rawObject.index_count > 0,
                      let indexPointer = rawObject.indices else {
                    throw Self.invariant(
                        operation: "read scene snapshot",
                        "Object \(objectID) has incomplete mesh storage"
                    )
                }
                guard rawObject.instance_count >= 0 else {
                    throw Self.invariant(
                        operation: "read scene snapshot",
                        "Object \(objectID) has a negative instance count"
                    )
                }

                let positionCount = Int(rawObject.position_count)
                var positions: [SIMD3<Float>] = []
                positions.reserveCapacity(positionCount)
                for vertexIndex in 0..<positionCount {
                    let base = vertexIndex * 3
                    positions.append(SIMD3(
                        positionPointer[base],
                        positionPointer[base + 1],
                        positionPointer[base + 2]
                    ))
                }
                let indices = Array(UnsafeBufferPointer(
                    start: indexPointer,
                    count: Int(rawObject.index_count)
                ))

                let instanceCount = Int(rawObject.instance_count)
                if instanceCount > 0, rawObject.instances == nil {
                    throw Self.invariant(
                        operation: "read scene snapshot",
                        "Object \(objectID) has instances without storage"
                    )
                }
                var instances: [SceneInstance] = []
                instances.reserveCapacity(instanceCount)
                if let instancePointer = rawObject.instances {
                    for instanceIndex in 0..<instanceCount {
                        let rawInstance = instancePointer[instanceIndex]
                        let instanceID = try Self.instanceID(
                            rawInstance.id,
                            operation: "read scene snapshot"
                        )
                        let rawTransform = rawInstance.transform
                        guard rawTransform.offset_x.isFinite,
                              rawTransform.offset_y.isFinite,
                              rawTransform.offset_z.isFinite,
                              rawTransform.rotation_z.isFinite,
                              rawTransform.scale.isFinite,
                              rawTransform.scale > 0 else {
                            throw Self.invariant(
                                operation: "read scene snapshot",
                                "Instance \(instanceID) has an invalid transform"
                            )
                        }
                        instances.append(SceneInstance(
                            id: instanceID,
                            transform: InstanceTransform(
                                offsetX: rawTransform.offset_x,
                                offsetY: rawTransform.offset_y,
                                offsetZ: rawTransform.offset_z,
                                rotationZ: rawTransform.rotation_z,
                                scale: rawTransform.scale
                            )
                        ))
                    }
                }

                objects.append(SceneObject(
                    id: objectID,
                    name: name,
                    mesh: SceneMesh(
                        revision: rawObject.mesh_revision,
                        positions: positions,
                        indices: indices,
                        bounds: EngineBounds(
                            minimum: SIMD3(
                                rawObject.bbox_min.0,
                                rawObject.bbox_min.1,
                                rawObject.bbox_min.2
                            ),
                            maximum: SIMD3(
                                rawObject.bbox_max.0,
                                rawObject.bbox_max.1,
                                rawObject.bbox_max.2
                            )
                        ),
                        pivot: SIMD3(
                            rawObject.pivot.0,
                            rawObject.pivot.1,
                            rawObject.pivot.2
                        )
                    ),
                    instances: instances
                ))
            }
        }

        let uniqueObjectIDs = Set(objects.map(\.id))
        guard uniqueObjectIDs.count == objects.count else {
            throw Self.invariant(
                operation: "read scene snapshot",
                "Bridge returned duplicate object IDs"
            )
        }
        for object in objects {
            guard Set(object.instances.map(\.id)).count == object.instances.count else {
                throw Self.invariant(
                    operation: "read scene snapshot",
                    "Object \(object.id) contains duplicate instance IDs"
                )
            }
        }

        return SceneSnapshot(
            documentID: DocumentID(rawValue: rawSnapshot.document_id),
            revision: DocumentRevision(rawValue: rawSnapshot.revision),
            objects: objects
        )
    }

    private static func borrowedString(
        _ raw: orca_owned_string,
        operation: String
    ) throws -> String {
        guard raw.length <= UInt64(Int.max) else {
            throw invariant(operation: operation, "String exceeds Swift count range")
        }
        if raw.length == 0 { return "" }
        guard let data = raw.data else {
            throw invariant(operation: operation, "String storage is null")
        }
        let bytes = UnsafeRawBufferPointer(
            start: data,
            count: Int(raw.length)
        )
        guard let value = String(bytes: bytes, encoding: .utf8) else {
            throw invariant(operation: operation, "String is not valid UTF-8")
        }
        return value
    }

    private static func objectID(
        _ rawValue: UInt64,
        operation: String
    ) throws -> ObjectID {
        guard rawValue != 0 else {
            throw invariant(operation: operation, "Bridge returned an invalid object ID")
        }
        return ObjectID(rawValue: rawValue)
    }

    private static func instanceID(
        _ rawValue: UInt64,
        operation: String
    ) throws -> InstanceID {
        guard rawValue != 0 else {
            throw invariant(operation: operation, "Bridge returned an invalid instance ID")
        }
        return InstanceID(rawValue: rawValue)
    }

    private static func invariant(operation: String, _ diagnostic: String) -> BridgeError {
        BridgeError.local(
            .internalInvariant,
            operation: operation,
            diagnostic: diagnostic
        )
    }

    private static func withLockedHandles<Result>(
        plater: EnginePlater,
        presets: EnginePresets,
        _ body: (OpaquePointer, OpaquePointer) throws -> Result
    ) rethrows -> Result {
        // Fixed global order for cross-session calls: plater, then presets.
        try plater.lock.withLock {
            try presets.withLockedHandle { presetHandle in
                try body(plater.handle, presetHandle)
            }
        }
    }

    private static func withProgressContext<Result>(
        _ progress: @escaping @Sendable (Int, String) -> Void,
        _ body: (orca_progress_fn, UnsafeMutableRawPointer) throws -> Result
    ) throws -> Result {
        let box = ProgressBox(progress)
        let context = Unmanaged.passRetained(box).toOpaque()
        defer { Unmanaged<ProgressBox>.fromOpaque(context).release() }
        return try body(progressTrampoline, context)
    }
}

public struct SliceResult: Sendable {
    public let timeEstimateSeconds: Double
    public let gcodeBytes: Int64
}

private final class ProgressBox: @unchecked Sendable {
    let callback: @Sendable (Int, String) -> Void

    init(_ callback: @escaping @Sendable (Int, String) -> Void) {
        self.callback = callback
    }
}

private let progressTrampoline: orca_progress_fn = { percent, message, context in
    guard let context else { return }
    let box = Unmanaged<ProgressBox>.fromOpaque(context).takeUnretainedValue()
    box.callback(Int(percent), message.map(String.init(cString:)) ?? "")
}
