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

/// Canonical engine-space transform: z-up, millimetres, radians.
public struct InstanceTransform: Equatable, Sendable {
    public var offsetX: Double
    public var offsetY: Double
    public var offsetZ: Double
    public var rotationZ: Double
    public var scale: Double

    public init(
        offsetX: Double,
        offsetY: Double,
        offsetZ: Double,
        rotationZ: Double,
        scale: Double
    ) {
        precondition(
            offsetX.isFinite && offsetY.isFinite && offsetZ.isFinite &&
                rotationZ.isFinite && scale.isFinite && scale > 0,
            "InstanceTransform must contain finite values and positive scale"
        )
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.offsetZ = offsetZ
        self.rotationZ = rotationZ
        self.scale = scale
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

    public init(id: InstanceID, transform: InstanceTransform) {
        self.id = id
        self.transform = transform
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
