// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

import Foundation
import Observation
import OrcaBridge
import simd

struct InstanceSelection: Equatable, Sendable {
    let objectID: ObjectID
    let instanceID: InstanceID
    /// The selected VOLUME inside the object (desktop part selection), nil
    /// for a whole-object/instance selection.
    var volumeID: VolumeID?

    init(objectID: ObjectID, instanceID: InstanceID, volumeID: VolumeID? = nil) {
        self.objectID = objectID
        self.instanceID = instanceID
        self.volumeID = volumeID
    }
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

@MainActor
@Observable
final class DocumentStore {
    private let status: StatusCenter
    private var plater: EnginePlater?
    private(set) var scene: SceneSnapshot?
    /// Primary selection (panels and single-object actions).
    private(set) var selection: InstanceSelection?
    /// Multi-selection members (desktop ctrl+click), primary included.
    private(set) var multiSelection: [InstanceSelection] = []
    /// Live gesture previews (engine-frame matrices), one per instance.
    private(set) var previewMatrices: [InstanceID: simd_float4x4] = [:]

    /// Every selected instance (multi when active, else the primary).
    var selectedGroup: [InstanceSelection] {
        multiSelection.isEmpty ? selection.map { [$0] } ?? [] : multiSelection
    }

    var hasMultiSelection: Bool { multiSelection.count > 1 }
    private(set) var presentationRevision: UInt64 = 0
    private(set) var frameRequest: UInt64 = 0
    private(set) var cameraRequestID: UInt64 = 0
    private(set) var cameraPreset: CameraViewPreset = .defaultValue
    private(set) var isMutating = false
    private(set) var isSlicing = false
    private(set) var isBootstrapping = false

    init(status: StatusCenter) {
        self.status = status
    }

    var isReady: Bool { plater != nil && scene != nil }
    var isBusy: Bool { isMutating || isSlicing }
    /// Undo/redo state of the authoritative document.
    var history: DocumentHistory? { scene?.history }

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
            let objectNote = mutation.createdObjectCount > 1
                ? "\(mutation.createdObjectCount) objects · " : ""
            let status = "\(displayName) · \(objectNote)\(object.mesh.indices.count / 3) tris · " +
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

    // MARK: Projects (desktop File ▸ Open / Save project)

    /// Last saved project file (shareable).
    private(set) var lastSavedProject: URL?

    /// Replaces the document and the preset session with a 3MF project.
    /// Returns whether the engine committed the open (the caller then
    /// refreshes the preset store from the engine).
    func openProject(from source: URL, presets: EnginePresets) async -> Bool {
        guard let plater, !isBusy else {
            status.report(.document, "open project blocked: document is busy")
            return false
        }
        isMutating = true
        let displayName = source.lastPathComponent
        status.report(.document, "\(displayName): opening project…")
        let result = await BackgroundWork.run(operation: "open project") {
            let sandboxURL = try EnginePaths.copyImportIntoSandbox(source, kind: "project")
            return try plater.openProject(path: sandboxURL.path, presets: presets)
        }
        isMutating = false
        switch result {
        case .success(let opened):
            selection = nil
            install(opened.snapshot)
            frameRequest += 1
            let settings = opened.configApplied ? "project settings applied" : "geometry only (no settings)"
            status.report(.document, "\(displayName): \(opened.objectCount) object(s) · \(settings)")
            return true
        case .failure(let failure):
            status.report(.document, failure: failure)
            return false
        }
    }

    func saveProject(named name: String, presets: EnginePresets, bed: EngineBed) async {
        guard let plater, let scene, !isBusy else {
            status.report(.document, "save project blocked: document is busy")
            return
        }
        // Desktop stores a plate thumbnail in every project (Metadata/plate_1.png).
        let thumbnail: (size: Int, rgba: [UInt8])
        do {
            thumbnail = (ThumbnailService.size, try ThumbnailService.render(scene: scene, bed: bed))
        } catch {
            status.report(.document, failure: AppFailure.wrap(error, operation: "render project thumbnail"))
            return
        }
        isMutating = true
        let result = await BackgroundWork.run(operation: "save project") {
            let url = try EnginePaths.projectURL(name: name)
            try plater.saveProject(path: url.path, presets: presets, thumbnail: thumbnail)
            return url
        }
        isMutating = false
        switch result {
        case .success(let url):
            lastSavedProject = url
            status.report(.document, "project saved: \(url.lastPathComponent)")
        case .failure(let failure):
            status.report(.document, failure: failure)
        }
    }

    // MARK: Exports (ABI v33: STL / generic 3MF / sliced .gcode.3mf)

    /// The latest export (Share menu target, like `lastSavedProject`).
    private(set) var lastExport: URL?

    /// Desktop object-list "Export STL": one object's merged mesh.
    func exportSTL(objectID: ObjectID, objectName: String) async {
        guard let plater, let object = scene?.object(id: objectID), !isBusy else {
            status.report(.document, "export blocked: document is busy or object missing")
            return
        }
        isMutating = true
        let result = await BackgroundWork.run(operation: "export STL") {
            let url = try EnginePaths.exportURL(name: object.name, pathExtension: "stl")
            try plater.exportSTL(objectID: objectID, to: url.path)
            return url
        }
        isMutating = false
        switch result {
        case .success(let url):
            lastExport = url
            status.report(.document, "STL exported: \(url.lastPathComponent)")
        case .failure(let failure):
            status.report(.document, failure: failure)
        }
    }

    /// Desktop "Export generic 3MF": geometry-only interchange file.
    func export3mf(projectName: String) async {
        guard let plater, !isBusy else {
            status.report(.document, "export blocked: document is busy")
            return
        }
        isMutating = true
        let result = await BackgroundWork.run(operation: "export generic 3MF") {
            let url = try EnginePaths.exportURL(name: projectName, pathExtension: "3mf")
            try plater.export3mf(to: url.path)
            return url
        }
        isMutating = false
        switch result {
        case .success(let url):
            lastExport = url
            status.report(.document, "3MF exported: \(url.lastPathComponent)")
        case .failure(let failure):
            status.report(.document, failure: failure)
        }
    }

