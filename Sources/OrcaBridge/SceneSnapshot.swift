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

    public init(id: InstanceID, transform: InstanceTransform, matrix: simd_double4x4) {
        self.id = id
        self.transform = transform
        self.matrix = matrix
    }
}

public struct SceneObject: Identifiable, Sendable {
    public let id: ObjectID
    public let name: String
    public let mesh: SceneMesh
    public let instances: [SceneInstance]

    public init(
        id: ObjectID,
        name: String,
        mesh: SceneMesh,
        instances: [SceneInstance]
    ) {
        self.id = id
        self.name = name
        self.mesh = mesh
        self.instances = instances
    }
}

/// A coherent, immutable read of one authoritative C++ document revision.
public struct SceneSnapshot: Sendable {
    public let documentID: DocumentID
    public let revision: DocumentRevision
    public let objects: [SceneObject]

    public init(
        documentID: DocumentID,
        revision: DocumentRevision,
        objects: [SceneObject]
    ) {
        self.documentID = documentID
        self.revision = revision
        self.objects = objects
    }

    public func object(id: ObjectID) -> SceneObject? {
        objects.first { $0.id == id }
    }

    public func instance(objectID: ObjectID, instanceID: InstanceID) -> SceneInstance? {
        object(id: objectID)?.instances.first { $0.id == instanceID }
    }
}
