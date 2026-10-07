import Foundation
import Observation
import OrcaBridge
import simd

struct InstanceSelection: Equatable, Sendable {
    let objectID: ObjectID
    let instanceID: InstanceID
}

struct SliceInput: Sendable {
    let plater: EnginePlater
    let snapshot: SceneSnapshot
}

private struct DocumentBootstrap: Sendable {
    let plater: EnginePlater
    let snapshot: SceneSnapshot
}

private struct ImportCommit: Sendable {
    let mutation: EnginePlater.MutationResult
    let status: String
}

private struct MultiDeleteExecution: Sendable {
    let latestMutation: EnginePlater.MutationResult?
    let failure: AppFailure?
}

@MainActor
@Observable
final class DocumentStore {
    private let status: StatusCenter
    private var plater: EnginePlater?
    private(set) var scene: SceneSnapshot?
    private(set) var selection: InstanceSelection?
    private(set) var previewTransform: InstanceTransform?
    private(set) var presentationRevision: UInt64 = 0
    private(set) var frameRequest: UInt64 = 0
    private(set) var isMutating = false
    private(set) var isSlicing = false
    private(set) var isBootstrapping = false

    init(status: StatusCenter) {
        self.status = status
    }

    var isReady: Bool { plater != nil && scene != nil }
    var isBusy: Bool { isMutating || isSlicing }

    func bootstrap() async {
        guard !isReady, !isBootstrapping else { return }
        isBootstrapping = true
        status.report(.document, "engine: starting…")
        let result = await BackgroundWork.run(operation: "create document") {
            let plater = try EnginePlater()
            return DocumentBootstrap(
                plater: plater,
                snapshot: try plater.snapshot()
            )
        }
        isBootstrapping = false
        switch result {
        case .success(let bootstrap):
            plater = bootstrap.plater
            install(bootstrap.snapshot)
            status.report(.document, "engine: ready (import an STL)")
        case .failure(let failure):
            status.report(.document, failure: failure)
        }
    }

    func importModel(from source: URL, bedCenter: SIMD2<Double>) async {
        guard let plater, !isBusy else {
            status.report(.document, "import blocked: document is busy")
            return
        }
        isMutating = true
        let displayName = source.lastPathComponent
        status.report(.document, "\(displayName): loading…")
        let result = await BackgroundWork.run(operation: "import model") {
            let sandboxURL = try EnginePaths.copyImportIntoSandbox(source)
            let mutation = try plater.apply(
                .importModel(path: sandboxURL.path, bedCenter: bedCenter)
            )
            guard let objectID = mutation.createdObjectID,
                  let object = mutation.snapshot.object(id: objectID) else {
                throw AppFailure.invariant(
                    operation: "import model",
                    diagnostic: "created object is absent from its snapshot"
                )
            }
            let dimensions = object.mesh.bounds.size
            let status = "\(displayName) · \(object.mesh.indices.count / 3) tris · " +
                String(
                    format: "%.0f×%.0f×%.0f mm",
                    dimensions.x,
                    dimensions.y,
                    dimensions.z
                )
            return ImportCommit(mutation: mutation, status: status)
        }
        isMutating = false
        switch result {
        case .success(let commit):
            install(commit.mutation.snapshot)
            frameRequest += 1
            status.report(.document, commit.status)
        case .failure(let failure):
            status.report(.document, failure: failure)
        }
    }

    func addInstance(to objectID: ObjectID) async {
        guard let mutation = await applyMutation(
            .addInstance(objectID: objectID),
            operation: "add instance"
        ) else { return }
        if let instanceID = mutation.createdInstanceID {
            selection = InstanceSelection(
                objectID: objectID,
                instanceID: instanceID
            )
        }
    }

    func deleteInstance(_ instanceID: InstanceID, of objectID: ObjectID) async {
        _ = await applyMutation(
            .deleteInstance(objectID: objectID, instanceID: instanceID),
            operation: "delete instance"
        )
    }

    func deleteObject(_ objectID: ObjectID) async {
        _ = await applyMutation(
            .deleteObject(objectID),
            operation: "delete object"
        )
    }

    func deleteObjects(_ objectIDs: [ObjectID]) async {
        guard let plater, !isBusy else {
            status.report(.document, "delete objects blocked: document is busy")
            return
        }
        guard !objectIDs.isEmpty else { return }
        isMutating = true
        let result = await BackgroundWork.run(operation: "delete objects") {
            var latest: EnginePlater.MutationResult?
            for objectID in objectIDs {
                do {
                    latest = try plater.apply(.deleteObject(objectID))
                } catch {
                    return MultiDeleteExecution(
                        latestMutation: latest,
                        failure: AppFailure.wrap(
                            error,
                            operation: "delete object \(objectID)"
                        )
                    )
                }
            }
            return MultiDeleteExecution(
                latestMutation: latest,
                failure: nil
            )
        }
        isMutating = false
        switch result {
        case .success(let execution):
            if let mutation = execution.latestMutation {
                install(mutation.snapshot)
            }
            if let failure = execution.failure {
                status.report(.document, failure: failure)
            }
        case .failure(let failure):
            status.report(.document, failure: failure)
        }
    }

    func select(objectID: ObjectID?, instanceID: InstanceID?) {
        guard let objectID, let instanceID,
              scene?.instance(
                  objectID: objectID,
                  instanceID: instanceID
              ) != nil else {
            selection = nil
            previewTransform = nil
            presentationRevision += 1
            return
        }
        selection = InstanceSelection(
            objectID: objectID,
            instanceID: instanceID
        )
        previewTransform = nil
        presentationRevision += 1
    }