    /// Desktop "Export sliced 3MF" (.gcode.3mf): slices every non-empty
    /// plate and embeds the G-code — the USB-printer file. Runs under the
    /// slicing gate (it IS a slice).
    func exportGcode3mf(projectName: String, presets: EnginePresets, bed: EngineBed) async {
        guard let input = beginSlicing() else {
            status.report(.document, "export blocked: document is not ready or is busy")
            return
        }
        defer { finishSlicing() }
        let name = projectName.isEmpty ? "plater" : projectName
        do {
            let url = try EnginePaths.gcodeOutputURL(
                sceneName: (name as NSString).deletingPathExtension + ".gcode")
            // .gcode.3mf beside the G-code outputs
            let target = url.deletingPathExtension().appendingPathExtension("3mf")
            let job = try SliceJob()
            do {
                let rgba = try ThumbnailService.render(scene: input.snapshot, bed: bed)
                try job.setThumbnail(size: ThumbnailService.size, rgba: rgba)
            } catch {
                status.report(.document, failure: AppFailure.wrap(
                    error, operation: "render export thumbnail"))
            }
            let progressCallback: @Sendable (Int, String) -> Void = {
                [weak self] percent, message in
                Task { @MainActor in
                    self?.status.update(.document, "export 3MF: \(percent)% \(message)")
                }
            }
            let result = await BackgroundWork.run(operation: "export sliced 3MF") {
                try input.plater.exportGcode3mf(
                    to: target.path, presets: presets, job: job, progress: progressCallback)
            }
            switch result {
            case .success(let sliceResult):
                lastExport = target
                let minutes = Int(sliceResult.timeEstimateSeconds / 60)
                let warningNote = sliceResult.warnings.isEmpty
                    ? "" : " \u{00b7} \(sliceResult.warnings.count) warning(s)"
                status.report(
                    .document,
                    "sliced 3MF ready: \(target.lastPathComponent) \u{00b7} ~\(minutes) min print\(warningNote)")
            case .failure(let failure):
                status.report(.document, failure: failure)
            }
        } catch {
            status.report(.document, failure: AppFailure.wrap(
                error, operation: "prepare sliced 3MF export"))
        }
    }

    /// Background-session autosave (desktop auto-backup subset): a fast,
    /// thumbnail-less 3MF at a fixed Application Support path. Restored once
    /// on the next launch by AppEnvironment.
    func saveAutosave(to url: URL, presets: EnginePresets) async {
        guard let plater, let scene, !isBusy, !scene.objects.isEmpty else { return }
        isMutating = true
        let result = await BackgroundWork.run(operation: "autosave project") {
            try plater.saveProject(path: url.path, presets: presets, thumbnail: nil)
        }
        isMutating = false
        if case .failure(let failure) = result {
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

    /// Desktop "New project": a fresh document session (plates at the
    /// current machine's bed, empty history). The preset selection is kept —
    /// desktop does not reset profiles on New.
    func newProject(bed: PrintVolume?) async {
        guard !isBusy else {
            status.report(.document, "new project blocked: document is busy")
            return
        }
        isMutating = true
        let result = await BackgroundWork.run(operation: "new project") {
            let plater = try EnginePlater()
            if let bed {
                _ = try plater.setBed(
                    originX: bed.minX, originY: bed.minY,
                    width: bed.width, depth: bed.depth, height: 1000.0
                )
            }
            return (plater, try plater.snapshot())
        }
        isMutating = false
        switch result {
        case .success(let fresh):
            plater = fresh.0
            selection = nil
            multiSelection = []
            clearFlattenPlanes()
            install(fresh.1)
            frameRequest += 1
            status.report(.document, "new project")
        case .failure(let failure):
            status.report(.document, failure: failure)
        }
    }

    // MARK: History / object list (desktop Edit menu, object list)

    func undo() async {
        guard history?.canUndo == true else { return }
        _ = await applyMutation(.undo, operation: "undo")
    }

    func redo() async {
        guard history?.canRedo == true else { return }
        _ = await applyMutation(.redo, operation: "redo")
    }

    func rename(_ objectID: ObjectID, to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            status.report(.document, failure: .invariant(
                operation: "rename object", diagnostic: "the name is empty"))
            return
        }
        _ = await applyMutation(.rename(objectID: objectID, name: trimmed), operation: "rename object")
    }

    /// Desktop "Delete all" (one undo step).
    func deleteAll() async {
        guard scene?.objects.isEmpty == false else { return }
        if await applyMutation(.clear, operation: "delete all") != nil {
            selection = nil
        }
    }

    // MARK: Shapes and volumes (desktop Add Primitive / object list)

    /// Desktop "Add Primitive" as a new object at the bed center.
    func addShapeObject(shape: PrimitiveShape, sizeMM: Double, bedCenter: SIMD2<Double>) async {
        if let mutation = await applyMutation(
            .addShapeObject(shape: shape, sizeMM: sizeMM, bedCenter: bedCenter),
            operation: "add shape object"
        ), let objectID = mutation.createdObjectID,
            let instanceID = mutation.snapshot.object(id: objectID)?.instances.first?.id {
            selection = InstanceSelection(objectID: objectID, instanceID: instanceID)
            frameRequest += 1
        }
    }

    /// Desktop load_generic_subobject: a shape volume for the selected
    /// instance (part / modifier / negative / blocker / enforcer).
    func addVolume(
        role: VolumeRole, shape: PrimitiveShape, sizeMM: Double,
        objectID: ObjectID, instanceID: InstanceID
    ) async {
        _ = await applyMutation(
            .volumeAddShape(
                objectID: objectID,
                instanceID: instanceID,
                role: role,
                shape: shape,
                sizeMM: sizeMM
            ),
            operation: "add volume"
        )
    }

    /// Desktop "Load...": a file as one volume of `role` on the selected
    /// object (the file is copied into the sandbox first, like imports).
    func addVolume(from source: URL, role: VolumeRole, objectID: ObjectID) async {
        guard let plater, !isBusy else {
            status.report(.document, "add part blocked: document is busy")
            return
        }
        isMutating = true
        let result = await BackgroundWork.run(operation: "load volume from file") {
            let sandboxURL = try EnginePaths.copyImportIntoSandbox(source, kind: "model")
            return try plater.apply(
                .volumeAddFile(
                    objectID: objectID,
                    role: role,
                    path: sandboxURL.path
                )
            )
        }
        isMutating = false
        switch result {
        case .success(let mutation):
            install(mutation.snapshot)
            status.report(.document, "\(source.lastPathComponent): added as \(role.label.lowercased())")
        case .failure(let failure):
            status.report(.document, failure: failure)
        }
    }

    func setVolumeType(_ role: VolumeRole, volumeID: VolumeID, objectID: ObjectID) async {
        _ = await applyMutation(
            .volumeSetType(objectID: objectID, volumeID: volumeID, role: role),
            operation: "change volume type"
        )
    }

    func deleteVolume(_ volumeID: VolumeID, objectID: ObjectID) async {
        _ = await applyMutation(
            .volumeDelete(objectID: objectID, volumeID: volumeID),
            operation: "delete volume"
        )
    }

    func renameVolume(_ volumeID: VolumeID, to name: String, objectID: ObjectID) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            status.report(.document, failure: .invariant(
                operation: "rename volume", diagnostic: "the name is empty"))
            return
        }
        _ = await applyMutation(
            .volumeRename(objectID: objectID, volumeID: volumeID, name: trimmed),
            operation: "rename volume"
        )
    }

