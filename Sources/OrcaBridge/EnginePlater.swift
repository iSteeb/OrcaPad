// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

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
        /// Desktop "Fill bed" (FillBedJob): clones the object's template
        /// instance to fill the selected plate; returns the instance count.
        case fillBed(objectID: ObjectID, allowRotations: Bool)
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
        /// Batch delete (ABI v26): one undo step for the whole group.
        case deleteObjects([ObjectID])
        /// Multi-object clipboard (ABI v26).
        case copyObjects([ObjectID])
        case pasteObjects(bedCenter: SIMD2<Double>)
        /// Batch instance delete (ABI v26): one undo step for the whole
        /// group; an object left without instances is removed entirely.
        case deleteInstances([GroupInstance])
        /// Desktop "Paste Process Settings": replaces every override of the
        /// target with `overrides` in one undo step (ABI v26).
        case applySettings(objectID: ObjectID, volumeID: VolumeID?, overrides: [String: String])
        /// Plates (ABI v27): document-level plate mutations, one undo step
        /// each. `addPlate` and `duplicatePlate` report the new plate's id.
        case addPlate
        case deletePlate(PlateID)
        case renamePlate(PlateID, name: String)
        case lockPlate(PlateID, locked: Bool)
        case movePlateToFront(PlateID)
        case duplicatePlate(PlateID)
        /// Group (multi-selection) absolute transforms; one undo step.
        case groupSetTransforms([GroupTransform], label: String)
        /// Group rotation about each instance's own origin; one undo step.
        case groupRotate([GroupInstance], axis: EngineAxis, radians: Double)
        /// Per-object (volumeID nil) / per-part setting override.
        case setSetting(objectID: ObjectID, volumeID: VolumeID?, key: String, value: String)
        case eraseSetting(objectID: ObjectID, volumeID: VolumeID?, key: String)
        /// Desktop printable toggle (instanceID nil = whole object).
        case setPrintable(objectID: ObjectID, instanceID: InstanceID?, printable: Bool)
        case setInstanceCount(objectID: ObjectID, count: Int)
        case cloneObject(objectID: ObjectID, count: Int)
        case instanceToObject(objectID: ObjectID, instanceID: InstanceID)
        case mergeObjects([ObjectID])
        /// Needs the presets session (machine volume).
        case scaleToFit(objectID: ObjectID, instanceID: InstanceID)
        case convertUnits(objectID: ObjectID, UnitConversion)
        /// Per-layer custom G-code on the SELECTED plate (ABI v24/v32):
        /// colour change / pause / tool change / raw custom G-code.
        case addCustomGcode(printZ: Double, kind: CustomGcodeKind,
                            extruder: Int, color: String, extra: String)
        case deleteCustomGcode(printZ: Double)
        /// Desktop "Cut" (plane): the object is replaced by the kept parts.
        case cut(objectID: ObjectID, instanceID: InstanceID,
                 planePoint: SIMD3<Double>, normal: SIMD3<Double>, keep: CutKeep)
        /// Desktop painter gizmo (ABI v36): one sphere-brush stroke.
        case paintSphere(objectID: ObjectID, volumeID: VolumeID, layer: PaintLayer,
                         hit: SIMD3<Double>, viewDir: SIMD3<Double>,
                         radiusMM: Double, state: Int32)
        /// Removes every stroke of one paint layer.
        case paintReset(objectID: ObjectID, volumeID: VolumeID, layer: PaintLayer)
        /// Desktop layer-range modifiers (ABI v39): REPLACES the object's
        /// height ranges in one undo step.
        case setHeightRanges(objectID: ObjectID, ranges: [HeightRange])
        /// Desktop Simplify gizmo (ABI v40): quadric edge collapse on one
        /// volume. useCount drives toward wantedCount triangles; otherwise
        /// quality (maxError).
        case simplifyVolume(objectID: ObjectID, volumeID: VolumeID,
                            useCount: Bool, wantedCount: UInt32, maxError: Double)
        /// Desktop "Subdivision mesh" (ABI v40): igl Loop, 4x faces.
        case subdivideVolume(objectID: ObjectID, volumeID: VolumeID)
        /// Desktop slider-tick EDIT (ABI v40): replaces the item at printZ.
        case editCustomGcode(printZ: Double, kind: CustomGcodeKind,
                             extruder: Int, color: String, extra: String)
    }

    /// One layer-height range (desktop height-range modifiers).
    public struct HeightRange: Sendable, Equatable {
        public let minZ: Double
        public let maxZ: Double
        public let layerHeight: Double

        public init(minZ: Double, maxZ: Double, layerHeight: Double) {
            self.minZ = minZ
            self.maxZ = maxZ
            self.layerHeight = layerHeight
        }
    }

    /// Paint layers (each a ModelVolume FacetsAnnotation consumed by slicing).
    public enum PaintLayer: UInt8, Sendable, CaseIterable {
        case support = 0
        case seam = 1
        case mmu = 2
        case fuzzy = 3

        public var label: String {
            switch self {
            case .support: return "Support"
            case .seam: return "Seam"
            case .mmu: return "MMU"
            case .fuzzy: return "Fuzzy skin"
            }
        }
    }

    /// One painted triangle in world (engine) coordinates.
    public struct PaintTriangle: Sendable {
        public let a: SIMD3<Float>
        public let b: SIMD3<Float>
        public let c: SIMD3<Float>
        /// Engine EnforcerBlockerType value (1=enforcer/colour1, 2=blocker/colour2, ..).
        public let state: UInt8
    }

    /// What a plane cut keeps (desktop CutDialog radio buttons).
    public enum CutKeep: Int32, Sendable, CaseIterable {
        case upper = 0
        case lower = 1
        case bothAsParts = 2
        case bothAsObjects = 3

        public var label: String {
            switch self {
            case .upper: return "Upper part"
            case .lower: return "Lower part"
            case .bothAsParts: return "Both as parts"
            case .bothAsObjects: return "Both as objects"
            }
        }
    }

    /// Desktop layer-tick custom G-code types (CustomGCode::Type).
    public enum CustomGcodeKind: Int32, Sendable, CaseIterable {
        case colorChange = 0
        case pausePrint = 1
        case toolChange = 2
        /// Read-only: projects may carry template ticks; ADDING one is a
        /// typed unsupported capability at the Bridge.
        case template = 3
        case custom = 4

        public var label: String {
            switch self {
            case .colorChange: return "Colour change"
            case .pausePrint: return "Pause print"
            case .toolChange: return "Tool change"
            case .template: return "Template"
            case .custom: return "Custom G-code"
            }
        }
    }

    /// One layer tick (ascending print_z order).
    public struct CustomGcodeItem: Identifiable, Sendable, Equatable {
        public let printZ: Double
        public let kind: CustomGcodeKind
        /// 1-based extruder (colour / tool changes).
        public let extruder: Int
        /// #rrggbb for colour changes, pause message otherwise.
        public let color: String
        /// G-code text (custom) or message (pause).
        public let extra: String
        public var id: Double { printZ }
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

        /// Plate created by `addPlate` / `duplicatePlate`.
        public let createdPlateID: PlateID?

        /// Instances that did not fit the bed after `arrange` (0 otherwise).
        public let unprintableCount: Int

        /// Instances created by `fillBed` (0 otherwise).
        public let fillBedAddedInstances: Int

        fileprivate init(
            snapshot: SceneSnapshot,
            createdObjectID: ObjectID? = nil,
            createdInstanceID: InstanceID? = nil,
            createdObjectCount: Int = 0,
            unprintableCount: Int = 0,
            createdVolumeID: VolumeID? = nil,
            createdPartCount: Int = 0,
            createdPlateID: PlateID? = nil,
            fillBedAddedInstances: Int = 0
        ) {
            self.snapshot = snapshot
            self.createdObjectID = createdObjectID
            self.createdInstanceID = createdInstanceID
            self.createdObjectCount = createdObjectCount
            self.unprintableCount = unprintableCount
            self.createdVolumeID = createdVolumeID
            self.createdPartCount = createdPartCount
            self.createdPlateID = createdPlateID
            self.fillBedAddedInstances = fillBedAddedInstances
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

    // MARK: Plates (ABI v27)

    /// Bed geometry from the selected printer (client-driven; plate boxes
    /// derive from it). Not undoable; returns the re-read snapshot.
    public func setBed(
        originX: Double, originY: Double,
        width: Double, depth: Double, height: Double
    ) throws -> SceneSnapshot {
        try lock.withLock {
            var raw = orca_scene_snapshot()
            try BridgeResult.consume(
                orca_plater_set_bed(
                    handle, originX, originY, width, depth, height, &raw
                ),
                operation: "set bed geometry"
            )
            defer { orca_scene_snapshot_dispose(&raw) }
            return try Self.decodeSnapshot(raw)
        }
    }

    /// Selects the working plate (import target, slice source). Session
    /// state; returns the re-read snapshot without a revision change.
    public func selectPlate(_ id: PlateID) throws -> SceneSnapshot {
        try lock.withLock {
            var raw = orca_scene_snapshot()
            try BridgeResult.consume(
                orca_plater_plate_select(handle, id.rawValue, &raw),
                operation: "select plate \(id)"
            )
            defer { orca_scene_snapshot_dispose(&raw) }
            return try Self.decodeSnapshot(raw)
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

    /// Painted triangles of one layer (world coordinates), by state — the
    /// renderer overlay source. Read-only.
    public func volumePaint(
        objectID: ObjectID, volumeID: VolumeID, layer: PaintLayer
    ) throws -> [PaintTriangle] {
        try lock.withLock {
            var raw = orca_paint_mesh()
            try BridgeResult.consume(
                orca_plater_volume_paint(
                    handle, objectID.rawValue, volumeID.rawValue,
                    layer.rawValue, &raw
                ),
                operation: "read paint"
            )
            defer { orca_paint_mesh_dispose(&raw) }
            guard raw.count == 0 || raw.triangles != nil else {
                throw BridgeError.local(
                    .internalInvariant, operation: "read paint",
                    diagnostic: "Bridge returned paint without storage"
                )
            }
            var triangles: [PaintTriangle] = []
            triangles.reserveCapacity(Int(raw.count))
            // C fixed-size arrays import as tuples; read by byte offset
            // (same pattern as the toolpath extruder stats).
            func position(_ tuple: (Float, Float, Float, Float, Float, Float,
                                    Float, Float, Float), _ index: Int) -> Float {
                withUnsafeBytes(of: tuple) {
                    $0.loadUnaligned(fromByteOffset: index * MemoryLayout<Float>.stride,
                                     as: Float.self)
                }
            }
            for index in 0..<Int(raw.count) {
                let t = raw.triangles[index]
                triangles.append(PaintTriangle(
                    a: SIMD3(position(t.positions, 0), position(t.positions, 1), position(t.positions, 2)),
                    b: SIMD3(position(t.positions, 3), position(t.positions, 4), position(t.positions, 5)),
                    c: SIMD3(position(t.positions, 6), position(t.positions, 7), position(t.positions, 8)),
                    state: t.state))
            }
            return triangles
        }
    }

    // MARK: Hull / COG + text (ABI v37)

    /// Convex hull + volume centroid of an object (world space of its
    /// first instance).
    public struct HullMesh: Sendable {
        public let positions: [SIMD3<Float>]
        public let indices: [UInt32]
        public let centroid: SIMD3<Float>
    }

    public func objectHull(objectID: ObjectID) throws -> HullMesh {
        try lock.withLock {
            var raw = orca_hull_mesh()
            try BridgeResult.consume(
                orca_plater_object_hull(handle, objectID.rawValue, &raw),
                operation: "object hull"
            )
            defer { orca_hull_mesh_dispose(&raw) }
            guard raw.index_count > 0, raw.positions != nil, raw.indices != nil else {
                throw BridgeError.local(
                    .internalInvariant, operation: "object hull",
                    diagnostic: "Bridge returned a hull without storage"
                )
            }
            var positions: [SIMD3<Float>] = []
            positions.reserveCapacity(Int(raw.vertex_count))
            for index in 0..<Int(raw.vertex_count) {
                positions.append(SIMD3(
                    raw.positions[index * 3], raw.positions[index * 3 + 1],
                    raw.positions[index * 3 + 2]))
            }
            let indices = Array(UnsafeBufferPointer(
                start: raw.indices, count: Int(raw.index_count)))
            return HullMesh(
                positions: positions, indices: indices,
                centroid: SIMD3(raw.centroid.0, raw.centroid.1, raw.centroid.2))
        }
    }

    /// Desktop "Add Text" v1: standalone raised text object at the bed
    /// center (bundled Sarabun; one undo step).
    public func addTextObject(
        text: String, fontPath: String, sizeMM: Double, depthMM: Double,
        bedCenter: SIMD2<Double>
    ) throws -> MutationResult {
        try lock.withLock {
            var mutationRevision: UInt64 = 0
            var rawObjectID: UInt64 = 0
            let result = text.withCString { textPointer in
                fontPath.withCString { fontPointer in
                    orca_plater_add_text_object(
                        handle, fontPointer, textPointer,
                        sizeMM, depthMM, bedCenter.x, bedCenter.y,
                        &rawObjectID, &mutationRevision)
                }
            }
            try BridgeResult.consume(result, operation: "add text object")
            let scene = try snapshotLocked()
            guard scene.revision.rawValue == mutationRevision else {
                throw BridgeError.local(
                    .internalInvariant, operation: "add text object",
                    diagnostic: "revision mismatch after add text")
            }
            return MutationResult(
                snapshot: scene,
                createdObjectID: try Self.objectID(rawObjectID, operation: "add text object"),
                createdObjectCount: 1)
        }
    }

    /// Desktop "Add SVG" v1: standalone raised SVG object (ABI v38).
    public func addSVGObject(
        path: String, depthMM: Double, bedCenter: SIMD2<Double>
    ) throws -> MutationResult {
        try lock.withLock {
            var mutationRevision: UInt64 = 0
            var rawObjectID: UInt64 = 0
            let result = path.withCString { pointer in
                orca_plater_add_svg_object(
                    handle, pointer, depthMM, bedCenter.x, bedCenter.y,
                    &rawObjectID, &mutationRevision)
            }
            try BridgeResult.consume(result, operation: "add svg object")
            let scene = try snapshotLocked()
            guard scene.revision.rawValue == mutationRevision else {
                throw BridgeError.local(
                    .internalInvariant, operation: "add svg object",
                    diagnostic: "revision mismatch after add svg")
            }
            return MutationResult(
                snapshot: scene,
                createdObjectID: try Self.objectID(rawObjectID, operation: "add svg object"),
                createdObjectCount: 1)
        }
    }

    /// The object's layer-height ranges, ascending (ABI v39).
    public func objectHeightRanges(objectID: ObjectID) throws -> [HeightRange] {
        try lock.withLock {
            var raw: UnsafeMutablePointer<orca_height_range>?
            var count: UInt32 = 0
            try BridgeResult.consume(
                orca_plater_object_height_ranges(
                    handle, objectID.rawValue, &raw, &count),
                operation: "read height ranges"
            )
            let buffer = UnsafeBufferPointer(start: raw, count: Int(count))
            defer { orca_height_ranges_dispose(raw) }
            return buffer.map {
                HeightRange(minZ: $0.min_z, maxZ: $0.max_z, layerHeight: $0.layer_height)
            }
        }
    }

    /// The selected plate's custom G-code ticks, ascending print_z.
    public func customGcodes() throws -> [CustomGcodeItem] {
        try lock.withLock {
            var count: Int32 = 0
            try BridgeResult.consume(
                orca_plater_custom_gcode_count(handle, &count),
                operation: "read custom G-code count"
            )
            var items: [CustomGcodeItem] = []
            items.reserveCapacity(Int(count))
            for index in 0..<count {
                var raw = orca_custom_gcode_item()
                try BridgeResult.consume(
                    orca_plater_custom_gcode_item(handle, index, &raw),
                    operation: "read custom G-code item"
                )
                defer { orca_custom_gcode_item_dispose(&raw) }
                guard let kind = CustomGcodeKind(rawValue: raw.type) else {
                    throw BridgeError.local(
                        .internalInvariant, operation: "read custom G-code item",
                        diagnostic: "engine returned an unsupported custom G-code type \(raw.type)"
                    )
                }
                let color = try consumeBridgeString(&raw.color, operation: "custom G-code").get()
                let extra = try consumeBridgeString(&raw.extra, operation: "custom G-code").get()
                items.append(CustomGcodeItem(
                    printZ: raw.print_z, kind: kind, extruder: Int(raw.extruder),
                    color: color, extra: extra))
            }
            return items
        }
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
            /// Clipboard copies are document READS: they take no revision and
            /// must not be checked against the snapshot's (the equality
            /// guard below would reject every copy on a non-empty document —
            /// mutationRevision stays 0 while the document is at N ≥ 1).
            var expectsRevisionAdvance = true
            var createdObjectID: ObjectID?
            var createdInstanceID: InstanceID?
            var createdObjectCount = 0
            var arrangeUnprintableCount = 0
            var fillBedAddedInstances = 0
            var createdVolumeID: VolumeID?
            var createdPartCount = 0
            var createdPlateID: PlateID?
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

            case .fillBed(let objectID, let allowRotations):
                var added: UInt32 = 0
                try BridgeResult.consume(
                    orca_plater_fill_bed(
                        handle,
                        presetHandle,
                        objectID.rawValue,
                        allowRotations ? 1 : 0,
                        &added,
                        &mutationRevision
                    ),
                    operation: "fill bed"
                )
                fillBedAddedInstances = Int(added)

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
                expectsRevisionAdvance = false
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

            case .setPrintable(let objectID, let instanceID, let printable):
                try BridgeResult.consume(
                    orca_plater_set_printable(
                        handle, objectID.rawValue, instanceID?.rawValue ?? 0,
                        printable ? 1 : 0, &mutationRevision
                    ),
                    operation: "set printable"
                )

            case .setInstanceCount(let objectID, let count):
                try BridgeResult.consume(
                    orca_plater_set_instance_count(
                        handle, objectID.rawValue, Int32(clamping: count), &mutationRevision
                    ),
                    operation: "set number of instances"
                )

            case .cloneObject(let objectID, let count):
                var rawObjectID: UInt64 = 0
                try BridgeResult.consume(
                    orca_plater_clone_object(
                        handle, objectID.rawValue, Int32(clamping: count), &rawObjectID,
                        &mutationRevision
                    ),
                    operation: "clone object \(objectID)"
                )
                createdObjectCount = count
                createdObjectID = try Self.objectID(rawObjectID, operation: "clone object")

            case .instanceToObject(let objectID, let instanceID):
                var rawObjectID: UInt64 = 0
                try BridgeResult.consume(
                    orca_plater_instance_to_object(
                        handle, objectID.rawValue, instanceID.rawValue, &rawObjectID,
                        &mutationRevision
                    ),
                    operation: "set instance as object"
                )
                createdObjectCount = 1
                createdObjectID = try Self.objectID(rawObjectID, operation: "instance to object")

            case .mergeObjects(let objectIDs):
                var rawObjectID: UInt64 = 0
                let raw = objectIDs.map(\.rawValue)
                try BridgeResult.consume(
                    raw.withUnsafeBufferPointer { ids in
                        orca_plater_merge_objects(
                            handle, ids.baseAddress, Int32(clamping: raw.count),
                            &rawObjectID, &mutationRevision
                        )
                    },
                    operation: "assemble \(objectIDs.count) objects"
                )
                createdObjectCount = 1
                createdObjectID = try Self.objectID(rawObjectID, operation: "assemble")

            case .scaleToFit(let objectID, let instanceID):
                try BridgeResult.consume(
                    orca_plater_scale_to_fit(
                        handle, presetHandle, objectID.rawValue, instanceID.rawValue,
                        &mutationRevision
                    ),
                    operation: "scale to build volume"
                )

            case .convertUnits(let objectID, let conversion):
                var rawObjectID: UInt64 = 0
                try BridgeResult.consume(
                    orca_plater_convert_units(
                        handle, objectID.rawValue, conversion.rawValue, &rawObjectID,
                        &mutationRevision
                    ),
                    operation: conversion.label
                )
                createdObjectCount = 1
                createdObjectID = try Self.objectID(rawObjectID, operation: "convert units")

            case .addCustomGcode(let printZ, let kind, let extruder, let color, let extra):
                try color.withCString { colorPointer in
                    try extra.withCString { extraPointer in
                        try BridgeResult.consume(
                            orca_plater_custom_gcode_add(
                                handle, printZ, kind.rawValue, Int32(extruder),
                                colorPointer, extraPointer, &mutationRevision
                            ),
                            operation: "add custom G-code"
                        )
                    }
                }

            case .deleteCustomGcode(let printZ):
                try BridgeResult.consume(
                    orca_plater_custom_gcode_delete(handle, printZ, &mutationRevision),
                    operation: "delete custom G-code"
                )

            case .paintSphere(let objectID, let volumeID, let layer, let hit,
                              let viewDir, let radiusMM, let state):
                try BridgeResult.consume(
                    orca_plater_volume_paint_sphere(
                        handle, objectID.rawValue, volumeID.rawValue, layer.rawValue,
                        hit.x, hit.y, hit.z,
                        viewDir.x, viewDir.y, viewDir.z,
                        radiusMM, state, &mutationRevision
                    ),
                    operation: "paint"
                )

            case .setHeightRanges(let objectID, let ranges):
                var raw = ranges.map { range in
                    orca_height_range(
                        min_z: range.minZ, max_z: range.maxZ,
                        layer_height: range.layerHeight)
                }
                try BridgeResult.consume(
                    raw.withUnsafeBufferPointer { buffer in
                        orca_plater_object_set_height_ranges(
                            handle, objectID.rawValue,
                            buffer.baseAddress, UInt32(ranges.count),
                            &mutationRevision)
                    },
                    operation: "set height ranges"
                )

            case .simplifyVolume(let objectID, let volumeID, let useCount,
                                 let wantedCount, let maxError):
                var triangles: UInt32 = 0
                try BridgeResult.consume(
                    orca_plater_volume_simplify(
                        handle, objectID.rawValue, volumeID.rawValue,
                        useCount ? 1 : 0, wantedCount, maxError,
                        &triangles, &mutationRevision),
                    operation: "simplify volume"
                )

            case .subdivideVolume(let objectID, let volumeID):
                var triangles: UInt32 = 0
                try BridgeResult.consume(
                    orca_plater_volume_subdivide(
                        handle, objectID.rawValue, volumeID.rawValue,
                        &triangles, &mutationRevision),
                    operation: "subdivide volume"
                )

            case .editCustomGcode(let printZ, let kind, let extruder,
                                  let color, let extra):
                try color.withCString { colorPointer in
                    try extra.withCString { extraPointer in
                        try BridgeResult.consume(
                            orca_plater_custom_gcode_edit(
                                handle, printZ, kind.rawValue, Int32(extruder),
                                colorPointer, extraPointer, &mutationRevision),
                            operation: "edit custom G-code"
                        )
                    }
                }

            case .paintReset(let objectID, let volumeID, let layer):
                try BridgeResult.consume(
                    orca_plater_volume_paint_reset(
                        handle, objectID.rawValue, volumeID.rawValue,
                        layer.rawValue, &mutationRevision
                    ),
                    operation: "clear paint"
                )

            case .cut(let objectID, let instanceID, let point, let normal, let keep):
                var rawObjectID: UInt64 = 0
                var objectCount: UInt32 = 0
                try BridgeResult.consume(
                    orca_plater_object_cut(
                        handle, objectID.rawValue, instanceID.rawValue,
                        point.x, point.y, point.z,
                        normal.x, normal.y, normal.z, keep.rawValue,
                        &rawObjectID, &objectCount, &mutationRevision
                    ),
                    operation: "cut object"
                )
                createdObjectCount = Int(objectCount)
                createdObjectID = try Self.objectID(rawObjectID, operation: "cut object")

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

            case .deleteObjects(let objectIDs):
                let rawIDs = objectIDs.map(\.rawValue)
                try BridgeResult.consume(
                    rawIDs.withUnsafeBufferPointer { buffer in
                        orca_plater_objects_delete(
                            handle, buffer.baseAddress, Int32(objectIDs.count),
                            &mutationRevision
                        )
                    },
                    operation: "delete \(objectIDs.count) object(s)"
                )

            case .copyObjects(let objectIDs):
                expectsRevisionAdvance = false
                let rawIDs = objectIDs.map(\.rawValue)
                try BridgeResult.consume(
                    rawIDs.withUnsafeBufferPointer { buffer in
                        orca_plater_objects_copy(
                            handle, buffer.baseAddress, Int32(objectIDs.count)
                        )
                    },
                    operation: "copy \(objectIDs.count) object(s)"
                )

            case .deleteInstances(let group):
                var objectIDs = [UInt64](repeating: 0, count: group.count)
                var instanceIDs = [UInt64](repeating: 0, count: group.count)
                for (index, member) in group.enumerated() {
                    objectIDs[index] = member.objectID.rawValue
                    instanceIDs[index] = member.instanceID.rawValue
                }
                try BridgeResult.consume(
                    objectIDs.withUnsafeBufferPointer { objects in
                        instanceIDs.withUnsafeBufferPointer { instances in
                            orca_plater_instances_delete(
                                handle, objects.baseAddress, instances.baseAddress,
                                Int32(group.count), &mutationRevision
                            )
                        }
                    },
                    operation: "delete \(group.count) instance(s)"
                )

            case .pasteObjects(let bedCenter):
                // Generous fixed capacity: whole-object clipboard entries;
                // a plate larger than this fails loudly (typed) instead of
                // truncating.
                var pastedIDs = [UInt64](repeating: 0, count: 1024)
                var pastedCount: Int32 = 0
                try BridgeResult.consume(
                    pastedIDs.withUnsafeMutableBufferPointer { buffer in
                        orca_plater_objects_paste(
                            handle, bedCenter.x, bedCenter.y,
                            buffer.baseAddress, Int32(buffer.count),
                            &pastedCount, &mutationRevision
                        )
                    },
                    operation: "paste objects"
                )
                createdObjectCount = Int(pastedCount)
                createdObjectID = pastedCount > 0
                    ? try Self.objectID(pastedIDs[0], operation: "paste objects") : nil

            case .applySettings(let objectID, let volumeID, let overrides):
                let orderedKeys = Array(overrides.keys)
                // C-string arena: mutable duplicates own the memory, the call
                // receives an immutable view.
                let allocatedKeys = orderedKeys.map { strdup($0) }
                let allocatedValues = orderedKeys.map { strdup(overrides[$0] ?? "") }
                defer {
                    allocatedKeys.forEach { free($0) }
                    allocatedValues.forEach { free($0) }
                }
                let cKeys: [UnsafePointer<CChar>?] =
                    allocatedKeys.map { $0.map { UnsafePointer($0) } }
                let cValues: [UnsafePointer<CChar>?] =
                    allocatedValues.map { $0.map { UnsafePointer($0) } }
                try BridgeResult.consume(
                    cKeys.withUnsafeBufferPointer { keys in
                        cValues.withUnsafeBufferPointer { values in
                            orca_plater_settings_apply(
                                handle, objectID.rawValue, volumeID?.rawValue ?? 0,
                                keys.baseAddress, values.baseAddress,
                                Int32(orderedKeys.count), &mutationRevision
                            )
                        }
                    },
                    operation: "paste settings onto object \(objectID)"
                )

            case .addPlate:
                var rawPlateID: UInt64 = 0
                try BridgeResult.consume(
                    orca_plater_plate_add(handle, &rawPlateID, &mutationRevision),
                    operation: "add plate"
                )
                createdPlateID = try Self.plateID(rawPlateID, operation: "add plate")

            case .deletePlate(let plateID):
                try BridgeResult.consume(
                    orca_plater_plate_delete(
                        handle, plateID.rawValue, &mutationRevision
                    ),
                    operation: "delete plate \(plateID)"
                )

            case .renamePlate(let plateID, let name):
                try BridgeResult.consume(
                    name.withCString { namePointer in
                        orca_plater_plate_rename(
                            handle, plateID.rawValue, namePointer, &mutationRevision
                        )
                    },
                    operation: "rename plate \(plateID)"
                )

            case .lockPlate(let plateID, let locked):
                try BridgeResult.consume(
                    orca_plater_plate_lock(
                        handle, plateID.rawValue, locked ? 1 : 0, &mutationRevision
                    ),
                    operation: "\(locked ? "lock" : "unlock") plate \(plateID)"
                )

            case .movePlateToFront(let plateID):
                try BridgeResult.consume(
                    orca_plater_plate_move_to_front(
                        handle, plateID.rawValue, &mutationRevision
                    ),
                    operation: "move plate \(plateID) to front"
                )

            case .duplicatePlate(let plateID):
                var rawPlateID: UInt64 = 0
                try BridgeResult.consume(
                    orca_plater_plate_duplicate(
                        handle, plateID.rawValue, &rawPlateID, &mutationRevision
                    ),
                    operation: "duplicate plate \(plateID)"
                )
                createdPlateID = try Self.plateID(rawPlateID, operation: "duplicate plate")
            }

            let scene = try snapshotLocked()
            if expectsRevisionAdvance {
                guard scene.revision.rawValue == mutationRevision else {
                    throw BridgeError.local(
                        .internalInvariant,
                        operation: "apply document mutation",
                        diagnostic: "Mutation returned revision \(mutationRevision), snapshot returned \(scene.revision.rawValue)"
                    )
                }
            }
            return MutationResult(
                snapshot: scene,
                createdObjectID: createdObjectID,
                createdInstanceID: createdInstanceID,
                createdObjectCount: createdObjectCount,
                unprintableCount: arrangeUnprintableCount,
                createdVolumeID: createdVolumeID,
                createdPartCount: createdPartCount,
                createdPlateID: createdPlateID,
                fillBedAddedInstances: fillBedAddedInstances
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

    /// Desktop "Slice all": every non-empty plate in order into ONE G-code
    /// file with `; ORCA_PLATE ... begin/end` markers between the plates.
    /// Each plate's section is plate-relative (like a per-plate export).
    public func sliceAll(
        to outputPath: String,
        job: SliceJob,
        progress: @escaping @Sendable (Int, String) -> Void
    ) throws -> SliceResult {
        try lock.withLock {
            try Self.withProgressContext(progress) { callback, context in
                var report = orca_slice_report()
                defer { orca_slice_report_dispose(&report) }
                let result = outputPath.withCString { outputPointer in
                    orca_plater_slice_all_to_gcode(
                        handle, outputPointer, callback, context, job.handle, &report
                    )
                }
                try BridgeResult.consume(result, operation: "slice all plates")
                return try SliceResult(decoding: report, operation: "slice all plates")
            }
        }
    }

    public func sliceAll(
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
                    orca_plater_slice_all_to_gcode_with_presets(
                        platerHandle, presetHandle, outputPointer,
                        callback, context, job.handle, &report
                    )
                }
                try BridgeResult.consume(result, operation: "slice all plates with presets")
                return try SliceResult(decoding: report, operation: "slice all plates with presets")
            }
        }
    }

    /// Desktop Flatten-gizmo candidate planes for one instance (ABI v29):
    /// convex polygons on the object's hull in world/engine coordinates,
    /// with outward normals and areas. Read-only (no mutation).
    public struct FlattenPlane: Sendable, Equatable {
        public let vertices: [SIMD3<Float>]
        public let normal: SIMD3<Double>
        public let area: Float
    }

    public func flattenPlanes(
        objectID: ObjectID,
        instanceID: InstanceID
    ) throws -> [FlattenPlane] {
        try lock.withLock {
            var raw = orca_flatten_planes()
            try BridgeResult.consume(
                orca_plater_flatten_planes(
                    handle, objectID.rawValue, instanceID.rawValue, &raw),
                operation: "flatten planes"
            )
            defer { orca_flatten_planes_dispose(&raw) }
            guard raw.plane_count > 0, raw.planes != nil else {
                throw BridgeError.local(
                    .internalInvariant,
                    operation: "flatten planes",
                    diagnostic: "Bridge returned success with no planes"
                )
            }
            var planes: [FlattenPlane] = []
            planes.reserveCapacity(Int(raw.plane_count))
            for index in 0..<Int(raw.plane_count) {
                let plane = raw.planes[index]
                guard plane.vertex_count > 0, plane.vertices != nil else {
                    throw BridgeError.local(
                        .internalInvariant,
                        operation: "flatten planes",
                        diagnostic: "Bridge returned a plane without vertices"
                    )
                }
                var vertices: [SIMD3<Float>] = []
                vertices.reserveCapacity(Int(plane.vertex_count))
                for vertex in 0..<Int(plane.vertex_count) {
                    let point = plane.vertices[vertex]
                    vertices.append(SIMD3(point.0, point.1, point.2))
                }
                planes.append(FlattenPlane(
                    vertices: vertices,
                    normal: SIMD3(plane.normal.0, plane.normal.1, plane.normal.2),
                    area: plane.area
                ))
            }
            return planes
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

    // MARK: Measure (ABI v40) — desktop GLGizmoMeasure

    /// One picked surface feature, object space (mm).
    public struct SurfaceFeature: Sendable, Equatable {
        public enum Kind: UInt8, Sendable {
            case point = 0
            case edge = 1
            case circle = 2
            case plane = 3
        }

        public let kind: Kind
        public let pointA: SIMD3<Double>
        /// Edge second endpoint (other kinds: unused).
        public let pointB: SIMD3<Double>
        /// Circle centre->normal / plane normal.
        public let normal: SIMD3<Double>
        public let radius: Double
        public let area: Double
        public let planeIndex: Int32
    }

    /// Distance / per-axis delta / angle between two features.
    public struct FeatureMeasurement: Sendable {
        public let hasDistance: Bool
        public let from: SIMD3<Double>
        public let to: SIMD3<Double>
        public let distance: Double
        public let hasXYZ: Bool
        public let xyz: SIMD3<Double>
        public let hasAngle: Bool
        public let angleRadians: Double
    }

    /// Engine Measure::Measuring over one object's merged mesh. Triangle
    /// indices match the scene snapshot 1:1 (client picking feeds them
    /// straight through). Rebuild when the object's mesh revision changes;
    /// invalidate after document mutations that could replace the object.
    public final class MeasureContext: @unchecked Sendable {
        private var raw: OpaquePointer?
        private let lock = NSLock()

        fileprivate init(raw: OpaquePointer) {
            self.raw = raw
        }

        deinit {
            if let raw { orca_measure_dispose(raw) }
        }

        /// Desktop hover: the feature under a merged-mesh triangle point.
        public func pick(faceIndex: Int32, point: SIMD3<Double>) throws -> SurfaceFeature {
            try lock.withLock {
                guard let raw else {
                    throw BridgeError.local(
                        .invalidHandle, operation: "measure pick",
                        diagnostic: "measure context was disposed")
                }
                var feature = orca_surface_feature()
                try BridgeResult.consume(
                    orca_measure_pick(
                        raw, faceIndex, point.x, point.y, point.z, &feature),
                    operation: "measure pick"
                )
                return Self.decode(feature)
            }
        }

        /// Desktop update_measurement_result: relation between features.
        public func between(
            _ a: SurfaceFeature, _ b: SurfaceFeature
        ) throws -> FeatureMeasurement {
            try lock.withLock {
                guard let raw else {
                    throw BridgeError.local(
                        .invalidHandle, operation: "measure between",
                        diagnostic: "measure context was disposed")
                }
                var rawA = Self.encode(a)
                var rawB = Self.encode(b)
                var measurement = orca_measurement()
                try BridgeResult.consume(
                    orca_measure_between(raw, &rawA, &rawB, &measurement),
                    operation: "measure between"
                )
                return FeatureMeasurement(
                    hasDistance: measurement.has_distance != 0,
                    from: SIMD3(measurement.from.0, measurement.from.1,
                                measurement.from.2),
                    to: SIMD3(measurement.to.0, measurement.to.1,
                             measurement.to.2),
                    distance: measurement.distance,
                    hasXYZ: measurement.has_xyz != 0,
                    xyz: SIMD3(measurement.xyz.0, measurement.xyz.1,
                               measurement.xyz.2),
                    hasAngle: measurement.has_angle != 0,
                    angleRadians: measurement.angle_radians)
            }
        }

        private static func decode(_ raw: orca_surface_feature) -> SurfaceFeature {
            SurfaceFeature(
                kind: SurfaceFeature.Kind(rawValue: raw.type) ?? .point,
                pointA: SIMD3(raw.point_a.0, raw.point_a.1, raw.point_a.2),
                pointB: SIMD3(raw.point_b.0, raw.point_b.1, raw.point_b.2),
                normal: SIMD3(raw.normal.0, raw.normal.1, raw.normal.2),
                radius: raw.radius, area: raw.area, planeIndex: raw.plane_index)
        }

        private static func encode(_ feature: SurfaceFeature) -> orca_surface_feature {
            var raw = orca_surface_feature()
            raw.type = feature.kind.rawValue
            raw.point_a = (feature.pointA.x, feature.pointA.y, feature.pointA.z)
            raw.point_b = (feature.pointB.x, feature.pointB.y, feature.pointB.z)
            raw.normal = (feature.normal.x, feature.normal.y, feature.normal.z)
            raw.radius = feature.radius
            raw.area = feature.area
            raw.plane_index = feature.planeIndex
            return raw
        }
    }

    /// Builds the measure context over the object's merged mesh (CPU-heavy:
    /// plane segmentation). Engine mutex serialized; not a mutation.
    public func measureContext(objectID: ObjectID) throws -> MeasureContext {
        try lock.withLock {
            var raw: OpaquePointer?
            try BridgeResult.consume(
                orca_plater_object_measure(handle, objectID.rawValue, &raw),
                operation: "measure context"
            )
            guard let raw else {
                throw BridgeError.local(
                    .internalInvariant, operation: "measure context",
                    diagnostic: "Bridge returned no measure context")
            }
            return MeasureContext(raw: raw)
        }
    }

    // MARK: Exports (ABI v33)

    /// Desktop object-list "Export STL": one object's merged mesh (binary).
    public func exportSTL(objectID: ObjectID, to path: String) throws {
        try lock.withLock {
            let result = path.withCString { pointer in
                orca_plater_object_export_stl(handle, objectID.rawValue, pointer, 1)
            }
            try BridgeResult.consume(result, operation: "export STL")
        }
    }

    /// Desktop "Export generic 3MF": geometry-only interchange file.
    public func export3mf(to path: String) throws {
        try lock.withLock {
            let result = path.withCString { pointer in
                orca_project_export_3mf(handle, pointer)
            }
            try BridgeResult.consume(result, operation: "export generic 3MF")
        }
    }

    /// Desktop "Export sliced 3MF" (.gcode.3mf): slices every non-empty
    /// plate and embeds each plate's G-code (the USB-printer file). Blocking;
    /// progress scales across plates like slice-all.
    public func exportGcode3mf(
        to path: String,
        presets: EnginePresets,
        job: SliceJob,
        progress: @escaping @Sendable (Int, String) -> Void
    ) throws -> SliceResult {
        try Self.withLockedHandles(plater: self, presets: presets) { platerHandle, presetHandle in
            try Self.withProgressContext(progress) { callback, context in
                var report = orca_slice_report()
                defer { orca_slice_report_dispose(&report) }
                let result = path.withCString { outputPointer in
                    orca_plater_export_gcode_3mf(
                        platerHandle, presetHandle, outputPointer,
                        callback, context, job.handle, &report
                    )
                }
                try BridgeResult.consume(result, operation: "export sliced 3MF")
                return try SliceResult(decoding: report, operation: "export sliced 3MF")
            }
        }
    }

    /// Desktop "Export all objects as one STL" (ABI v40): every object's
    /// mesh through its first instance. "as STLs" loops exportSTL.
    public func exportAllSTL(to path: String) throws {
        try lock.withLock {
            let result = path.withCString { pointer in
                orca_plater_export_stl_all(handle, pointer, 1)
            }
            try BridgeResult.consume(result, operation: "export all STL")
        }
    }

    /// Desktop "Export plate sliced file": the sliced-3MF export restricted
    /// to ONE plate (ABI v40). Blocking; progress as exportGcode3mf.
    public func exportGcode3mfPlate(
        plateIndex: Int,
        to path: String,
        presets: EnginePresets,
        job: SliceJob,
        progress: @escaping @Sendable (Int, String) -> Void
    ) throws -> SliceResult {
        try Self.withLockedHandles(plater: self, presets: presets) { platerHandle, presetHandle in
            try Self.withProgressContext(progress) { callback, context in
                var report = orca_slice_report()
                defer { orca_slice_report_dispose(&report) }
                let result = path.withCString { outputPointer in
                    orca_plater_export_gcode_3mf_plate(
                        platerHandle, presetHandle, Int32(plateIndex),
                        outputPointer, callback, context, job.handle, &report
                    )
                }
                try BridgeResult.consume(result, operation: "export plate sliced 3MF")
                return try SliceResult(decoding: report, operation: "export plate sliced 3MF")
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
        return try Self.decodeSnapshot(rawSnapshot)
    }

    /// Decodes one raw ABI snapshot (owned by the caller, disposed by the
    /// caller). Validates every value BEFORE constructing Swift types.
    private static func decodeSnapshot(_ rawSnapshot: orca_scene_snapshot) throws -> SceneSnapshot {
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
                            mirrored: rawInstance.mirrored != 0,
                            printable: rawInstance.printable != 0,
                            plate: Int(rawInstance.plate)
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
                    overrideCount: Int(rawObject.override_count),
                    extruder: Int(rawObject.extruder)
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
        var plates: [ScenePlate] = []
        let plateCount = Int(rawSnapshot.plate_count)
        if plateCount > 0 {
            guard let platePointer = rawSnapshot.plates else {
                throw Self.invariant(
                    operation: "read scene snapshot",
                    "Bridge returned plates without storage"
                )
            }
            plates.reserveCapacity(plateCount)
            for plateIndex in 0..<plateCount {
                let rawPlate = platePointer[plateIndex]
                let plateID = try Self.plateID(
                    rawPlate.id,
                    operation: "read scene snapshot"
                )
                guard rawPlate.index == Int32(plateIndex) else {
                    throw Self.invariant(
                        operation: "read scene snapshot",
                        "Plate \(plateID) has a mismatched index \(rawPlate.index)"
                    )
                }
                plates.append(ScenePlate(
                    id: plateID,
                    index: plateIndex,
                    name: try Self.borrowedString(
                        rawPlate.name,
                        operation: "read name for plate \(plateID)"
                    ),
                    locked: rawPlate.locked != 0,
                    origin: SIMD3(
                        rawPlate.origin.0, rawPlate.origin.1, rawPlate.origin.2
                    ),
                    size: SIMD3(
                        rawPlate.size.0, rawPlate.size.1, rawPlate.size.2
                    ),
                    objectCount: Int(rawPlate.object_count)
                ))
            }
        }
        guard plates.isEmpty == false else {
            throw Self.invariant(
                operation: "read scene snapshot",
                "Bridge returned a document without plates"
            )
        }
        return SceneSnapshot(
            documentID: DocumentID(rawValue: rawSnapshot.document_id),
            revision: DocumentRevision(rawValue: rawSnapshot.revision),
            objects: objects,
            plates: plates,
            currentPlate: Int(rawSnapshot.current_plate),
            history: history
        )
    }

    private static func plateID(
        _ raw: UInt64, operation: String
    ) throws -> PlateID {
        guard raw != 0 else {
            throw invariant(operation: operation, "Bridge returned plate id 0")
        }
        return PlateID(rawValue: raw)
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
                overrideCount: Int(raw.override_count),
                mergedTriangleStart: raw.merged_triangle_start,
                mergedTriangleCount: raw.merged_triangle_count
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