    func moveSelected(by delta: SIMD2<Float>) {
        guard !isBusy,
              let selection,
              let authoritative = scene?.instance(
                  objectID: selection.objectID,
                  instanceID: selection.instanceID
              )?.transform else { return }
        var transform = previewTransform ?? authoritative
        transform.offsetX += Double(delta.x)
        transform.offsetY += Double(delta.y)
        previewTransform = transform
        presentationRevision += 1
    }

    func commitSelectedTransform() async {
        manipulationBase = nil
        guard let selection,
              let authoritative = selectedAuthoritativeTransform else { return }
        let transform = onBed(previewTransform ?? authoritative)
        guard transform != authoritative else {
            previewTransform = nil
            presentationRevision += 1
            return
        }
        _ = await applyMutation(
            .setTransform(
                objectID: selection.objectID,
                instanceID: selection.instanceID,
                transform: transform
            ),
            operation: "transform"
        )
    }

    // MARK: Gizmo manipulation (rotate / scale relative to a gesture base)

    /// Snap step for gesture rotation (desktop rotate gizmo snaps too).
    static let rotationSnapDegrees = 5.0

    private var manipulationBase: InstanceTransform?

    var selectedAuthoritativeTransform: InstanceTransform? {
        guard let selection else { return nil }
        return scene?.instance(
            objectID: selection.objectID,
            instanceID: selection.instanceID
        )?.transform
    }

    /// The transform the UI should display: the live preview while a gesture
    /// runs, otherwise the authoritative engine value.
    var selectedDisplayTransform: InstanceTransform? {
        previewTransform ?? selectedAuthoritativeTransform
    }

    /// Engine-space size of the selected instance (snapshot bounds × scale).
    var selectedSize: SIMD3<Float>? {
        guard let selection,
              let object = scene?.object(id: selection.objectID),
              let transform = selectedDisplayTransform else { return nil }
        return object.mesh.bounds.size * Float(transform.scale)
    }

    func beginManipulation() {
        guard !isBusy else { return }
        manipulationBase = selectedDisplayTransform
    }

    /// Live rotation preview: base rotation + gesture delta, snapped.
    func previewRotation(deltaRadians: Double) {
        guard !isBusy, let base = manipulationBase else { return }
        let step = Self.rotationSnapDegrees * .pi / 180
        var transform = base
        transform.rotationZ = Self.normalizedAngle(
            base.rotationZ + (deltaRadians / step).rounded() * step
        )
        previewTransform = transform
        presentationRevision += 1
    }

    /// Live uniform-scale preview: base scale × gesture factor, kept on bed.
    func previewScale(factor: Double) {
        guard !isBusy, let base = manipulationBase, factor.isFinite, factor > 0 else { return }
        var transform = base
        transform.scale = min(max(base.scale * factor, 0.01), 100)
        previewTransform = onBed(transform)
        presentationRevision += 1
    }

    /// Numeric entry (Object manipulation panel): commits immediately.
    func setSelectedTransform(_ transform: InstanceTransform) async {
        guard !isBusy else {
            status.report(.document, "transform blocked: document is busy")
            return
        }
        var normalized = transform
        normalized.rotationZ = Self.normalizedAngle(transform.rotationZ)
        previewTransform = onBed(normalized)
        presentationRevision += 1
        await commitSelectedTransform()
    }

    /// Keeps the instance resting on the bed: meshes are centered on import
    /// and only z-rotation is supported, so the lowest point is the snapshot
    /// bound's min z scaled — engine truth, no client geometry.
    private func onBed(_ transform: InstanceTransform) -> InstanceTransform {
        guard let selection,
              let object = scene?.object(id: selection.objectID) else { return transform }
        var lifted = transform
        lifted.offsetZ = -Double(object.mesh.bounds.minimum.z) * transform.scale
        return lifted
    }

    private static func normalizedAngle(_ radians: Double) -> Double {
        atan2(sin(radians), cos(radians))
    }

    func beginSlicing() -> SliceInput? {
        guard let plater, let scene,
              !scene.objects.isEmpty,
              !isBusy else { return nil }
        isSlicing = true
        return SliceInput(plater: plater, snapshot: scene)
    }

    func finishSlicing() {
        precondition(isSlicing, "finishSlicing without an active slice")
        isSlicing = false
    }

    private func applyMutation(
        _ mutation: EnginePlater.Mutation,
        operation: String
    ) async -> EnginePlater.MutationResult? {
        guard let plater, !isBusy else {
            status.report(.document, "\(operation) blocked: document is busy")
            return nil
        }
        isMutating = true
        let result = await BackgroundWork.run(operation: operation) {
            try plater.apply(mutation)
        }
        isMutating = false
        switch result {
        case .success(let mutation):
            install(mutation.snapshot)
            return mutation
        case .failure(let failure):
            previewTransform = nil
            presentationRevision += 1
            status.report(.document, failure: failure)
            return nil
        }
    }

    private func install(_ authoritativeScene: SceneSnapshot) {
        if let current = scene,
           current.documentID == authoritativeScene.documentID,
           authoritativeScene.revision < current.revision {
            previewTransform = nil
            presentationRevision += 1
            status.report(
                .document,
                failure: .invariant(
                    operation: "install scene snapshot",
                    diagnostic: "stale revision \(authoritativeScene.revision.rawValue) < \(current.revision.rawValue)"
                )
            )
            return
        }
        scene = authoritativeScene
        previewTransform = nil
        if let selection,
           authoritativeScene.instance(
               objectID: selection.objectID,
               instanceID: selection.instanceID
           ) == nil {
            self.selection = nil
        }
        presentationRevision += 1
    }
}
