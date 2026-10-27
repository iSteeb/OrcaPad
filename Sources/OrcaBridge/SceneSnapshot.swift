// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

import Foundation
import simd

public struct DocumentID: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        precondition(rawValue != 0, "DocumentID must be nonzero")
        self.rawValue = rawValue
    }

    public var description: String { String(rawValue) }
}

public struct ObjectID: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        precondition(rawValue != 0, "ObjectID must be nonzero")
        self.rawValue = rawValue
    }

    public var description: String { String(rawValue) }
}

public struct InstanceID: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        precondition(rawValue != 0, "InstanceID must be nonzero")
        self.rawValue = rawValue
    }

    public var description: String { String(rawValue) }
}

public struct PlateID: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        precondition(rawValue != 0, "PlateID must be nonzero")
        self.rawValue = rawValue
    }

    public var description: String { String(rawValue) }
}

public struct VolumeID: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        precondition(rawValue != 0, "VolumeID must be nonzero")
        self.rawValue = rawValue
    }

    public var description: String { String(rawValue) }
}

public struct DocumentRevision: RawRepresentable, Hashable, Comparable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// World axes for incremental engine rotations (desktop rotate gizmo).
public enum EngineAxis: Int32, CaseIterable, Sendable {
    case x = 0
    case y = 1
    case z = 2
}

/// Desktop unit conversions (ModelObject::convert_units).
public enum UnitConversion: Int32, CaseIterable, Sendable {
    case fromInch = 0
    case toInch = 1
    case fromMeter = 2
    case toMeter = 3

    public var label: String {
        switch self {
        case .fromInch: return "Convert from inches"
        case .toInch: return "Revert conversion from inches"
        case .fromMeter: return "Convert from metres"
        case .toMeter: return "Revert conversion from metres"
        }
    }
}

/// Built-in primitive shapes (desktop Add Primitive).
public enum PrimitiveShape: Int32, CaseIterable, Sendable {
    case cube = 0
    case cylinder = 1
    case sphere = 2
    case cone = 3
    case disc = 4
    case torus = 5
    /// Modifier-sized slab over an instance footprint (volumes only).
    case slab = 6

    public var label: String {
        switch self {
        case .cube: return "Cube"
        case .cylinder: return "Cylinder"
        case .sphere: return "Sphere"
        case .cone: return "Cone"
        case .disc: return "Disc"
        case .torus: return "Torus"
        case .slab: return "Slab"
        }
    }

    /// Valid as a standalone object (desktop add-shape menu).
    public var isObjectShape: Bool { self != .slab }
}

/// Canonical engine-space transform: z-up, millimetres, radians. Rotation is
/// the engine's own Euler decomposition; scale is per local axis (> 0).
public struct InstanceTransform: Equatable, Sendable {
    public var offsetX: Double
    public var offsetY: Double
    public var offsetZ: Double
    public var rotationX: Double
    public var rotationY: Double
    public var rotationZ: Double
    public var scaleX: Double
    public var scaleY: Double
    public var scaleZ: Double

    public init(
        offsetX: Double, offsetY: Double, offsetZ: Double,
        rotationX: Double, rotationY: Double, rotationZ: Double,
        scaleX: Double, scaleY: Double, scaleZ: Double
    ) {
        precondition(
            [offsetX, offsetY, offsetZ, rotationX, rotationY, rotationZ,
             scaleX, scaleY, scaleZ].allSatisfy(\.isFinite) &&
                scaleX > 0 && scaleY > 0 && scaleZ > 0,
            "InstanceTransform must contain finite values and positive scales"
        )
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.offsetZ = offsetZ
        self.rotationX = rotationX
        self.rotationY = rotationY
        self.rotationZ = rotationZ
        self.scaleX = scaleX
        self.scaleY = scaleY
        self.scaleZ = scaleZ
    }

    public var rotation: SIMD3<Double> { SIMD3(rotationX, rotationY, rotationZ) }
    public var scale: SIMD3<Double> { SIMD3(scaleX, scaleY, scaleZ) }
    public var isUniformlyScaled: Bool {
        abs(scaleX - scaleY) < 1e-9 && abs(scaleX - scaleZ) < 1e-9
    }