    /// Desktop "Delete selected" for a multi-selection: whole objects when
    /// every instance is selected, otherwise the selected instances.
    func deleteObjects(_ objectIDs: [ObjectID]) async {
        guard !objectIDs.isEmpty else { return }
        _ = await applyMutation(
            .deleteObjects(objectIDs),
            operation: "delete objects"
        )
    }

    /// Desktop Selection::erase: the whole group in ONE undo step. An object
    /// whose every instance is selected is removed entirely (engine-side
    /// promotion), a partially selected object keeps its other instances.
    func deleteSelectedGroup() async {
        let group = selectedGroup
        guard !group.isEmpty, let scene else { return }
        // Expand fully-selected objects to all their instances so the batch
        // delete can promote them.
        var members: [EnginePlater.GroupInstance] = []
        let byObject = Dictionary(grouping: group, by: \.objectID)
        for (objectID, selected) in byObject {
            guard let object = scene.object(id: objectID) else { continue }
            if selected.count >= object.instances.count {
                members.append(contentsOf: object.instances.map {
                    EnginePlater.GroupInstance(
                        objectID: objectID, instanceID: $0.id
                    )
                })
            } else {
                members.append(contentsOf: selected.map {
                    EnginePlater.GroupInstance(
                        objectID: $0.objectID, instanceID: $0.instanceID
                    )
                })
            }
        }
        guard !members.isEmpty else { return }
        if await applyMutation(
            .deleteInstances(members),
            operation: "delete selection"
        ) != nil {
            multiSelection = []
        }
    }

    // MARK: Per-object / per-part settings (desktop "Edit Process Settings")

    /// Current overrides of an object (volumeID nil) or one of its volumes.
    func settings(objectID: ObjectID, volumeID: VolumeID?) async -> [String: String]? {
        guard let plater else { return nil }
        let result = await BackgroundWork.run(operation: "read object settings") {
            try plater.settings(objectID: objectID, volumeID: volumeID)
        }
        switch result {
        case .success(let values):
            return values
        case .failure(let failure):
            status.report(.document, failure: failure)
            return nil
        }
    }

    func setSetting(objectID: ObjectID, volumeID: VolumeID?, key: String, value: String) async {
        _ = await applyMutation(
            .setSetting(objectID: objectID, volumeID: volumeID, key: key, value: value),
            operation: "set \(key)"
        )
    }

    func eraseSetting(objectID: ObjectID, volumeID: VolumeID?, key: String) async {
        _ = await applyMutation(
            .eraseSetting(objectID: objectID, volumeID: volumeID, key: key),
            operation: "remove \(key)"
        )
    }

    // MARK: Object operations (desktop object menu, ABI v23)

    func setPrintable(objectID: ObjectID, instanceID: InstanceID?, printable: Bool) async {
        _ = await applyMutation(
            .setPrintable(objectID: objectID, instanceID: instanceID, printable: printable),
            operation: "set printable"
        )
    }

    func setInstanceCount(objectID: ObjectID, count: Int) async {
        _ = await applyMutation(
            .setInstanceCount(objectID: objectID, count: count),
            operation: "set number of instances"
        )
    }

    /// Desktop Clone dialog: `count` copies, optionally followed by Arrange
    /// (desktop "Auto arrange plate after cloning").
    func cloneObject(objectID: ObjectID, count: Int, arrangeWith presets: EnginePresets?) async {
        guard await applyMutation(
            .cloneObject(objectID: objectID, count: count),
            operation: "clone object"
        ) != nil else { return }
        if let presets {
            await arrangeAll(presets: presets, allowRotations: false)
        }
    }

    func separateInstance(objectID: ObjectID, instanceID: InstanceID) async {
        if let mutation = await applyMutation(
            .instanceToObject(objectID: objectID, instanceID: instanceID),
            operation: "set instance as object"
        ), let created = mutation.createdObjectID,
            let createdInstance = mutation.snapshot.object(id: created)?.instances.first?.id {
            selection = InstanceSelection(objectID: created, instanceID: createdInstance)
        }
    }

    /// Desktop "Assemble": the distinct objects of the multi-selection.
    func assembleSelection() async {
        var objectIDs: [ObjectID] = []
        for member in selectedGroup where !objectIDs.contains(member.objectID) {
            objectIDs.append(member.objectID)
        }
        guard objectIDs.count >= 2 else {
            status.report(.document, failure: .invariant(
                operation: "assemble", diagnostic: "select at least two objects"))
            return
        }
        if let mutation = await applyMutation(.mergeObjects(objectIDs), operation: "assemble"),
           let created = mutation.createdObjectID,
           let instanceID = mutation.snapshot.object(id: created)?.instances.first?.id {
            multiSelection = []
            selection = InstanceSelection(objectID: created, instanceID: instanceID)
        }
    }

