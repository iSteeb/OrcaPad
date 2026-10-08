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
        /// `label` names the undo step ("Move", "Scale", ...).
        case setTransform(
            objectID: ObjectID,
            instanceID: InstanceID,
            transform: InstanceTransform,
            label: String
        )
        case rotate(
            objectID: ObjectID,
            instanceID: InstanceID,
            axis: EngineAxis,
            radians: Double
        )
        case layFlat(
            objectID: ObjectID,
            instanceID: InstanceID,
            normal: SIMD3<Double>
        )
        case orientAll
        case arrange(allowRotations: Bool)
        case ensureOnBed
        /// Desktop Edit > Undo / Redo (one history step).
        case undo
        case redo
        case rename(objectID: ObjectID, name: String)
        /// Desktop "Delete all".
        case clear
        /// Desktop "Add Primitive" (new object).
        case addShapeObject(shape: PrimitiveShape, sizeMM: Double, bedCenter: SIMD2<Double>)
        /// Desktop load_generic_subobject (part / modifier / negative /
        /// blocker / enforcer from a shape).
        case volumeAddShape(
            objectID: ObjectID, instanceID: InstanceID, role: VolumeRole,
            shape: PrimitiveShape, sizeMM: Double)
        /// Desktop "Load..." (a file as one volume).
        case volumeAddFile(objectID: ObjectID, role: VolumeRole, path: String)
        case volumeSetType(objectID: ObjectID, volumeID: VolumeID, role: VolumeRole)
        case volumeDelete(objectID: ObjectID, volumeID: VolumeID)
        case volumeRename(objectID: ObjectID, volumeID: VolumeID, name: String)
        /// Desktop "Split to objects".
        case splitObjects(objectID: ObjectID)
        /// Desktop "Split to parts" (nil = the object's only model part).
        case splitParts(objectID: ObjectID, volumeID: VolumeID?)
        /// Desktop Selection::mirror (toggles one axis).
        case mirrorInstance(objectID: ObjectID, instanceID: InstanceID, axis: EngineAxis)
        /// Desktop clipboard.
        case copyObject(objectID: ObjectID)
        case pasteObject(bedCenter: SIMD2<Double>)
        /// Group (multi-selection) absolute transforms; one undo step.
        case groupSetTransforms([GroupTransform], label: String)
        /// Group rotation about each instance's own origin; one undo step.
        case groupRotate([GroupInstance], axis: EngineAxis, radians: Double)
        /// Per-object (volumeID nil) / per-part setting override.
        case setSetting(objectID: ObjectID, volumeID: VolumeID?, key: String, value: String)
        case eraseSetting(objectID: ObjectID, volumeID: VolumeID?, key: String)
    }

    /// One (object, instance) pair of a multi-selection.
    public struct GroupInstance: Sendable {
        public let objectID: ObjectID
        public let instanceID: InstanceID

        public init(objectID: ObjectID, instanceID: InstanceID) {
            self.objectID = objectID
            self.instanceID = instanceID
        }
    }

    /// An absolute transform for one group member.
    public struct GroupTransform: Sendable {
        public let instance: GroupInstance
        public let transform: InstanceTransform

        public init(instance: GroupInstance, transform: InstanceTransform) {
            self.instance = instance
            self.transform = transform
        }
    }

    public struct MutationResult: Sendable {
        public let snapshot: SceneSnapshot
        public let createdObjectID: ObjectID?
        public let createdInstanceID: InstanceID?
        /// Objects created by an import or a split (first is `createdObjectID`).
        public let createdObjectCount: Int

        /// Volumes created by `volumeAdd*` / parts created by `splitParts`.
        public let createdVolumeID: VolumeID?
        public let createdPartCount: Int

        /// Instances that did not fit the bed after `arrange` (0 otherwise).
        public let unprintableCount: Int

        fileprivate init(
            snapshot: SceneSnapshot,
            createdObjectID: ObjectID? = nil,
            createdInstanceID: InstanceID? = nil,
            createdObjectCount: Int = 0,
            unprintableCount: Int = 0,
            createdVolumeID: VolumeID? = nil,
            createdPartCount: Int = 0
        ) {
            self.snapshot = snapshot
            self.createdObjectID = createdObjectID
            self.createdInstanceID = createdInstanceID
            self.createdObjectCount = createdObjectCount
            self.unprintableCount = unprintableCount
            self.createdVolumeID = createdVolumeID
            self.createdPartCount = createdPartCount
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

    /// Option keys an object (or a part / modifier) may override.
    public static func settingsKeys(forVolume: Bool) throws -> [String] {
        let operation = "read overridable option keys"
        var raw = orca_owned_string()
        try BridgeResult.consume(
            orca_plater_settings_keys(forVolume ? 1 : 0, &raw), operation: operation
        )
        let json = try consumeBridgeString(&raw, operation: operation).get()
        guard let data = json.data(using: .utf8),
              let keys = try JSONSerialization.jsonObject(with: data) as? [String] else {
            throw invariant(operation: operation, "Bridge returned a malformed key list")
        }
        return keys
    }

    /// Current overrides of an object (volumeID nil) or one of its volumes.
    public func settings(objectID: ObjectID, volumeID: VolumeID?) throws -> [String: String] {
        let operation = "read overrides of object \(objectID)"
        return try lock.withLock {
            var raw = orca_owned_string()
            try BridgeResult.consume(
                orca_plater_settings_dump(
                    handle, objectID.rawValue, volumeID?.rawValue ?? 0, &raw
                ),
                operation: operation
            )
            let json = try consumeBridgeString(&raw, operation: operation).get()
            guard let data = json.data(using: .utf8),
                  let values = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
                throw Self.invariant(operation: operation, "Bridge returned a malformed dump")
            }
            return values
        }
    }

    /// Applies exactly one engine mutation and returns the complete scene at
    /// the resulting revision while retaining the document lock throughout.
    public func apply(_ mutation: Mutation, presets: EnginePresets? = nil) throws -> MutationResult {
        try lock.withLock {
            var mutationRevision: UInt64 = 0
            var createdObjectID: ObjectID?
            var createdInstanceID: InstanceID?
            var createdObjectCount = 0
            var arrangeUnprintableCount = 0
            var createdVolumeID: VolumeID?
            var createdPartCount = 0
            let presetHandle: OpaquePointer? = presets?.withUnsafeHandle { $0 }

            switch mutation {
            case .importModel(let path, let bedCenter):
                var rawObjectID: UInt64 = 0
                var objectCount: UInt32 = 0
                let result = path.withCString { pathPointer in
                    orca_plater_import_model(
                        handle,
                        pathPointer,
                        bedCenter.x,
                        bedCenter.y,
                        &rawObjectID,
                        &objectCount,
                        &mutationRevision
                    )
                }
                try BridgeResult.consume(result, operation: "import model")
                guard objectCount > 0 else {
                    throw BridgeError.local(
                        .internalInvariant,
                        operation: "import model",
                        diagnostic: "Bridge reported a successful import of zero objects"
                    )
                }
                createdObjectCount = Int(objectCount)
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

            case .setTransform(let objectID, let instanceID, let transform, let label):
                var rawTransform = orca_instance_transform(
                    offset_x: transform.offsetX,
                    offset_y: transform.offsetY,
                    offset_z: transform.offsetZ,
                    rotation_x: transform.rotationX,
                    rotation_y: transform.rotationY,
                    rotation_z: transform.rotationZ,
                    scale_x: transform.scaleX,
                    scale_y: transform.scaleY,
                    scale_z: transform.scaleZ
                )
                try BridgeResult.consume(
                    label.withCString { labelPointer in
                        orca_plater_instance_set(
                            handle,
                            objectID.rawValue,
                            instanceID.rawValue,
                            &rawTransform,
                            labelPointer,
                            &mutationRevision
                        )
                    },
                    operation: "set transform for instance \(instanceID)"
                )

            case .layFlat(let objectID, let instanceID, let normal):
                try BridgeResult.consume(
                    orca_plater_instance_lay_flat(
                        handle,
                        objectID.rawValue,
                        instanceID.rawValue,
                        normal.x, normal.y, normal.z,
                        &mutationRevision
                    ),
                    operation: "lay instance flat"
                )

            case .orientAll:
                try BridgeResult.consume(
                    orca_plater_orient(handle, presetHandle, 0, 0, &mutationRevision),
                    operation: "orient all instances"
                )

            case .arrange(let allowRotations):
                var unprintable: UInt32 = 0
                try BridgeResult.consume(
                    orca_plater_arrange(
                        handle,
                        presetHandle,
                        allowRotations ? 1 : 0,
                        &unprintable,
                        &mutationRevision
                    ),
                    operation: "arrange plate"
                )
                arrangeUnprintableCount = Int(unprintable)

            case .rotate(let objectID, let instanceID, let axis, let radians):
                try BridgeResult.consume(
                    orca_plater_instance_rotate(
                        handle,
                        objectID.rawValue,
                        instanceID.rawValue,
                        axis.rawValue,
                        radians,
                        &mutationRevision
                    ),
                    operation: "rotate instance \(instanceID)"
                )

            case .ensureOnBed:
                try BridgeResult.consume(
                    orca_plater_ensure_on_bed(handle, &mutationRevision),
                    operation: "ensure scene on bed"
                )

            case .undo:
                try BridgeResult.consume(
                    orca_plater_undo(handle, &mutationRevision),
                    operation: "undo"
                )

            case .redo:
                try BridgeResult.consume(
                    orca_plater_redo(handle, &mutationRevision),
                    operation: "redo"
                )

            case .rename(let objectID, let name):
                try BridgeResult.consume(
                    name.withCString { orca_plater_object_rename(handle, objectID.rawValue, $0, &mutationRevision) },
                    operation: "rename object \(objectID)"
                )

            case .clear:
                try BridgeResult.consume(
                    orca_plater_clear(handle, &mutationRevision),
                    operation: "delete all objects"
                )

            case .addShapeObject(let shape, let size, let bedCenter):
                var rawObjectID: UInt64 = 0
                try BridgeResult.consume(
                    orca_plater_add_shape_object(
                        handle, shape.rawValue, size, bedCenter.x, bedCenter.y,
                        &rawObjectID, &mutationRevision
                    ),
                    operation: "add shape object"
                )
                createdObjectCount = 1
                createdObjectID = try Self.objectID(rawObjectID, operation: "add shape object")

            case .volumeAddShape(let objectID, let instanceID, let role, let shape, let size):
                var rawVolumeID: UInt64 = 0
                try BridgeResult.consume(
                    orca_plater_volume_add_shape(
                        handle, objectID.rawValue, instanceID.rawValue, role.rawValue,
                        shape.rawValue, size, &rawVolumeID, &mutationRevision
                    ),
                    operation: "add volume to object \(objectID)"
                )
                createdVolumeID = try Self.volumeID(rawVolumeID, operation: "add volume")

            case .volumeAddFile(let objectID, let role, let path):
                var rawVolumeID: UInt64 = 0
                try BridgeResult.consume(
                    path.withCString { pointer in
                        orca_plater_volume_add_file(
                            handle, objectID.rawValue, role.rawValue, pointer,
                            &rawVolumeID, &mutationRevision
                        )
                    },
                    operation: "load volume from file"
                )
                createdVolumeID = try Self.volumeID(rawVolumeID, operation: "add volume")

            case .volumeSetType(let objectID, let volumeID, let role):
                try BridgeResult.consume(
                    orca_plater_volume_set_type(
                        handle, objectID.rawValue, volumeID.rawValue, role.rawValue,
                        &mutationRevision
                    ),
                    operation: "change volume type"
                )

            case .volumeDelete(let objectID, let volumeID):
                try BridgeResult.consume(
                    orca_plater_volume_delete(
                        handle, objectID.rawValue, volumeID.rawValue, &mutationRevision
                    ),
                    operation: "delete volume"
                )

            case .volumeRename(let objectID, let volumeID, let name):
                try BridgeResult.consume(
                    name.withCString { pointer in
                        orca_plater_volume_rename(
                            handle, objectID.rawValue, volumeID.rawValue, pointer,
                            &mutationRevision
                        )
                    },
                    operation: "rename volume"
                )

            case .splitObjects(let objectID):
                var rawObjectID: UInt64 = 0
                var objectCount: UInt32 = 0
                try BridgeResult.consume(
                    orca_plater_split_objects(
                        handle, objectID.rawValue, &rawObjectID, &objectCount,
                        &mutationRevision
                    ),
                    operation: "split object \(objectID) to objects"
                )
                createdObjectCount = Int(objectCount)
                createdObjectID = try Self.objectID(rawObjectID, operation: "split to objects")

            case .splitParts(let objectID, let volumeID):
                var partCount: UInt32 = 0
                try BridgeResult.consume(
                    orca_plater_split_parts(
                        handle, objectID.rawValue, volumeID?.rawValue ?? 0,
                        &partCount, &mutationRevision
                    ),
                    operation: "split object \(objectID) to parts"
                )
                createdPartCount = Int(partCount)

            case .mirrorInstance(let objectID, let instanceID, let axis):
                try BridgeResult.consume(
                    orca_plater_instance_mirror(
                        handle, objectID.rawValue, instanceID.rawValue,
                        axis.rawValue, &mutationRevision
                    ),
                    operation: "mirror instance \(instanceID)"
                )

            case .copyObject(let objectID):
                try BridgeResult.consume(
                    orca_plater_object_copy(handle, objectID.rawValue),
                    operation: "copy object \(objectID)"
                )

            case .groupSetTransforms(let group, let label):
                var objectIDs = [UInt64](repeating: 0, count: group.count)
                var instanceIDs = [UInt64](repeating: 0, count: group.count)
                var rawTransforms = [orca_instance_transform](
                    repeating: orca_instance_transform(
                        offset_x: 0, offset_y: 0, offset_z: 0,
                        rotation_x: 0, rotation_y: 0, rotation_z: 0,
                        scale_x: 1, scale_y: 1, scale_z: 1
                    ),
                    count: group.count
                )
                for (index, member) in group.enumerated() {
                    objectIDs[index] = member.instance.objectID.rawValue
                    instanceIDs[index] = member.instance.instanceID.rawValue
                    let t = member.transform
                    rawTransforms[index] = orca_instance_transform(
                        offset_x: t.offsetX, offset_y: t.offsetY, offset_z: t.offsetZ,
                        rotation_x: t.rotationX, rotation_y: t.rotationY, rotation_z: t.rotationZ,
                        scale_x: t.scaleX, scale_y: t.scaleY, scale_z: t.scaleZ
                    )
                }
                try BridgeResult.consume(
                    label.withCString { labelPointer in
                        objectIDs.withUnsafeBufferPointer { objects in
                            instanceIDs.withUnsafeBufferPointer { instances in
                                rawTransforms.withUnsafeBufferPointer { transforms in
                                    orca_plater_instances_set(
                                        handle,
                                        objects.baseAddress,
                                        instances.baseAddress,
                                        transforms.baseAddress,
                                        Int32(group.count),
                                        labelPointer,
                                        &mutationRevision
                                    )
                                }
                            }
                        }
                    },
                    operation: "move \(group.count) instance(s)"
                )

            case .groupRotate(let group, let axis, let radians):
                var objectIDs = [UInt64](repeating: 0, count: group.count)
                var instanceIDs = [UInt64](repeating: 0, count: group.count)
                for (index, member) in group.enumerated() {
                    objectIDs[index] = member.objectID.rawValue
                    instanceIDs[index] = member.instanceID.rawValue
                }
                try BridgeResult.consume(
                    objectIDs.withUnsafeBufferPointer { objects in
                        instanceIDs.withUnsafeBufferPointer { instances in
                            orca_plater_instances_rotate(
                                handle,
                                objects.baseAddress,
                                instances.baseAddress,
                                Int32(group.count),
                                axis.rawValue,
                                radians,
                                &mutationRevision
                            )
                        }
                    },
                    operation: "rotate \(group.count) instance(s)"
                )

            case .setSetting(let objectID, let volumeID, let key, let value):
                try BridgeResult.consume(
                    key.withCString { keyPointer in
                        value.withCString { valuePointer in
                            orca_plater_settings_set(
                                handle, objectID.rawValue, volumeID?.rawValue ?? 0,
                                keyPointer, valuePointer, &mutationRevision
                            )
                        }
                    },
                    operation: "set \(key) on object \(objectID)"
                )

            case .eraseSetting(let objectID, let volumeID, let key):
                try BridgeResult.consume(
                    key.withCString { keyPointer in
                        orca_plater_settings_erase(
                            handle, objectID.rawValue, volumeID?.rawValue ?? 0,
                            keyPointer, &mutationRevision
                        )
                    },
                    operation: "remove \(key) from object \(objectID)"
                )

            case .pasteObject(let bedCenter):
                var rawObjectID: UInt64 = 0
                try BridgeResult.consume(
                    orca_plater_object_paste(
                        handle, bedCenter.x, bedCenter.y, &rawObjectID,
                        &mutationRevision
                    ),
                    operation: "paste object"
                )
                createdObjectCount = 1
                createdObjectID = try Self.objectID(rawObjectID, operation: "paste object")
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
                createdInstanceID: createdInstanceID,
                createdObjectCount: createdObjectCount,
                unprintableCount: arrangeUnprintableCount,
                createdVolumeID: createdVolumeID,
                createdPartCount: createdPartCount
            )
        }
    }

    public func slice(
        to outputPath: String,
        job: SliceJob,
        progress: @escaping @Sendable (Int, String) -> Void
    ) throws -> SliceResult {
        try lock.withLock {
            try Self.withProgressContext(progress) { callback, context in
                var report = orca_slice_report()
                defer { orca_slice_report_dispose(&report) }
                let result = outputPath.withCString { outputPointer in
                    orca_plater_slice_to_gcode(
                        handle, outputPointer, callback, context, job.handle, &report
                    )
                }
                try BridgeResult.consume(result, operation: "slice document")
                return try SliceResult(decoding: report, operation: "slice document")
            }
        }
    }

    public func slice(
        to outputPath: String,
        presets: EnginePresets,
        job: SliceJob,
        progress: @escaping @Sendable (Int, String) -> Void
    ) throws -> SliceResult {
        try Self.withLockedHandles(plater: self, presets: presets) { platerHandle, presetHandle in
            try Self.withProgressContext(progress) { callback, context in
                var report = orca_slice_report()
                defer { orca_slice_report_dispose(&report) }
                let result = outputPath.withCString { outputPointer in
                    orca_plater_slice_to_gcode_with_presets(
                        platerHandle, presetHandle, outputPointer,
                        callback, context, job.handle, &report
                    )
                }
                try BridgeResult.consume(result, operation: "slice document with presets")
                return try SliceResult(decoding: report, operation: "slice document with presets")
            }
        }
    }

    /// Desktop "Open project": replaces the document (new document id) and
    /// the preset session atomically; returns the new authoritative scene.
    public func openProject(
        path: String,
        presets: EnginePresets
    ) throws -> ProjectOpenResult {
        try Self.withLockedHandles(plater: self, presets: presets) { platerHandle, presetHandle in
            var info = orca_project_info()
            let result = path.withCString { pointer in
                orca_project_open(platerHandle, presetHandle, pointer, &info)
            }
            try BridgeResult.consume(result, operation: "open project")
            let scene = try snapshotLocked()
            guard scene.revision.rawValue == info.revision else {
                throw BridgeError.local(
                    .internalInvariant,
                    operation: "open project",
                    diagnostic: "Open returned revision \(info.revision), snapshot returned \(scene.revision.rawValue)"
                )
            }
            guard let source = ProjectOpenResult.Source(rawValue: info.source) else {
                throw BridgeError.local(
                    .internalInvariant, operation: "open project",
                    diagnostic: "unknown project source \(info.source)"
                )
            }
            return ProjectOpenResult(
                snapshot: scene,
                objectCount: Int(info.object_count),
                plateCount: Int(info.plate_count),
                configApplied: info.config_applied != 0,
                source: source
            )
        }
    }

    /// Desktop "Save project" (single-plate Orca 3MF). Not a mutation.
    /// `thumbnail`: square top-down RGBA8 plate image (nil = none).
    public func saveProject(
        path: String,
        presets: EnginePresets,
        thumbnail: (size: Int, rgba: [UInt8])?
    ) throws {
        if let thumbnail, thumbnail.rgba.count != thumbnail.size * thumbnail.size * 4 {
            throw BridgeError.local(
                .invalidArgument, operation: "save project",
                diagnostic: "thumbnail buffer size does not match \(thumbnail.size)²"
            )
        }
        try Self.withLockedHandles(plater: self, presets: presets) { platerHandle, presetHandle in
            let result: orca_result = path.withCString { pointer in
                guard let thumbnail else {
                    return orca_project_save(platerHandle, presetHandle, pointer, 0, nil)
                }
                return thumbnail.rgba.withUnsafeBufferPointer { buffer in
                    orca_project_save(
                        platerHandle, presetHandle, pointer,
                        UInt32(thumbnail.size), buffer.baseAddress
                    )
                }
            }
            try BridgeResult.consume(result, operation: "save project")
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
                        let raw = rawInstance.transform
                        // Validate before constructing: InstanceTransform's
                        // initializer preconditions would trap otherwise.
                        guard [raw.offset_x, raw.offset_y, raw.offset_z,
                               raw.rotation_x, raw.rotation_y, raw.rotation_z,
                               raw.scale_x, raw.scale_y, raw.scale_z].allSatisfy(\.isFinite),
                              raw.scale_x > 0, raw.scale_y > 0, raw.scale_z > 0 else {
                            throw Self.invariant(
                                operation: "read scene snapshot",
                                "Instance \(instanceID) has an invalid transform"
                            )
                        }
                        let transform = InstanceTransform(
                            offsetX: raw.offset_x, offsetY: raw.offset_y, offsetZ: raw.offset_z,
                            rotationX: raw.rotation_x, rotationY: raw.rotation_y, rotationZ: raw.rotation_z,
                            scaleX: raw.scale_x, scaleY: raw.scale_y, scaleZ: raw.scale_z
                        )
                        let m = rawInstance.matrix
                        let matrix = simd_double4x4(columns: (
                            SIMD4(m.0, m.1, m.2, m.3),
                            SIMD4(m.4, m.5, m.6, m.7),
                            SIMD4(m.8, m.9, m.10, m.11),
                            SIMD4(m.12, m.13, m.14, m.15)
                        ))
                        instances.append(SceneInstance(
                            id: instanceID,
                            transform: transform,
                            matrix: matrix,
                            mirrored: rawInstance.mirrored != 0
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
                    instances: instances,
                    volumes: try Self.decodeVolumes(
                        rawObject, meshRevision: rawObject.mesh_revision,
                        pivot: SIMD3(
                            rawObject.pivot.0, rawObject.pivot.1, rawObject.pivot.2
                        ),
                        objectID: objectID
                    ),
                    overrideCount: Int(rawObject.override_count)
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

        let history = DocumentHistory(
            undoCount: Int(rawSnapshot.undo_count),
            redoCount: Int(rawSnapshot.redo_count),
            undoLabel: try Self.borrowedString(rawSnapshot.undo_label, operation: "read undo label"),
            redoLabel: try Self.borrowedString(rawSnapshot.redo_label, operation: "read redo label")
        )
        return SceneSnapshot(
            documentID: DocumentID(rawValue: rawSnapshot.document_id),
            revision: DocumentRevision(rawValue: rawSnapshot.revision),
            objects: objects,
            history: history
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

    private static func volumeID(
        _ rawValue: UInt64,
        operation: String
    ) throws -> VolumeID {
        guard rawValue != 0 else {
            throw invariant(operation: operation, "Bridge returned an invalid volume ID")
        }
        return VolumeID(rawValue: rawValue)
    }

    /// Decodes one object's volumes. Parts carry no own mesh (they render
    /// through the merged object mesh); other roles carry their object-space
    /// mesh keyed by the object's mesh revision and pivot.
    private static func decodeVolumes(
        _ rawObject: orca_scene_object,
        meshRevision: UInt64,
        pivot: SIMD3<Float>,
        objectID: ObjectID
    ) throws -> [SceneVolume] {
        let count = Int(rawObject.volume_count)
        guard count >= 0 else {
            throw invariant(
                operation: "read scene snapshot",
                "Object \(objectID) has a negative volume count"
            )
        }
        guard count > 0 else {
            throw invariant(
                operation: "read scene snapshot",
                "Object \(objectID) has no volumes"
            )
        }
        guard let volumePointer = rawObject.volumes else {
            throw invariant(
                operation: "read scene snapshot",
                "Object \(objectID) has volumes without storage"
            )
        }
        var volumes: [SceneVolume] = []
        volumes.reserveCapacity(count)
        for index in 0..<count {
            let raw = volumePointer[index]
            let volumeID = try volumeID(raw.id, operation: "read scene snapshot")
            let name = try borrowedString(
                raw.name, operation: "read name for volume \(volumeID)"
            )
            guard let role = VolumeRole(rawValue: raw.type) else {
                throw invariant(
                    operation: "read scene snapshot",
                    "Volume \(volumeID) has an unknown role \(raw.type)"
                )
            }
            var mesh: SceneMesh?
            if role != .part {
                guard raw.position_count > 0, let positions = raw.positions,
                      raw.index_count > 0, let indices = raw.indices else {
                    throw invariant(
                        operation: "read scene snapshot",
                        "Volume \(volumeID) has incomplete mesh storage"
                    )
                }
                var points: [SIMD3<Float>] = []
                points.reserveCapacity(Int(raw.position_count))
                for vertex in 0..<Int(raw.position_count) {
                    let base = vertex * 3
                    points.append(SIMD3(
                        positions[base], positions[base + 1], positions[base + 2]
                    ))
                }
                mesh = SceneMesh(
                    revision: meshRevision,
                    positions: points,
                    indices: Array(UnsafeBufferPointer(
                        start: indices, count: Int(raw.index_count)
                    )),
                    bounds: EngineBounds(
                        minimum: SIMD3(raw.bbox_min.0, raw.bbox_min.1, raw.bbox_min.2),
                        maximum: SIMD3(raw.bbox_max.0, raw.bbox_max.1, raw.bbox_max.2)
                    ),
                    pivot: pivot
                )
            }
            volumes.append(SceneVolume(
                id: volumeID,
                name: name,
                role: role,
                extruder: Int(raw.extruder),
                mesh: mesh,
                overrideCount: Int(raw.override_count)
            ))
        }
        return volumes
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

public struct ProjectOpenResult: Sendable {
    public enum Source: UInt8, Sendable {
        case orca = 0, bambu = 1, prusa = 2, other = 3
    }
    public let snapshot: SceneSnapshot
    public let objectCount: Int
    public let plateCount: Int
    /// Project settings were adopted into the preset session.
    public let configApplied: Bool
    public let source: Source
}

/// Cancellation token for one slice (desktop "Cancel"). `cancel()` is safe
/// from any thread while the slice runs; it never takes the engine lock.
public final class SliceJob: @unchecked Sendable {
    fileprivate let handle: OpaquePointer

    public init() throws {
        var raw: OpaquePointer?
        try BridgeResult.consume(orca_slice_job_new(&raw), operation: "create slice job")
        guard let raw else {
            throw BridgeError.local(
                .internalInvariant,
                operation: "create slice job",
                diagnostic: "Bridge returned OK without a slice job"
            )
        }
        handle = raw
    }

    public func cancel() { orca_slice_job_cancel(handle) }

    /// Client-rendered plate image (square, top-down RGBA8) the engine turns
    /// into the G-code thumbnails its `thumbnails` config asks for.
    public func setThumbnail(size: Int, rgba: [UInt8]) throws {
        guard rgba.count == size * size * 4 else {
            throw BridgeError.local(
                .invalidArgument, operation: "set slice thumbnail",
                diagnostic: "thumbnail buffer is \(rgba.count) bytes, expected \(size * size * 4)"
            )
        }
        try rgba.withUnsafeBufferPointer { buffer in
            try BridgeResult.consume(
                orca_slice_job_set_thumbnail(handle, UInt32(size), buffer.baseAddress),
                operation: "set slice thumbnail"
            )
        }
    }

    deinit { orca_slice_job_free(handle) }
}

public struct SliceWarning: Sendable, Hashable {
    public enum Level: Int32, Sendable { case tip = 0, warning = 1, critical = 2 }
    public enum Source: Int32, Sendable {
        case validate = 1, printStep = 2, objectStep = 3, gcode = 4, conflict = 5
    }
    public let level: Level
    public let source: Source
    /// Engine identifier (G-code warning id, validate opt_key, or
    /// "gcode_path_conflict"); may be empty.
    public let code: String
    /// Engine text; may be empty for coded G-code warnings.
    public let message: String
    /// Object name or newline-joined params.
    public let detail: String
}

public struct SliceResult: Sendable {
    public let timeEstimateSeconds: Double
    public let gcodeBytes: Int64
    public let warnings: [SliceWarning]

    init(decoding report: orca_slice_report, operation: String) throws {
        guard report.time_estimate_s.isFinite, report.time_estimate_s >= 0,
              report.gcode_bytes >= 0,
              report.warning_count == 0 || report.warnings != nil else {
            throw BridgeError.local(
                .internalInvariant, operation: operation,
                diagnostic: "\(operation): Bridge returned an inconsistent slice report"
            )
        }
        var warnings: [SliceWarning] = []
        warnings.reserveCapacity(Int(report.warning_count))
        for index in 0..<Int(report.warning_count) {
            // Strings are consumed IN PLACE through the report's buffer (each
            // is reset to empty), so the caller's orca_slice_report_dispose
            // never double-frees them.
            let slot = report.warnings.advanced(by: index)
            guard let level = SliceWarning.Level(rawValue: slot.pointee.level),
                  let source = SliceWarning.Source(rawValue: slot.pointee.source) else {
                throw BridgeError.local(
                    .internalInvariant, operation: operation,
                    diagnostic: "\(operation): unknown warning level \(slot.pointee.level) / source \(slot.pointee.source)"
                )
            }
            let code = try consumeBridgeString(&slot.pointee.code, operation: operation).get()
            let message = try consumeBridgeString(&slot.pointee.message, operation: operation).get()
            let detail = try consumeBridgeString(&slot.pointee.detail, operation: operation).get()
            warnings.append(SliceWarning(
                level: level, source: source, code: code, message: message, detail: detail
            ))
        }
        timeEstimateSeconds = report.time_estimate_s
        gcodeBytes = report.gcode_bytes
        self.warnings = warnings
    }
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