    public var isValid: Bool {
        [offsetX, offsetY, offsetZ, rotationX, rotationY, rotationZ,
         scaleX, scaleY, scaleZ].allSatisfy(\.isFinite) &&
            scaleX > 0 && scaleY > 0 && scaleZ > 0
    }
}

public struct EngineBounds: Equatable, Sendable {
    public let minimum: SIMD3<Float>
    public let maximum: SIMD3<Float>

    public init(minimum: SIMD3<Float>, maximum: SIMD3<Float>) {
        self.minimum = minimum
        self.maximum = maximum
    }

    public var size: SIMD3<Float> { maximum - minimum }
}

/// Owned, immutable geometry copied from the engine at a document revision.
public struct SceneMesh: Sendable {
    public let revision: UInt64
    public let positions: [SIMD3<Float>]
    public let indices: [UInt32]
    public let bounds: EngineBounds
    public let pivot: SIMD3<Float>

    public init(
        revision: UInt64,
        positions: [SIMD3<Float>],
        indices: [UInt32],
        bounds: EngineBounds,
        pivot: SIMD3<Float>
    ) {
        self.revision = revision
        self.positions = positions
        self.indices = indices
        self.bounds = bounds
        self.pivot = pivot
    }
}

public struct SceneInstance: Identifiable, Sendable {
    public let id: InstanceID
    public let transform: InstanceTransform
    /// The engine's instance matrix (ModelInstance::get_matrix()); render and
    /// preview from this — never re-derive it from the Euler angles.
    public let matrix: simd_double4x4
    /// Left-handed matrix (mirrored on an odd number of axes): renderers flip
    /// winding/normals; the transform fields stay absolute.
    public let mirrored: Bool
    /// False when excluded from slicing (desktop printable toggle).
    public let printable: Bool
    /// False = keep this instance floating (desktop ModelInstance::auto_drop).
    public let autoDrop: Bool
    /// Index into the snapshot's plates (-1 = on no plate, not sliced).
    public let plate: Int

    public init(
        id: InstanceID, transform: InstanceTransform, matrix: simd_double4x4,
        mirrored: Bool, printable: Bool, autoDrop: Bool = true, plate: Int = 0
    ) {
        self.id = id
        self.transform = transform
        self.matrix = matrix
        self.mirrored = mirrored
        self.printable = printable
        self.autoDrop = autoDrop
        self.plate = plate
    }
}

/// One plate of the document (desktop PartPlate): grid box, name, lock and
/// how many objects sit on it.
public struct ScenePlate: Identifiable, Sendable {
    public let id: PlateID
    public let index: Int
    public let name: String
    public let locked: Bool
    /// Engine coords: min corner + width/depth/height of the plate box.
    public let origin: SIMD3<Float>
    public let size: SIMD3<Float>
    public let objectCount: Int

    public init(
        id: PlateID, index: Int, name: String, locked: Bool,
        origin: SIMD3<Float>, size: SIMD3<Float>, objectCount: Int
    ) {
        self.id = id
        self.index = index
        self.name = name
        self.locked = locked
        self.origin = origin
        self.size = size
        self.objectCount = objectCount
    }

    /// Center of the plate bed in engine X/Y (import target).
    public var center: SIMD2<Float> {
        SIMD2(origin.x + size.x / 2, origin.y + size.y / 2)
    }
}

public struct SceneObject: Identifiable, Sendable {
    public let id: ObjectID
    public let name: String
    public let mesh: SceneMesh
    public let instances: [SceneInstance]
    /// Object volumes, document order (desktop object list).
    public let volumes: [SceneVolume]
    /// Per-object setting overrides (desktop object-list settings badge).
    public let overrideCount: Int
    /// Object-level extruder assignment (1-based; 0 = default/first).
    public let extruder: Int