    func scaleToFit(objectID: ObjectID, instanceID: InstanceID, presets: EnginePresets) async {
        guard let plater, !isBusy else {
            status.report(.document, "scale to fit blocked: document is busy")
            return
        }
        isMutating = true
        let result = await BackgroundWork.run(operation: "scale to build volume") {
            try plater.apply(.scaleToFit(objectID: objectID, instanceID: instanceID), presets: presets)
        }
        isMutating = false
        switch result {
        case .success(let mutation):
            install(mutation.snapshot)
            frameRequest += 1
        case .failure(let failure):
            status.report(.document, failure: failure)
        }
    }

    func convertUnits(objectID: ObjectID, conversion: UnitConversion) async {
        if let mutation = await applyMutation(
            .convertUnits(objectID: objectID, conversion),
            operation: conversion.label
        ), let created = mutation.createdObjectID,
            let instanceID = mutation.snapshot.object(id: created)?.instances.first?.id {
            selection = InstanceSelection(objectID: created, instanceID: instanceID)
            frameRequest += 1
        }
    }

    // MARK: Mirror / clipboard (desktop object menu)

    func mirrorSelected(axis: EngineAxis) async {
        guard let selection else { return }
        await mirrorObject(
            objectID: selection.objectID,
            instanceID: selection.instanceID,
            axis: axis
        )
    }

    func mirrorObject(
        objectID: ObjectID, instanceID: InstanceID, axis: EngineAxis
    ) async {
        _ = await applyMutation(
            .mirrorInstance(objectID: objectID, instanceID: instanceID, axis: axis),
            operation: "mirror"
        )
    }

    func copySelected() async {
        let ids = selectedObjectIDs
        guard !ids.isEmpty else { return }
        if await applyMutation(.copyObjects(ids), operation: "copy objects") != nil {
            status.report(
                .document,
                ids.count == 1 ? "object copied" : "\(ids.count) objects copied"
            )
        }
    }

    /// Desktop Cut: copy to the clipboard, then delete in one undo step.
    func cutSelected() async {
        let ids = selectedObjectIDs
        guard !ids.isEmpty else { return }
        guard await applyMutation(
            .copyObjects(ids), operation: "cut objects"
        ) != nil else { return }
        if await applyMutation(.deleteObjects(ids), operation: "cut objects") != nil {
            status.report(
                .document,
                ids.count == 1 ? "object cut" : "\(ids.count) objects cut"
            )
        }
    }

    /// Pastes the whole clipboard beside the current selection (or at the
    /// bed center) and selects every pasted object.
    func pasteObject(bedCenter: SIMD2<Double>) async {
        var target = bedCenter
        if let instance = selectedInstance {
            target = SIMD2(instance.transform.offsetX + 15, instance.transform.offsetY + 15)
        }
        if let mutation = await applyMutation(
            .pasteObjects(bedCenter: target),
            operation: "paste objects"
        ) {
            // The pasted objects are the trailing `createdObjectCount`
            // entries of the new snapshot (the engine appends).
            let objects = mutation.snapshot.objects
            let pasted = objects.suffix(max(mutation.createdObjectCount, 0))
            guard pasted.count == mutation.createdObjectCount,
                  pasted.first?.id == mutation.createdObjectID else {
                status.report(.document, failure: .invariant(
                    operation: "paste objects",
                    diagnostic: "pasted object ids do not match the mutation result"
                ))
                return
            }
            let members = pasted.compactMap { object -> InstanceSelection? in
                guard let instance = object.instances.first else { return nil }
                return InstanceSelection(
                    objectID: object.id, instanceID: instance.id
                )
            }
            guard !members.isEmpty else { return }
            if members.count == 1 {
                selection = members.first
                multiSelection = []
            } else {
                multiSelection = members
                selection = members.first
            }
            frameRequest += 1
        }
    }

    /// Unique object IDs of the current selection / multi-selection.
    var selectedObjectIDs: [ObjectID] {
        var seen: Set<ObjectID> = []
        var ids: [ObjectID] = []
        for member in selectedGroup where !seen.contains(member.objectID) {
            seen.insert(member.objectID)
            ids.append(member.objectID)
        }
        return ids
    }

    /// Applies a desktop camera view preset to the canvas camera.
    func applyCameraView(_ preset: CameraViewPreset) {
        cameraPreset = preset
        cameraRequestID += 1
    }

    // MARK: Split (desktop Split to objects / parts)

    func splitToObjects(_ objectID: ObjectID) async {
        if let mutation = await applyMutation(
            .splitObjects(objectID: objectID),
            operation: "split to objects"
        ), let first = mutation.createdObjectID,
            let instanceID = mutation.snapshot.object(id: first)?.instances.first?.id {
            selection = InstanceSelection(objectID: first, instanceID: instanceID)
            frameRequest += 1
            status.report(.document, "split into \(mutation.createdObjectCount) objects")
        }
    }

    func splitToParts(_ objectID: ObjectID, volumeID: VolumeID?) async {
        if let mutation = await applyMutation(
            .splitParts(objectID: objectID, volumeID: volumeID),
            operation: "split to parts"
        ) {
            status.report(.document, "split into \(mutation.createdPartCount) parts")
        }
    }

    func select(objectID: ObjectID?, instanceID: InstanceID?) {
        guard let objectID, let instanceID,
              scene?.instance(
                  objectID: objectID,
                  instanceID: instanceID
              ) != nil else {
            selection = nil
            multiSelection = []
            clearPreview()
            return
        }
        selection = InstanceSelection(objectID: objectID, instanceID: instanceID)
        if multiSelection.count > 1 { multiSelection = [selection!] }
        clearPreview()
    }

