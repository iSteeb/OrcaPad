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
    /// Live gesture preview of the selected instance (engine-frame matrix).
    private(set) var previewMatrix: simd_float4x4?
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
            let sandboxURL = try EnginePaths.copyImportIntoSandbox(source, kind: "model")
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
            previewMatrix = nil
            presentationRevision += 1
            return
        }
        selection = InstanceSelection(
            objectID: objectID,
            instanceID: instanceID
        )
        previewMatrix = nil
        presentationRevision += 1
    }

    // MARK: Manipulation (gesture previews on the engine matrix → one
    // engine mutation on commit; the engine rests the instance on the bed)

    /// Snap step for gesture rotation (desktop rotate gizmo snaps too).
    static let rotationSnapDegrees = 5.0

    private enum PendingManipulation {
        case move
        case rotate(EngineAxis, Double)
        case scale(Double)
    }

    private var pending: PendingManipulation?
    private var manipulationBase: simd_float4x4?

    private var selectedInstance: SceneInstance? {
        guard let selection else { return nil }
        return scene?.instance(objectID: selection.objectID, instanceID: selection.instanceID)
    }

    var selectedAuthoritativeTransform: InstanceTransform? { selectedInstance?.transform }

    private var selectedAuthoritativeMatrix: simd_float4x4? {
        selectedInstance.map { EngineMatrix.float($0.matrix) }
    }

    /// Transform shown by the panels: always the engine's authoritative value
    /// (gesture previews are matrix-only and commit as one mutation).
    var selectedDisplayTransform: InstanceTransform? { selectedAuthoritativeTransform }

    /// Local (object-axis) size: snapshot bounds × per-axis scale.
    var selectedSize: SIMD3<Float>? {
        guard let selection,
              let object = scene?.object(id: selection.objectID),
              let transform = selectedAuthoritativeTransform else { return nil }
        return object.mesh.bounds.size * SIMD3<Float>(transform.scale)
    }

    func moveSelected(by delta: SIMD2<Float>) {
        guard !isBusy, let current = previewMatrix ?? selectedAuthoritativeMatrix else { return }
        previewMatrix = EngineMatrix.translation(SIMD3(delta.x, delta.y, 0)) * current
        pending = .move
        presentationRevision += 1
    }

    func beginManipulation() {
        guard !isBusy else { return }
        manipulationBase = previewMatrix ?? selectedAuthoritativeMatrix
    }

    /// Live rotation preview about a world axis through the object center,
    /// snapped to `rotationSnapDegrees`.
    func previewRotation(axis: EngineAxis, deltaRadians: Double) {
        guard !isBusy, let base = manipulationBase else { return }
        let step = Self.rotationSnapDegrees * .pi / 180
        let snapped = (deltaRadians / step).rounded() * step
        let origin = EngineMatrix.origin(base)
        previewMatrix = EngineMatrix.translation(origin)
            * EngineMatrix.rotation(axis, radians: Float(snapped))
            * EngineMatrix.translation(-origin)
            * base
        pending = .rotate(axis, snapped)
        presentationRevision += 1
    }

    /// Live uniform-scale preview (local axes, about the object center).
    func previewScale(factor: Double) {
        guard !isBusy, let base = manipulationBase, factor.isFinite, factor > 0 else { return }
        let clamped = min(max(factor, 0.01), 100)
        previewMatrix = base * EngineMatrix.scale(SIMD3(repeating: Float(clamped)))
        pending = .scale(clamped)
        presentationRevision += 1
    }

    func commitSelectedTransform() async {
        let gesture = pending
        let previewed = previewMatrix
        pending = nil
        manipulationBase = nil
        guard let selection,
              let authoritative = selectedAuthoritativeTransform,
              let authoritativeMatrix = selectedAuthoritativeMatrix,
              let gesture else {
            clearPreview()
            return
        }
        switch gesture {
        case .move:
            guard let previewed else { clearPreview(); return }
            let delta = EngineMatrix.origin(previewed) - EngineMatrix.origin(authoritativeMatrix)
            var moved = authoritative
            moved.offsetX += Double(delta.x)
            moved.offsetY += Double(delta.y)
            await setSelectedTransform(moved)
        case .rotate(let axis, let radians):
            guard radians != 0 else { clearPreview(); return }
            _ = await applyMutation(
                .rotate(objectID: selection.objectID, instanceID: selection.instanceID,
                        axis: axis, radians: radians),
                operation: "rotate"
            )
        case .scale(let factor):
            var scaled = authoritative
            scaled.scaleX *= factor
            scaled.scaleY *= factor
            scaled.scaleZ *= factor
            await setSelectedTransform(scaled)
        }
    }

    /// Absolute transform (numeric panels). The engine rests it on the bed.
    func setSelectedTransform(_ transform: InstanceTransform) async {
        guard let selection else { return }
        guard transform.isValid else {
            status.report(.document, failure: .invariant(
                operation: "set transform",
                diagnostic: "transform contains a non-finite value or non-positive scale"
            ))
            return
        }
        _ = await applyMutation(
            .setTransform(objectID: selection.objectID, instanceID: selection.instanceID,
                          transform: transform),
            operation: "transform"
        )
    }

    /// Incremental world-axis rotation (rotate panel ± steps): the engine
    /// composes it, so repeated steps wrap continuously through 360°.
    func rotateSelected(axis: EngineAxis, degrees: Double) async {
        guard let selection else { return }
        _ = await applyMutation(
            .rotate(objectID: selection.objectID, instanceID: selection.instanceID,
                    axis: axis, radians: degrees * .pi / 180),
            operation: "rotate"
        )
    }

    func resetRotation() async {
        guard var transform = selectedAuthoritativeTransform else { return }
        transform.rotationX = 0
        transform.rotationY = 0
        transform.rotationZ = 0
        await setSelectedTransform(transform)
    }

    private func clearPreview() {
        previewMatrix = nil
        presentationRevision += 1
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
            previewMatrix = nil
            presentationRevision += 1
            status.report(.document, failure: failure)
            return nil
        }
    }

    private func install(_ authoritativeScene: SceneSnapshot) {
        if let current = scene,
           current.documentID == authoritativeScene.documentID,
           authoritativeScene.revision < current.revision {
            previewMatrix = nil
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
        previewMatrix = nil
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