    public init(
        id: ObjectID,
        name: String,
        mesh: SceneMesh,
        instances: [SceneInstance],
        volumes: [SceneVolume],
        overrideCount: Int,
        extruder: Int = 0
    ) {
        self.id = id
        self.name = name
        self.mesh = mesh
        self.instances = instances
        self.volumes = volumes
        self.overrideCount = overrideCount
        self.extruder = extruder
    }

    public var modelParts: [SceneVolume] {
        volumes.filter { $0.role == .part }
    }

    public var nonPartVolumes: [SceneVolume] {
        volumes.filter { $0.role != .part }
    }
}

/// Undo/redo availability at a revision (desktop Edit menu state).
public struct DocumentHistory: Equatable, Sendable {
    public let undoCount: Int
    public let redoCount: Int
    /// Label of the step Undo reverts ("" when there is none).
    public let undoLabel: String
    /// Label of the step Redo re-applies ("" when there is none).
    public let redoLabel: String

    public init(undoCount: Int, redoCount: Int, undoLabel: String, redoLabel: String) {
        self.undoCount = undoCount
        self.redoCount = redoCount
        self.undoLabel = undoLabel
        self.redoLabel = redoLabel
    }

    public var canUndo: Bool { undoCount > 0 }
    public var canRedo: Bool { redoCount > 0 }
}

/// Object volume roles (desktop ModelVolumeType / object list).
public enum VolumeRole: UInt8, Sendable, CaseIterable {
    case part = 0
    case negative = 1
    case modifier = 2
    case supportBlocker = 3
    case supportEnforcer = 4

    public var label: String {
        switch self {
        case .part: return "Part"
        case .negative: return "Negative volume"
        case .modifier: return "Modifier"
        case .supportBlocker: return "Support blocker"
        case .supportEnforcer: return "Support enforcer"
        }
    }
}

/// One volume of an object. Parts render through the object's merged mesh
/// (`mesh == nil`); other roles carry their own object-space mesh.
public struct SceneVolume: Identifiable, Sendable {
    public let id: VolumeID
    public let name: String
    public let role: VolumeRole
    /// Volume "extruder" option (0 = the object's).
    public let extruder: Int
    /// Own object-space mesh for non-part roles; nil for parts.
    public let mesh: SceneMesh?
    /// Per-volume setting overrides.
    public let overrideCount: Int
    /// Parts only (ABI v26): this volume's triangle range inside the
    /// object's merged mesh (`SceneObject.mesh`), for canvas part picking
    /// and highlight. 0/0 for other roles.
    public let mergedTriangleStart: UInt32
    public let mergedTriangleCount: UInt32

    public init(
        id: VolumeID, name: String, role: VolumeRole, extruder: Int, mesh: SceneMesh?,
        overrideCount: Int,
        mergedTriangleStart: UInt32 = 0, mergedTriangleCount: UInt32 = 0
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.extruder = extruder
        self.mesh = mesh
        self.overrideCount = overrideCount
        self.mergedTriangleStart = mergedTriangleStart
        self.mergedTriangleCount = mergedTriangleCount
    }
}

/// A coherent, immutable read of one authoritative C++ document revision.
public struct SceneSnapshot: Sendable {
    public let documentID: DocumentID
    public let revision: DocumentRevision
    public let objects: [SceneObject]
    /// Document plates, index order (>= 1).
    public let plates: [ScenePlate]
    /// Index of the selected plate (session state).
    public let currentPlate: Int
    public let history: DocumentHistory

    public init(
        documentID: DocumentID,
        revision: DocumentRevision,
        objects: [SceneObject],
        plates: [ScenePlate] = [],
        currentPlate: Int = 0,
        history: DocumentHistory
    ) {
        self.documentID = documentID
        self.revision = revision
        self.objects = objects
        self.plates = plates
        self.currentPlate = currentPlate
        self.history = history
    }

    public func object(id: ObjectID) -> SceneObject? {
        objects.first { $0.id == id }
    }

    public func instance(objectID: ObjectID, instanceID: InstanceID) -> SceneInstance? {
        object(id: objectID)?.instances.first { $0.id == instanceID }
    }

    public func plate(id: PlateID) -> ScenePlate? {
        plates.first { $0.id == id }
    }
}