    /// Desktop ctrl+click: toggles membership of a multi-selection; the
    /// toggled instance becomes the primary when added.
    func toggleSelect(objectID: ObjectID, instanceID: InstanceID) {
        guard scene?.instance(objectID: objectID, instanceID: instanceID) != nil else {
            return
        }
        let member = InstanceSelection(objectID: objectID, instanceID: instanceID)
        if let index = multiSelection.firstIndex(of: member) {
            multiSelection.remove(at: index)
            if multiSelection.isEmpty {
                selection = member  // deselected the last member: keep primary
            } else {
                selection = multiSelection.first
            }
        } else {
            if selection != nil && multiSelection.isEmpty {
                multiSelection = [selection!]
            }
            multiSelection.append(member)
            selection = member
        }
        clearPreview()
    }

    /// Desktop "Select all": every instance of every object.
    func selectAll() {
        guard let scene else { return }
        var all: [InstanceSelection] = []
        for object in scene.objects {
            for instance in object.instances {
                all.append(InstanceSelection(objectID: object.id, instanceID: instance.id))
            }
        }
        guard !all.isEmpty else { return }
        multiSelection = all
        selection = all.first
        clearPreview()
    }

    func clearMultiSelection() {
        guard !multiSelection.isEmpty else { return }
        multiSelection = selection.map { [$0] } ?? []
        clearPreview()
    }

    /// Desktop part selection: refines the selection to one volume of the
    /// object (nil returns to the whole object). Single-selection only.
    func selectVolume(objectID: ObjectID, instanceID: InstanceID, volumeID: VolumeID?) {
        guard let object = scene?.object(id: objectID),
              object.instances.contains(where: { $0.id == instanceID }) else { return }
        if let volumeID,
           !object.volumes.contains(where: { $0.id == volumeID }) {
            status.report(.document, failure: .invariant(
                operation: "select part",
                diagnostic: "volume \(volumeID) is not part of object \(objectID)"
            ))
            return
        }
        var updated = InstanceSelection(objectID: objectID, instanceID: instanceID)
        updated.volumeID = volumeID
        selection = updated
        multiSelection = []
        clearPreview()
    }

    /// Desktop rectangle (marquee) selection: replaces the selection with
    /// the instances whose screen footprint intersected the rectangle.
    func setMultiSelection(_ members: [InstanceSelection]) {
        guard let scene else { return }
        let valid = members.filter {
            scene.instance(objectID: $0.objectID, instanceID: $0.instanceID) != nil
        }
        guard !valid.isEmpty else {
            multiSelection = []
            selection = nil
            clearPreview()
            return
        }
        multiSelection = valid
        selection = valid.first
        clearPreview()
    }

    // MARK: Settings clipboard (desktop Copy / Paste Process Settings)

    private(set) var settingsClipboard: [String: String]?
    private(set) var settingsClipboardIsVolume = false

    /// Copies the target's overrides (desktop copy_settings_to_clipboard).
    func copySettings(objectID: ObjectID, volumeID: VolumeID?) async {
        guard let values = await settings(objectID: objectID, volumeID: volumeID) else {
            return
        }
        settingsClipboard = values
        settingsClipboardIsVolume = volumeID != nil
        status.report(
            .document,
            values.isEmpty
                ? "no overrides to copy"
                : "copied \(values.count) setting\(values.count == 1 ? "" : "s")"
        )
    }

    /// Desktop paste_settings_into_list: object → object, part → part only;
    /// the target's overrides are REPLACED in one undo step.
    func pasteSettings(objectID: ObjectID, volumeID: VolumeID?) async {
        guard let clipboard = settingsClipboard, !clipboard.isEmpty else {
            status.report(.document, failure: .invariant(
                operation: "paste process settings",
                diagnostic: "the settings clipboard is empty"
            ))
            return
        }
        guard settingsClipboardIsVolume == (volumeID != nil) else {
            status.report(.document, failure: .invariant(
                operation: "paste process settings",
                diagnostic: "settings paste between object and part is not supported (copy from the same kind)"
            ))
            return
        }
        if await applyMutation(
            .applySettings(objectID: objectID, volumeID: volumeID, overrides: clipboard),
            operation: "paste process settings"
        ) != nil {
            status.report(.document, "pasted \(clipboard.count) setting\(clipboard.count == 1 ? "" : "s")")
        }
    }

    var canPasteSettings: Bool {
        guard let clipboard = settingsClipboard else { return false }
        return !clipboard.isEmpty
    }

    // MARK: Manipulation (gesture previews on the engine matrix → one
    // engine mutation on commit; the engine rests the instance on the bed)

    /// Snap step for panel-driven rotation (desktop rotate-gizmo fine zone).
    static let rotationSnapDegrees = 5.0

    private enum PendingManipulation {
        case move
        case rotate(EngineAxis, Double)
        case scale(Double)
        case scaleAxis(EngineAxis, Double)
    }

    private var pending: PendingManipulation?
    private var manipulationBase: simd_float4x4?

    private var selectedInstance: SceneInstance? {
        guard let selection else { return nil }
        return scene?.instance(objectID: selection.objectID, instanceID: selection.instanceID)
    }

    private func instanceMatrix(_ member: InstanceSelection) -> simd_float4x4? {
        scene?.instance(objectID: member.objectID, instanceID: member.instanceID)
            .map { EngineMatrix.float($0.matrix) }
    }

    var selectedAuthoritativeTransform: InstanceTransform? { selectedInstance?.transform }

    private var selectedAuthoritativeMatrix: simd_float4x4? {
        selectedInstance.map { EngineMatrix.float($0.matrix) }
    }

