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
        guard let selection,
              let authoritative = scene?.instance(
                  objectID: selection.objectID,
                  instanceID: selection.instanceID
              )?.transform else { return }
        let transform = previewTransform ?? authoritative
        _ = await applyMutation(
            .setTransform(
                objectID: selection.objectID,
                instanceID: selection.instanceID,
                transform: transform
            ),
            operation: "transform"
        )
    }

    func rotateSelected(by degrees: Double) async {
        guard !isBusy,
              let selection,
              let authoritative = scene?.instance(
                  objectID: selection.objectID,
                  instanceID: selection.instanceID
              )?.transform else { return }
        var transform = previewTransform ?? authoritative
        transform.rotationZ += degrees * .pi / 180
        previewTransform = transform
        presentationRevision += 1
        await commitSelectedTransform()
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