    /// Transform shown by the panels: always the engine's authoritative value
    /// (gesture previews are matrix-only and commit as one mutation).
    /// Transform shown by the panels: the authoritative value PLUS the live
    /// gesture preview (pending), so readouts update while the finger drags
    /// (user spec), not only after commit.
    var selectedDisplayTransform: InstanceTransform? {
        guard var live = selectedAuthoritativeTransform else { return nil }
        switch pending {
        case .move:
            if let selection,
               let preview = previewMatrices[selection.instanceID],
               let base = manipulationBase {
                let delta = EngineMatrix.origin(preview) - EngineMatrix.origin(base)
                live.offsetX += Double(delta.x)
                live.offsetY += Double(delta.y)
            }
        case .rotate(let axis, let radians):
            switch axis {
            case .x: live.rotationX += radians
            case .y: live.rotationY += radians
            case .z: live.rotationZ += radians
            }
        case .scale(let factor):
            live.scaleX *= factor
            live.scaleY *= factor
            live.scaleZ *= factor
        case .scaleAxis(let axis, let factor):
            switch axis {
            case .x: live.scaleX *= factor
            case .y: live.scaleY *= factor
            case .z: live.scaleZ *= factor
            }
        case nil:
            break
        }
        return live
    }

    /// Local (object-axis) size: snapshot bounds × per-axis scale (live:
    /// includes the gesture preview).
    var selectedSize: SIMD3<Float>? {
        guard let selection,
              let object = scene?.object(id: selection.objectID),
              let transform = selectedDisplayTransform else { return nil }
        return object.mesh.bounds.size * SIMD3<Float>(transform.scale)
    }

    func moveSelected(by delta: SIMD2<Float>) {
        guard !isBusy else { return }
        for member in selectedGroup {
            guard let current = previewMatrices[member.instanceID] ?? instanceMatrix(member) else {
                continue
            }
            previewMatrices[member.instanceID] =
                EngineMatrix.translation(SIMD3(delta.x, delta.y, 0)) * current
        }
        pending = .move
        presentationRevision += 1
    }

    func beginManipulation() {
        guard !isBusy else { return }
        manipulationBase = selection.flatMap { previewMatrices[$0.instanceID] }
            ?? selectedAuthoritativeMatrix
        groupBases = selectedGroup.reduce(into: [:]) { bases, member in
            if let matrix = instanceMatrix(member) { bases[member.instanceID] = matrix }
        }
    }

    private var groupBases: [InstanceID: simd_float4x4] = [:]

    /// Live rotation preview about a world axis through the object center.
    /// Snap follows the desktop gizmo's drag-distance zones: `snapDegrees`
    /// 45 = coarse, 5 = fine, 0 = free continuous rotation.
    func previewRotation(axis: EngineAxis, deltaRadians: Double, snapDegrees: Double) {
        guard !isBusy, let selection, let base = manipulationBase else { return }
        let snapped: Double
        if snapDegrees > 0 {
            let step = snapDegrees * .pi / 180
            snapped = (deltaRadians / step).rounded() * step
        } else {
            snapped = deltaRadians
        }
        let origin = EngineMatrix.origin(base)
        previewMatrices[selection.instanceID] = EngineMatrix.translation(origin)
            * EngineMatrix.rotation(axis, radians: Float(snapped))
            * EngineMatrix.translation(-origin)
            * base
        pending = .rotate(axis, snapped)
        presentationRevision += 1
    }

    /// Live uniform-scale preview (local axes, about the object center).
    func previewScale(factor: Double) {
        guard !isBusy, let selection, let base = manipulationBase,
              factor.isFinite, factor > 0 else { return }
        let clamped = min(max(factor, 0.01), 100)
        previewMatrices[selection.instanceID] =
            base * EngineMatrix.scale(SIMD3(repeating: Float(clamped)))
        pending = .scale(clamped)
        presentationRevision += 1
    }

    /// Live per-axis scale preview (desktop scale gizmo axis handles): one
    /// local axis scales, the object stays anchored at its center.
    func previewScale(axis: EngineAxis, factor: Double) {
        guard !isBusy, let selection, let base = manipulationBase,
              factor.isFinite, factor > 0 else { return }
        let clamped = min(max(factor, 0.01), 100)
        var scale = SIMD3<Float>(repeating: 1)
        scale[Int(axis.rawValue)] = Float(clamped)
        previewMatrices[selection.instanceID] = base * EngineMatrix.scale(scale)
        pending = .scaleAxis(axis, clamped)
        presentationRevision += 1
    }

    // MARK: Flatten planes (desktop GLGizmoFlatten hull grouping, ABI v29)

    private(set) var flattenPlanes: [EnginePlater.FlattenPlane]?
    private(set) var flattenHighlight: Int?
    private var flattenPlanesKey: (revision: DocumentRevision, instanceID: InstanceID)?

    /// Loads (and caches per revision + instance) the resting planes of the
    /// selected instance for the lay-flat mode. Failure clears the planes and
    /// surfaces loudly — the facet-tap fallback keeps working.
    func loadFlattenPlanes() async {
        guard let plater, let scene, let selection, !isBusy else {
            flattenPlanes = nil
            flattenPlanesKey = nil
            return
        }
        let key = (revision: scene.revision, instanceID: selection.instanceID)
        if let flattenPlanesKey,
           flattenPlanesKey.revision == key.revision,
           flattenPlanesKey.instanceID == key.instanceID { return }
        flattenPlanesKey = key
        flattenHighlight = nil
        let objectID = selection.objectID
        let instanceID = selection.instanceID
        let result = await BackgroundWork.run(operation: "load flatten planes") {
            try plater.flattenPlanes(objectID: objectID, instanceID: instanceID)
        }
        switch result {
        case .success(let planes):
            flattenPlanes = planes
        case .failure(let failure):
            flattenPlanes = nil
            status.report(.document, failure: failure)
        }
    }

    func clearFlattenPlanes() {
        flattenPlanes = nil
        flattenPlanesKey = nil
        flattenHighlight = nil
    }

    func setFlattenHighlight(_ index: Int?) {
        flattenHighlight = index
    }

    func commitSelectedTransform() async {
        let gesture = pending
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
            guard let previewed = previewMatrices[selection.instanceID] else {
                clearPreview()
                return
            }
            let delta = EngineMatrix.origin(previewed) - EngineMatrix.origin(authoritativeMatrix)
            if selectedGroup.count > 1 {
                var group: [EnginePlater.GroupTransform] = []
                for member in selectedGroup {
                    guard
                        groupBases[member.instanceID] != nil,
                        let transform = scene?.instance(
                            objectID: member.objectID, instanceID: member.instanceID
                        )?.transform
                    else { continue }
                    var moved = transform
                    moved.offsetX += Double(delta.x)
                    moved.offsetY += Double(delta.y)
                    group.append(EnginePlater.GroupTransform(
                        instance: EnginePlater.GroupInstance(
                            objectID: member.objectID, instanceID: member.instanceID
                        ),
                        transform: moved
                    ))
                }
                _ = await applyMutation(
                    .groupSetTransforms(group, label: "Move"),
                    operation: "move selection"
                )
                return
            }
            var moved = authoritative
            moved.offsetX += Double(delta.x)
            moved.offsetY += Double(delta.y)
            await setSelectedTransform(moved, label: "Move")
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
            await setSelectedTransform(scaled, label: "Scale")
        case .scaleAxis(let axis, let factor):
            var scaled = authoritative
            switch axis {
            case .x: scaled.scaleX *= factor
            case .y: scaled.scaleY *= factor
            case .z: scaled.scaleZ *= factor
            }
            await setSelectedTransform(scaled, label: "Scale \(axis == .x ? "X" : axis == .y ? "Y" : "Z")")
        }
    }

    /// Absolute transform (numeric panels). The engine rests it on the bed.
    /// `label` names the undo step.
    func setSelectedTransform(_ transform: InstanceTransform, label: String) async {
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
                          transform: transform, label: label),
            operation: "transform"
        )
    }

    // MARK: Plates (ABI v27; desktop plate bar)

    /// The document's plates (index order); derived from the snapshot.
    var plates: [ScenePlate] { scene?.plates ?? [] }

    /// The selected plate (working plate: import target + slice source).
    var currentPlate: ScenePlate? {
        guard let scene, scene.currentPlate >= 0,
              scene.currentPlate < scene.plates.count else { return nil }
        return scene.plates[scene.currentPlate]
    }

    /// Import anchor of the working plate (bed-center semantics).
    var currentPlateCenter: SIMD2<Double>? {
        currentPlate.map { SIMD2(Double($0.center.x), Double($0.center.y)) }
    }

    /// Bed geometry sync: the plate grid derives from the selected machine's
    /// print volume (client-driven; desktop resets plate size on machine
    /// change). The z range is open — every instance rests on the bed, so
    /// assignment is decided by the X/Y footprint. While the engine is busy
    /// (e.g. slicing) the new volume is retained and replayed on the next
    /// install — derived-state maintenance, never dropped (a stale plate
    /// grid would misplace everything sliced in the meantime).
    private var pendingBedSync: PrintVolume?

    func syncBed(_ volume: PrintVolume) async {
        guard let plater else { return }
        guard !isBusy else {
            pendingBedSync = volume
            status.update(.document, "bed sync pending: engine busy")
            return
        }
        let result = await BackgroundWork.run(operation: "sync bed geometry") {
            try plater.setBed(
                originX: volume.minX, originY: volume.minY,
                width: volume.width, depth: volume.depth, height: 1000.0
            )
        }
        switch result {
        case .success(let snapshot):
            install(snapshot)
        case .failure(let failure):
            status.report(.document, failure: failure)
        }
    }

    func addPlate() async {
        if let mutation = await applyMutation(.addPlate, operation: "add plate"),
           let plate = mutation.createdPlateID.flatMap({ mutation.snapshot.plate(id: $0) }) {
            status.report(.document, "added \(plate.name)")
        }
    }

    func deletePlate(_ id: PlateID) async {
        _ = await applyMutation(.deletePlate(id), operation: "delete plate")
    }

    func renamePlate(_ id: PlateID, to name: String) async {
        _ = await applyMutation(.renamePlate(id, name: name), operation: "rename plate")
    }

    func lockPlate(_ id: PlateID, locked: Bool) async {
        _ = await applyMutation(
            .lockPlate(id, locked: locked),
            operation: locked ? "lock plate" : "unlock plate"
        )
    }

    func movePlateToFront(_ id: PlateID) async {
        _ = await applyMutation(.movePlateToFront(id), operation: "move plate to front")
    }

    func duplicatePlate(_ id: PlateID) async {
        _ = await applyMutation(.duplicatePlate(id), operation: "duplicate plate")
    }

    /// Selects the working plate (session state) and re-frames the camera.
    func selectPlate(_ id: PlateID) async {
        guard let plater, !isBusy else { return }
        let result = await BackgroundWork.run(operation: "select plate") {
            try plater.selectPlate(id)
        }
        switch result {
        case .success(let snapshot):
            install(snapshot)
            frameRequest += 1
        case .failure(let failure):
            status.report(.document, failure: failure)
        }
    }

    // MARK: Move to plate (desktop plate context menu)

    /// Desktop "Move to plate": shifts every instance of the listed objects
    /// — relative placement preserved — so the group centers on the target
    /// plate. One undo step; membership re-derives from the new positions.
    func moveObjectsToPlate(_ objectIDs: [ObjectID], plate: PlateID) async {
        guard let scene, let target = scene.plate(id: plate) else { return }
        var center = SIMD2<Double>.zero
        var instanceCount = 0
        for id in objectIDs {
            guard let object = scene.object(id: id) else { continue }
            for instance in object.instances {
                center += SIMD2(instance.transform.offsetX, instance.transform.offsetY)
                instanceCount += 1
            }
        }
        guard instanceCount > 0 else {
            status.report(.document, failure: .invariant(
                operation: "move to plate",
                diagnostic: "the objects have no instances"))
            return
        }
        let groupCenter = center / Double(instanceCount)
        let targetCenter = SIMD2(Double(target.center.x), Double(target.center.y))
        let delta = targetCenter - groupCenter
        guard abs(delta.x) > 0.01 || abs(delta.y) > 0.01 else { return }
        var group: [EnginePlater.GroupTransform] = []
        var seen = Set<InstanceID>()
        for id in objectIDs {
            guard let object = scene.object(id: id) else { continue }
            for instance in object.instances where seen.insert(instance.id).inserted {
                var moved = instance.transform
                moved.offsetX += delta.x
                moved.offsetY += delta.y
                group.append(EnginePlater.GroupTransform(
                    instance: EnginePlater.GroupInstance(
                        objectID: id, instanceID: instance.id
                    ),
                    transform: moved
                ))
            }
        }
        if await applyMutation(
            .groupSetTransforms(group, label: "Move to plate"),
            operation: "move to plate"
        ) != nil {
            status.report(.document, "moved to \(target.name)")
        }
    }

    // MARK: Arrange / orient / lay flat (desktop toolbar parity)

    /// Desktop "Fill bed" (FillBedJob): fills the current plate with clones
    /// of the selected object's template instance (instances variant — same
    /// object, desktop `fill_bed_with_instances` semantics).
    func fillBed(objectID: ObjectID, presets: EnginePresets, allowRotations: Bool) async {
        guard let plater, !isBusy else {
            status.report(.document, "fill bed blocked: document is busy")
            return
        }
        isMutating = true
        let result = await BackgroundWork.run(operation: "fill bed") {
            try plater.apply(.fillBed(objectID: objectID, allowRotations: allowRotations), presets: presets)
        }
        isMutating = false
        switch result {
        case .success(let mutation):
            install(mutation.snapshot)
            frameRequest += 1
            if mutation.fillBedAddedInstances > 0 {
                status.report(
                    .document,
                    "plate filled: \(mutation.fillBedAddedInstances) cop" +
                        (mutation.fillBedAddedInstances == 1 ? "y" : "ies") + " added"
                )
            } else {
                status.report(.document, "plate is already full")
            }
        case .failure(let failure):
            status.report(.document, failure: failure)
        }
    }

    func arrangeAll(presets: EnginePresets, allowRotations: Bool) async {
        guard let plater, !isBusy else {
            status.report(.document, "arrange blocked: document is busy")
            return
        }
        isMutating = true
        let result = await BackgroundWork.run(operation: "arrange") {
            try plater.apply(.arrange(allowRotations: allowRotations), presets: presets)
        }
        isMutating = false
        switch result {
        case .success(let mutation):
            install(mutation.snapshot)
            frameRequest += 1
            if mutation.unprintableCount > 0 {
                status.report(
                    .document,
                    "arranged; \(mutation.unprintableCount) object(s) did not fit " +
                        "the print bed and were placed beside it"
                )
            } else {
                status.report(.document, "arranged")
            }
        case .failure(let failure):
            status.report(.document, failure: failure)
        }
    }

    func orientAll(presets: EnginePresets) async {
        guard let plater, !isBusy else {
            status.report(.document, "orient blocked: document is busy")
            return
        }
        isMutating = true
        let result = await BackgroundWork.run(operation: "orient") {
            try plater.apply(.orientAll, presets: presets)
        }
        isMutating = false
        switch result {
        case .success(let mutation):
            install(mutation.snapshot)
            frameRequest += 1
            status.report(.document, "oriented")
        case .failure(let failure):
            status.report(.document, failure: failure)
        }
    }

    func layFlatSelected(normal: SIMD3<Double>, presets: EnginePresets) async {
        guard let plater, let selection, !isBusy else {
            status.report(.document, "lay flat blocked: engine is not ready")
            return
        }
        isMutating = true
        let result = await BackgroundWork.run(operation: "lay flat") {
            try plater.apply(
                .layFlat(
                    objectID: selection.objectID,
                    instanceID: selection.instanceID,
                    normal: normal
                ),
                presets: presets
            )
        }
        isMutating = false
        switch result {
        case .success(let mutation):
            install(mutation.snapshot)
            frameRequest += 1
            status.report(.document, "laid flat")
        case .failure(let failure):
            status.report(.document, failure: failure)
        }
    }

    func rotateSelected(axis: EngineAxis, degrees: Double) async {
        guard let selection else { return }
        let radians = degrees * .pi / 180
        if selectedGroup.count > 1 {
            let group = selectedGroup.map {
                EnginePlater.GroupInstance(objectID: $0.objectID, instanceID: $0.instanceID)
            }
            _ = await applyMutation(
                .groupRotate(group, axis: axis, radians: radians),
                operation: "rotate selection"
            )
            return
        }
        _ = await applyMutation(
            .rotate(objectID: selection.objectID, instanceID: selection.instanceID,
                    axis: axis, radians: radians),
            operation: "rotate"
        )
    }

    func resetRotation() async {
        guard var transform = selectedAuthoritativeTransform else { return }
        transform.rotationX = 0
        transform.rotationY = 0
        transform.rotationZ = 0
        await setSelectedTransform(transform, label: "Reset rotation")
    }

    private func clearPreview() {
        previewMatrices = [:]
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
            clearPreview()
            status.report(.document, failure: failure)
            return nil
        }
    }

    private func install(_ authoritativeScene: SceneSnapshot) {
        if let current = scene,
           current.documentID == authoritativeScene.documentID,
           authoritativeScene.revision < current.revision {
            previewMatrices = [:]
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
        previewMatrices = [:]
        if let selection,
           authoritativeScene.instance(
               objectID: selection.objectID,
               instanceID: selection.instanceID
           ) == nil {
            self.selection = nil
        }
        // A selected volume may have been deleted/split: drop the refinement,
        // keeping the object selected.
        if let volumeID = selection?.volumeID,
           let object = selection.flatMap({ authoritativeScene.object(id: $0.objectID) }),
           !object.volumes.contains(where: { $0.id == volumeID }) {
            selection?.volumeID = nil
        }
        multiSelection.removeAll { member in
            authoritativeScene.instance(
                objectID: member.objectID, instanceID: member.instanceID
            ) == nil
        }
        if multiSelection.count <= 1 { multiSelection = [] }
        presentationRevision += 1
        // Replay a bed sync that arrived while the engine was busy.
        if let pending = pendingBedSync {
            pendingBedSync = nil
            Task { await syncBed(pending) }
        }
    }
}
