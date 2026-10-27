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
    /// Zoom step request (id + multiplicative scale, like the pinch).
    private(set) var cameraZoomRequest: UInt64 = 0
    private(set) var cameraZoomScale: Float = 1
    private(set) var isMutating = false
    private(set) var isSlicing = false
    private(set) var isBootstrapping = false

    init(status: StatusCenter) {
        self.status = status
        loadRecentModels()
        loadModelSourceObjectIDs()
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
        let previousObjectIDs = Set((scene?.objects ?? []).map(\.id))
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
            recordRecentModel(source)
            // Desktop "Reload from disk" needs the ORIGINAL source: record
            // it for every object this import created (multi-object files
            // create several; the mutation only names the first).
            let createdIDs = commit.mutation.snapshot.objects
                .map(\.id)
                .filter { !previousObjectIDs.contains($0) }
            if !createdIDs.isEmpty {
                await recordModelSource(source, objectIDs: createdIDs)
            }
        case .failure(let failure):
            status.report(.document, failure: failure)
        }
    }

    // MARK: Recent models (File menu "Recent", desktop recent-files parity)

    /// One recently imported model: source path + import date. Plain value —
    /// recent models are derived UI state, never engine state.
    struct RecentFile: Codable, Identifiable, Equatable, Sendable {
        let url: URL
        let date: Date

        var id: String { url.absoluteString }
    }

    /// Recently imported models, newest first. Persisted in UserDefaults
    /// (the Projects half of the Recent menu derives from the filesystem,
    /// models have no fixed home so the list must be kept explicitly).
    /// Re-import goes through `importModel` again — the original path must
    /// still be readable (iOS grants file-picker access per session; a
    /// revoked path fails loudly through the normal import error path).
    private(set) var recentModels: [RecentFile] = []
    private static let recentModelsKey = "recent.models"
    /// "recent.files.max" (@AppStorage key, default 10) bounds the list.
    private static var recentFilesLimit: Int {
        let stored = UserDefaults.standard.integer(forKey: "recent.files.max")
        return stored > 0 ? stored : 10
    }

    /// Reloads which objects carry a model source (bookmark presence —
    /// the copy records are written together with it at import time).
    private func loadModelSourceObjectIDs() {
        let prefix = Self.modelSourceBookmarkKey
        var ids = Set<ObjectID>()
        for key in UserDefaults.standard.dictionaryRepresentation().keys
        where key.hasPrefix(prefix) {
            if let raw = UInt64(key.dropFirst(prefix.count)), raw != 0 {
                ids.insert(ObjectID(rawValue: raw))
            }
        }
        modelSourceObjectIDs = ids
    }

    private func loadRecentModels() {
        guard let data = UserDefaults.standard.data(forKey: Self.recentModelsKey) else { return }
        do {
            recentModels = try JSONDecoder().decode([RecentFile].self, from: data)
        } catch {
            // Corrupt/persisted-incompatible list: drop it and say so (the
            // list rebuilds from the next imports) — never block startup.
            status.report(.document, failure: AppFailure.wrap(
                error, operation: "read recent models"))
        }
    }

    private func recordRecentModel(_ url: URL) {
        var models = recentModels.filter { $0.url != url }
        models.insert(RecentFile(url: url, date: Date()), at: 0)
        let limit = Self.recentFilesLimit
        if models.count > limit { models = Array(models.prefix(limit)) }
        recentModels = models
        do {
            let data = try JSONEncoder().encode(models)
            UserDefaults.standard.set(data, forKey: Self.recentModelsKey)
        } catch {
            status.report(.document, failure: AppFailure.wrap(
                error, operation: "save recent models"))
        }
    }

    // MARK: Model sources (desktop "Reload from disk", ABI v42)

    /// Per-object model sources for "Reload from disk": a security-scoped
    /// bookmark to the picked ORIGINAL (preferred) plus a stable import-time
    /// copy under Application Support/Sources (fallback when the bookmark
    /// no longer resolves — iOS file-picker access can be revoked). The
    /// fallback is never silent: the status says which source was used.
    private nonisolated static let modelSourceBookmarkKey = "model.source.bookmark."
    private nonisolated static let modelSourceCopyNameKey = "model.source.copyname."
    private nonisolated static let modelSourcesFolder = "Sources"
    /// Objects with a recorded source (drives menu visibility; primitives,
    /// text and SVG objects have none).
    private(set) var modelSourceObjectIDs: Set<ObjectID> = []

    private nonisolated static func bookmarkKey(_ objectID: ObjectID) -> String {
        modelSourceBookmarkKey + String(objectID.rawValue)
    }

    private nonisolated static func copyNameKey(_ objectID: ObjectID) -> String {
        modelSourceCopyNameKey + String(objectID.rawValue)
    }

    /// Application Support/Sources/<name> — the stable copies made at
    /// import time (the temp import copy is NOT stable: the next import
    /// deletes its directory). Objects from one multi-object file share a
    /// single copy (named after the first created object).
    private nonisolated static func modelSourcesDirectory() throws -> URL {
        let fileManager = FileManager.default
        let directory = fileManager.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent(modelSourcesFolder, isDirectory: true)
        try fileManager.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Records one source for freshly imported objects: a security-scoped
    /// bookmark to the ORIGINAL plus one stable copy shared by every object
    /// the import created. Failures surface (the object stays imported;
    /// only "Reload from disk" degrades to the copy or disappears).
    private func recordModelSource(_ source: URL, objectIDs: [ObjectID]) async {
        guard !objectIDs.isEmpty else { return }
        let objectIDs = objectIDs
        let recorded = await BackgroundWork.run(operation: "record model source") {
            () -> [ObjectID] in
            let fileManager = FileManager.default
            let scoped = source.startAccessingSecurityScopedResource()
            defer {
                if scoped { source.stopAccessingSecurityScopedResource() }
            }
            // iOS: plain bookmarks (security-scoped bookmarks are
            // macOS-only); resolving + startAccessing works for picker URLs.
            let bookmark = try source.bookmarkData()
            let directory = try Self.modelSourcesDirectory()
            let copyName = String(objectIDs[0].rawValue) +
                (source.pathExtension.isEmpty ? "" : "." + source.pathExtension)
            let destination = directory.appendingPathComponent(copyName)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: source, to: destination)
            for objectID in objectIDs {
                UserDefaults.standard.set(
                    bookmark, forKey: Self.bookmarkKey(objectID))
                UserDefaults.standard.set(
                    copyName, forKey: Self.copyNameKey(objectID))
            }
            return objectIDs
        }
        switch recorded {
        case .success(let ids):
            modelSourceObjectIDs.formUnion(ids)
        case .failure(let failure):
            status.report(.document, failure: failure)
        }
    }

    /// Whether "Reload from disk" is available for an object (a recorded
    /// bookmark or copy; new objects from shapes/text/SVG have none).
    func hasModelSource(_ objectID: ObjectID) -> Bool {
        modelSourceObjectIDs.contains(objectID)
    }

    /// Drops the recorded sources of discarded objects (bookmark + copy
    /// name keys); a shared copy file is removed only when NO remaining
    /// object still references it.
    private func discardModelSources(_ objectIDs: [ObjectID]) async {
        guard !objectIDs.isEmpty else { return }
        let objectIDs = objectIDs
        let discard = await BackgroundWork.run(operation: "discard model source") {
            let defaults = UserDefaults.standard
            var releasedNames = Set<String>()
            for objectID in objectIDs {
                defaults.removeObject(forKey: Self.bookmarkKey(objectID))
                if let name = defaults.string(forKey: Self.copyNameKey(objectID)) {
                    releasedNames.insert(name)
                }
                defaults.removeObject(forKey: Self.copyNameKey(objectID))
            }
            // Copy files survive while any other object still uses them.
            let referenced = Set(
                defaults.dictionaryRepresentation()
                    .compactMap { key, value -> String? in
                        key.hasPrefix(Self.modelSourceCopyNameKey)
                            ? value as? String : nil
                    }
            )
            let fileManager = FileManager.default
            let directory = try Self.modelSourcesDirectory()
            let names = try fileManager.contentsOfDirectory(atPath: directory.path)
            for name in names
            where releasedNames.contains(name) && !referenced.contains(name) {
                try fileManager.removeItem(
                    at: directory.appendingPathComponent(name))
            }
            return objectIDs
        }
        switch discard {
        case .success(let ids):
            modelSourceObjectIDs.subtract(ids)
        case .failure(let failure):
            status.report(.document, failure: failure)
        }
    }

    /// Desktop "Reload from disk": replaces the object's mesh in place
    /// (transform/settings stay; paint clears). Prefers the bookmarked
    /// ORIGINAL; falls back to the import-time copy when the original is
    /// unreachable — the status names the source either way.
    func reloadFromDisk(objectID: ObjectID) async {
        guard let plater, !isBusy else {
            status.report(.document, "reload blocked: document is busy")
            return
        }
        isMutating = true
        let result = await BackgroundWork.run(operation: "reload from disk") {
            () -> (mutation: EnginePlater.MutationResult, source: String) in
            var note = "the import-time copy"
            var fileURL: URL?
            if let bookmark = UserDefaults.standard.data(forKey: Self.bookmarkKey(objectID)) {
                do {
                    var stale = false
                    let original = try URL(
                        resolvingBookmarkData: bookmark,
                        options: [],
                        relativeTo: nil,
                        bookmarkDataIsStale: &stale)
                    let scoped = original.startAccessingSecurityScopedResource()
                    defer {
                        if scoped { original.stopAccessingSecurityScopedResource() }
                    }
                    if FileManager.default.fileExists(atPath: original.path) {
                        fileURL = try EnginePaths.copyImportIntoSandbox(
                            original, kind: "reload")
                        note = "the original file"
                    }
                } catch {
                    // Unresolvable/revoked bookmark: fall through to the
                    // stable copy; the status still says which source ran.
                    note = "the import-time copy (the original file is no longer reachable)"
                }
            }
            if fileURL == nil {
                // Fallback: the import-time copy (shared per import — its
                // name is recorded per object).
                let name = UserDefaults.standard.string(
                    forKey: Self.copyNameKey(objectID))
                guard let name, !name.isEmpty else {
                    throw AppFailure.invariant(
                        operation: "reload from disk",
                        diagnostic: "no original file or import-time copy is recorded for this object")
                }
                let candidate = try Self.modelSourcesDirectory()
                    .appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: candidate.path) else {
                    throw AppFailure.invariant(
                        operation: "reload from disk",
                        diagnostic: "the recorded import-time copy is missing")
                }
                fileURL = candidate
            }
            guard let resolved = fileURL else {
                throw AppFailure.invariant(
                    operation: "reload from disk",
                    diagnostic: "no source file resolved for the reload")
            }
            let mutation = try plater.apply(
                .replaceMesh(objectID: objectID, path: resolved.path))
            return (mutation, note)
        }
        isMutating = false
        switch result {
        case .success(let outcome):
            install(outcome.mutation.snapshot)
            status.report(.document, "reloaded from \(outcome.source)")
        case .failure(let failure):
            status.report(.document, failure: failure)
        }
    }

    /// "Replace 3D file…": swap the object's mesh for a newly picked file
    /// and re-record it as the object's source.
    func replaceModelFile(objectID: ObjectID, from source: URL) async {
        guard let plater, !isBusy else {
            status.report(.document, "replace blocked: document is busy")
            return
        }
        isMutating = true
        let result = await BackgroundWork.run(operation: "replace model file") {
            let sandboxURL = try EnginePaths.copyImportIntoSandbox(source, kind: "reload")
            return try plater.apply(
                .replaceMesh(objectID: objectID, path: sandboxURL.path))
        }
        isMutating = false
        switch result {
        case .success(let mutation):
            install(mutation.snapshot)
            status.report(.document, "model replaced: \(source.lastPathComponent)")
            await discardModelSources([objectID])
            await recordModelSource(source, objectIDs: [objectID])
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
            // The whole document was replaced (see newProject): drop the
            // previous document's model sources.
            let stale = Array(modelSourceObjectIDs)
            modelSourceObjectIDs = []
            if !stale.isEmpty { await discardModelSources(stale) }
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

    /// Desktop "Export all objects as one STL": every object's mesh through
    /// its first instance in ONE binary STL (ABI v40).
    func exportAllSTL(projectName: String) async {
        guard let plater, !isBusy else {
            status.report(.document, "export blocked: document is busy")
            return
        }
        let name = (projectName.isEmpty ? "plater" : projectName)
        isMutating = true
        let result = await BackgroundWork.run(operation: "export all STL") {
            let url = try EnginePaths.exportURL(
                name: name + "_all", pathExtension: "stl")
            try plater.exportAllSTL(to: url.path)
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

    /// Desktop "Export objects as STLs": one binary STL per object (the
    /// single-object export looped over the current snapshot).
    func exportEachSTL() async {
        guard let plater, let scene, !isBusy else {
            status.report(.document, "export blocked: document is busy")
            return
        }
        let objects = scene.objects
        isMutating = true
        let result = await BackgroundWork.run(operation: "export objects as STLs") {
            () -> [URL] in
            var urls: [URL] = []
            for object in objects {
                let url = try EnginePaths.exportURL(name: object.name, pathExtension: "stl")
                try plater.exportSTL(objectID: object.id, to: url.path)
                urls.append(url)
            }
            return urls
        }
        isMutating = false
        switch result {
        case .success(let urls):
            lastExport = urls.last
            status.report(
                .document,
                urls.count == 1
                    ? "STL exported: \(urls[0].lastPathComponent)"
                    : "\(urls.count) STLs exported to Files ▸ Exports")
        case .failure(let failure):
            status.report(.document, failure: failure)
        }
    }

    /// Desktop "Export plate sliced file": the sliced-3MF export restricted
    /// to the SELECTED plate (ABI v40). An empty plate is rejected by the
    /// Bridge with a typed error — surfaced here as the status message.
    func exportGcode3mfCurrentPlate(
        projectName: String, presets: EnginePresets, bed: EngineBed
    ) async {
        guard let input = beginSlicing() else {
            status.report(.document, "export blocked: document is not ready or is busy")
            return
        }
        defer { finishSlicing() }
        guard let plate = currentPlate else {
            status.report(.document, failure: .invariant(
                operation: "export plate sliced 3MF",
                diagnostic: "no plate is selected"))
            return
        }
        let name = projectName.isEmpty ? "plater" : projectName
        do {
            let url = try EnginePaths.gcodeOutputURL(
                sceneName: (name as NSString).deletingPathExtension
                    + "_plate\(plate.index + 1).gcode")
            let target = url.deletingPathExtension().appendingPathExtension("3mf")
            let job = try SliceJob()
            do {
                let rgba = try ThumbnailService.render(scene: input.snapshot, bed: bed)
                try job.setThumbnail(size: ThumbnailService.size, rgba: rgba)
            } catch {
                status.report(.document, failure: AppFailure.wrap(
                    error, operation: "render export thumbnail"))
            }
            let plateIndex = plate.index
            let progressCallback: @Sendable (Int, String) -> Void = {
                [weak self] percent, message in
                Task { @MainActor in
                    self?.status.update(.document, "export 3MF: \(percent)% \(message)")
                }
            }
            let result = await BackgroundWork.run(operation: "export plate sliced 3MF") {
                try input.plater.exportGcode3mfPlate(
                    plateIndex: plateIndex,
                    to: target.path, presets: presets, job: job,
                    progress: progressCallback)
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
                error, operation: "prepare plate sliced 3MF export"))
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
            // The whole document was replaced: drop every recorded model
            // source (deleting single objects keeps theirs — undo must keep
            // "Reload from disk" working for restored objects).
            let stale = Array(modelSourceObjectIDs)
            modelSourceObjectIDs = []
            if !stale.isEmpty { await discardModelSources(stale) }
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

    // MARK: Drop / floating (desktop Drop + Auto Drop, ABI v41)

    /// The selected instance's auto-drop flag (move-panel hint + Z field);
    /// nil = no selection.
    var selectedAutoDrop: Bool? {
        selectedInstance?.autoDrop
    }

    /// Desktop context "Drop": rest the object on the bed now (even for
    /// floating objects — it does not re-enable auto drop).
    func dropObjectToBed(objectID: ObjectID) async {
        if await applyMutation(.dropObject(objectID: objectID), operation: "drop to bed") != nil {
            status.report(.document, "dropped to bed")
        }
    }

    /// Desktop auto_drop: nil instanceID = every instance of the object.
    /// Enabling it rests the instances on the bed immediately (Bridge).
    func setAutoDrop(objectID: ObjectID, instanceID: InstanceID?, autoDrop: Bool) async {
        _ = await applyMutation(
            .setAutoDrop(objectID: objectID, instanceID: instanceID, autoDrop: autoDrop),
            operation: autoDrop ? "auto drop" : "keep floating"
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

    /// One multiplicative zoom step for the canvas camera (the hardware
    /// keyboard's Zoom in/out, desktop I/O keys; the pinch gesture applies
    /// the same camera.zoom).
    func requestCameraZoom(_ scale: Float) {
        cameraZoomScale = scale
        cameraZoomRequest += 1
    }

    /// Desktop "Cut": plane cut through the object's world bbox; the object
    /// is replaced by the kept parts (one undo step). Selects the first
    /// result and re-frames.
    func cutSelected(
        axis: EngineAxis, fraction: Double, keep: EnginePlater.CutKeep
    ) async {
        guard let current = selection,
              let object = scene?.object(id: current.objectID),
              let instance = object.instances.first(where: { $0.id == current.instanceID })
        else { return }
        // World-space bbox of the instance (engine frame).
        let matrix = instance.matrix
        var low = SIMD3<Double>(repeating: .infinity)
        var high = SIMD3<Double>(repeating: -.infinity)
        let mesh = object.mesh
        for index in 0..<mesh.positions.count {
            let p = mesh.positions[index]
            let local = SIMD3<Double>(Double(p.x), Double(p.y), Double(p.z))
            let world = SIMD3(
                matrix[0, 0] * local.x + matrix[1, 0] * local.y + matrix[2, 0] * local.z + matrix[3, 0],
                matrix[0, 1] * local.x + matrix[1, 1] * local.y + matrix[2, 1] * local.z + matrix[3, 1],
                matrix[0, 2] * local.x + matrix[1, 2] * local.y + matrix[2, 2] * local.z + matrix[3, 2])
            low = simd_min(low, world)
            high = simd_max(high, world)
        }
        let axisIndex = Int(axis.rawValue)
        let point = SIMD3(
            axisIndex == 0 ? low.x + (high.x - low.x) * fraction : 0.5 * (low.x + high.x),
            axisIndex == 1 ? low.y + (high.y - low.y) * fraction : 0.5 * (low.y + high.y),
            axisIndex == 2 ? low.z + (high.z - low.z) * fraction : 0.5 * (low.z + high.z))
        let normal: SIMD3<Double> = axis == .x ? SIMD3(1, 0, 0)
            : axis == .y ? SIMD3(0, 1, 0) : SIMD3(0, 0, 1)
        if let mutation = await applyMutation(
            .cut(objectID: object.id, instanceID: instance.id,
                 planePoint: point, normal: normal, keep: keep),
            operation: "cut object"
        ), let created = mutation.createdObjectID,
           let createdInstance = mutation.snapshot.object(id: created)?.instances.first?.id {
            selection = InstanceSelection(objectID: created, instanceID: createdInstance)
            multiSelection = []
            frameRequest += 1
            status.report(.document, "cut into \(mutation.createdObjectCount) object(s)")
        }
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

    /// Desktop "Add SVG": flat raised SVG object at the plate center.
    func addSVGObject(from source: URL, depthMM: Double) async {
        guard let plater, !isBusy else {
            status.report(.document, "add svg blocked: document is busy")
            return
        }
        isMutating = true
        let center = currentPlateCenter ?? SIMD2<Double>(0, 0)
        let result = await BackgroundWork.run(operation: "add svg object") {
            let sandbox = try EnginePaths.copyImportIntoSandbox(source, kind: "model")
            return try plater.addSVGObject(
                path: sandbox.path, depthMM: depthMM, bedCenter: center)
        }
        isMutating = false
        switch result {
        case .success(let mutation):
            install(mutation.snapshot)
            if let id = mutation.createdObjectID,
               let instance = mutation.snapshot.object(id: id)?.instances.first?.id {
                selection = InstanceSelection(objectID: id, instanceID: instance)
            }
            frameRequest += 1
            status.report(.document, "SVG added")
        case .failure(let failure):
            status.report(.document, failure: failure)
        }
    }

    /// IMPL-F integration: existing ranges for the editor sheet.
    func heightRanges(objectID: ObjectID) async -> [EnginePlater.HeightRange] {
        guard let plater else { return [] }
        let result = await BackgroundWork.run(operation: "read height ranges") {
            try plater.objectHeightRanges(objectID: objectID)
        }
        switch result {
        case .success(let ranges): return ranges
        case .failure(let failure):
            status.report(.document, failure: failure)
            return []
        }
    }

    func setHeightRanges(
        objectID: ObjectID, ranges: [EnginePlater.HeightRange]
    ) async -> Bool {
        await applyMutation(
            .setHeightRanges(objectID: objectID, ranges: ranges),
            operation: "set height ranges"
        ) != nil
    }

    // MARK: Object shells + COG (ABI v37)

    /// Hull + centroid of every object (IMPL-B contract shim, coordinator
    /// implementation). Empty when the document has no objects.
    func objectHulls() async -> [ObjectID: EnginePlater.HullMesh] {
        guard let plater, let scene, !scene.objects.isEmpty else { return [:] }
        var result: [ObjectID: EnginePlater.HullMesh] = [:]
        for object in scene.objects {
            let id = object.id
            let hull = await BackgroundWork.run(operation: "object hull \(id)") {
                try plater.objectHull(objectID: id)
            }
            switch hull {
            case .success(let mesh):
                result[id] = mesh
            case .failure(let failure):
                status.report(.document, failure: failure)
            }
        }
        return result
    }

    /// Desktop "Add Text": flat raised text object at the plate center.
    func addTextObject(text: String, sizeMM: Double, depthMM: Double) async {
        guard let plater, !isBusy else {
            status.report(.document, "add text blocked: document is busy")
            return
        }
        // Bundled Sarabun (SIL OFL 1.1) — shipped with the app.
        guard let fontURL = Bundle.module.url(
            forResource: "Sarabun-Regular", withExtension: "ttf",
            subdirectory: "Fonts")
        else {
            status.report(.document, failure: .invariant(
                operation: "add text object",
                diagnostic: "the bundled font is missing from the app"))
            return
        }
        isMutating = true
        let bedCenter = currentPlateCenter ?? SIMD2<Double>(0, 0)
        let result = await BackgroundWork.run(operation: "add text object") {
            try plater.addTextObject(
                text: text, fontPath: fontURL.path,
                sizeMM: sizeMM, depthMM: depthMM,
                bedCenter: bedCenter)
        }
        isMutating = false
        switch result {
        case .success(let mutation):
            install(mutation.snapshot)
            if let id = mutation.createdObjectID,
               let instance = mutation.snapshot.object(id: id)?.instances.first?.id {
                selection = InstanceSelection(objectID: id, instanceID: instance)
            }
            frameRequest += 1
            status.report(.document, "text added")
        case .failure(let failure):
            status.report(.document, failure: failure)
        }
    }

    // MARK: Painting (desktop painter gizmos, ABI v36)

    /// Painted triangles of the selected object (all layers merged with
    /// layer-tagged colors resolved by the renderer).
    private(set) var paintTriangles: [EnginePlater.PaintTriangle] = []
    private(set) var paintLayer: EnginePlater.PaintLayer = .support

    /// Brush radius in world mm (desktop painter slider).
    var paintRadiusMM: Double = 2.0
    /// Paint state (EnforcerBlockerType: 1 enforcer/colour-1, 2 blocker/colour-2...).
    var paintState: Int32 = 1

    func selectPaintLayer(_ layer: EnginePlater.PaintLayer) {
        paintLayer = layer
        Task { await reloadPaint() }
    }

    /// Reloads the selected object's paint for the active layer.
    func reloadPaint() async {
        guard let plater, let selection else {
            paintTriangles = []
            return
        }
        let objectID = selection.objectID
        let volumeID = selection.volumeID
            ?? scene?.object(id: objectID)?.volumes.first(where: { $0.role == .part })?.id
        guard let volumeID else {
            paintTriangles = []
            return
        }
        let layer = paintLayer
        let result = await BackgroundWork.run(operation: "read paint") {
            try plater.volumePaint(objectID: objectID, volumeID: volumeID, layer: layer)
        }
        switch result {
        case .success(let triangles):
            paintTriangles = triangles
        case .failure(let failure):
            paintTriangles = []
            status.report(.document, failure: failure)
        }
    }

    /// One sphere-brush stroke at a world hit (one undo step per stroke —
    /// the canvas paints on touch END, desktop batches per stroke).
    func paint(at hit: SIMD3<Double>, viewDir: SIMD3<Double>) async {
        guard let selection else { return }
        let objectID = selection.objectID
        let volumeID = selection.volumeID
            ?? scene?.object(id: objectID)?.volumes.first(where: { $0.role == .part })?.id
        guard let volumeID else { return }
        let layer = paintLayer
        let radius = paintRadiusMM
        let state = paintState
        _ = await applyMutation(
            .paintSphere(
                objectID: objectID, volumeID: volumeID, layer: layer,
                hit: hit, viewDir: viewDir, radiusMM: radius, state: state),
            operation: "paint"
        )
        await reloadPaint()
    }

    func clearPaint() async {
        guard let selection else { return }
        let objectID = selection.objectID
        let volumeID = selection.volumeID
            ?? scene?.object(id: objectID)?.volumes.first(where: { $0.role == .part })?.id
        guard let volumeID else { return }
        let layer = paintLayer
        if await applyMutation(
            .paintReset(objectID: objectID, volumeID: volumeID, layer: layer),
            operation: "clear paint"
        ) != nil {
            await reloadPaint()
        }
    }

    // MARK: Measure gizmo (desktop GLGizmoMeasure, ABI v40)

    /// The engine measure session over the measured object's merged mesh
    /// (OBJECT space; triangle indices match the snapshot mesh 1:1). The
    /// CPU-heavy build crosses BackgroundWork; pick/between are fast pure
    /// calls on the copied mesh but still stay off the main actor.
    private(set) var measureContext: EnginePlater.MeasureContext?
    private(set) var measureObjectID: ObjectID?
    /// Picked features, slots A and B (nil until picked).
    private(set) var measureFeatures: [EnginePlater.SurfaceFeature?] = [nil, nil]
    private(set) var measureResult: EnginePlater.FeatureMeasurement?
    /// The mesh + document revision the context was built for (the session
    /// is invalidated on any change — see `install`).
    private var measureMeshRevision: UInt64?
    private var measureRevision: DocumentRevision?
    private var isBuildingMeasure = false

    /// Whether a measure session is active (panel + overlay visibility).
    var isMeasuring: Bool {
        measureObjectID != nil || measureFeatures.contains { $0 != nil }
    }

    /// One measure tap: the merged-mesh triangle + raw object-space hit
    /// point of the tapped facet (from the canvas FacePick). Builds the
    /// session on first tap / different object, picks the feature, fills
    /// slot A then B, computes the measurement, and resets on the tap
    /// after a complete pair (desktop pair semantics).
    func handleMeasureTap(
        objectID: ObjectID, triangleIndex: Int32, objectPoint: SIMD3<Double>
    ) async {
        guard !isBuildingMeasure else { return }
        // A different object starts a fresh session (desktop keeps one
        // measuring per mesh).
        if measureObjectID != objectID { clearMeasure() }
        guard let context = await ensureMeasureContext(objectID: objectID) else { return }
        let pickResult = await BackgroundWork.run(operation: "measure pick") {
            try context.pick(faceIndex: triangleIndex, point: objectPoint)
        }
        switch pickResult {
        case .failure(let failure):
            status.report(.document, failure: failure)
        case .success(let feature):
            // The session may have been invalidated while the pick ran (any
            // document change clears it) — a stale pick is dropped; the
            // user taps again.
            guard measureObjectID == objectID else { return }
            // A complete A+B measurement: this tap restarts the pair.
            if measureResult != nil || measureFeatures[1] != nil {
                measureFeatures = [feature, nil]
                measureResult = nil
                return
            }
            if let a = measureFeatures[0] {
                let between = await BackgroundWork.run(operation: "measure between") {
                    try context.between(a, feature)
                }
                switch between {
                case .success(let measurement):
                    guard measureObjectID == objectID else { return }
                    measureFeatures[1] = feature
                    measureResult = measurement
                case .failure(let failure):
                    status.report(.document, failure: failure)
                }
            } else {
                measureFeatures[0] = feature
            }
        }
    }

    /// Builds (and caches) the measure context for one object. Any document
    /// change while the mesh is being analyzed makes the context stale —
    /// its triangle indices are pinned to the tapped mesh — so it is
    /// dropped and the user taps again.
    private func ensureMeasureContext(
        objectID: ObjectID
    ) async -> EnginePlater.MeasureContext? {
        if let measureContext, measureObjectID == objectID { return measureContext }
        clearMeasure()
        guard let plater, let object = scene?.object(id: objectID), !isBusy else {
            status.report(.document, "measure blocked: document is busy or object missing")
            return nil
        }
        isBuildingMeasure = true
        defer { isBuildingMeasure = false }
        let revisionAtRequest = scene?.revision
        status.report(.document, "measure: analyzing \(object.name)…")
        let result = await BackgroundWork.run(operation: "build measure context") {
            try plater.measureContext(objectID: objectID)
        }
        switch result {
        case .success(let context):
            guard scene?.revision == revisionAtRequest,
                  scene?.object(id: objectID)?.mesh.revision == object.mesh.revision
            else {
                status.report(
                    .document, "measure: the object changed while analyzing — tap again")
                return nil
            }
            measureContext = context
            measureObjectID = objectID
            measureMeshRevision = object.mesh.revision
            measureRevision = revisionAtRequest
            return context
        case .failure(let failure):
            status.report(.document, failure: failure)
            return nil
        }
    }

    /// Clears the session: features, measurement and the context (its
    /// deinit disposes the engine side) — the panel's Clear button.
    func clearMeasure() {
        measureContext = nil
        measureObjectID = nil
        measureFeatures = [nil, nil]
        measureResult = nil
        measureMeshRevision = nil
        measureRevision = nil
    }

    /// Assembles the renderer overlay payload (object space); `labelText`
    /// is the units-formatted distance (the panel owns units).
    func measureOverlay(labelText: String?) -> Renderer.MeasureOverlay? {
        guard let measureObjectID else { return nil }
        let result = measureResult
        return Renderer.MeasureOverlay(
            objectID: measureObjectID,
            features: measureFeatures,
            from: result?.hasDistance == true ? result?.from : nil,
            to: result?.hasDistance == true ? result?.to : nil,
            labelText: result?.hasDistance == true ? labelText : nil
        )
    }

    // MARK: Variable layer height (desktop layersediting gizmo, ABI v41)

    /// The selected object's layer-height profile: flat (z, height_mm)
    /// pairs in object space, z 0..maxZ. Empty = uniform slicing. Loaded
    /// async when the gizmo activates / selection / revision changes (the
    /// Plate tab's canvas task drives `loadVLH`).
    private(set) var vlhProfile: [Double] = []
    /// Resolved layer-height context exactly as slicing consumes it
    /// (process `layer_height`, machine min/max): baseline display, local
    /// preview clamps and the Adaptive/adjust guards.
    private(set) var vlhLayerHeight: Double = 0.2
    private(set) var vlhMinLayerHeight: Double = 0.07
    private(set) var vlhMaxLayerHeight: Double = 0.3
    /// Horizontal display axis max: desktop 1.12 × max layer height with
    /// a 0.6 mm readable floor (GLCanvas3D.cpp:508).
    private(set) var vlhDisplayMax: Double = 0.6
    /// The object's engine `max_z` (max z over every instance's
    /// transformed mesh — the profile's z span; computed in engine
    /// semantics, see `VLHApproximation.engineMaxZ`).
    private(set) var vlhObjectMaxZ: Double = 0
    /// Live gesture state: the drag's z/band (accent lines + local
    /// preview) and the approximate curve shown until the commit replaces
    /// it with engine truth.
    private(set) var vlhDragZ: Double?
    private(set) var vlhPreview: [Double]?
    /// Panel adjust parameters (desktop: `strength` 0.005 + `band_width`
    /// 2.0 defaults, GLCanvas3D.hpp:258-260; the mouse wheel scales the
    /// band on desktop, the panel slider here).
    var vlhThicknessDelta: Double = 0.005
    var vlhBandWidth: Double = 2.0
    /// Engine LayerHeightEditActionType: 0 increase, 1 decrease,
    /// 2 reduce (toward the process height), 3 smooth.
    var vlhAction: Int32 = 0
    /// Objects carrying a non-empty profile (object-list indicator);
    /// loaded lazily by the objects sheet.
    private(set) var vlhObjectIDs: Set<ObjectID> = []

    private var vlhKey: (revision: DocumentRevision, objectID: ObjectID)?

    /// Loads the selected object's profile + resolved layer-height context
    /// (cached per revision + object — the canvas task re-drives it on
    /// every change; see the Plate tab's `.task(id:)`).
    func loadVLH(presets: EnginePresets?) async {
        guard let plater, let selection else {
            vlhProfile = []
            vlhPreview = nil
            vlhDragZ = nil
            vlhKey = nil
            return
        }
        let key = (revision: scene?.revision ?? DocumentRevision(rawValue: 0),
                   objectID: selection.objectID)
        if let vlhKey,
           vlhKey.revision == key.revision,
           vlhKey.objectID == key.objectID { return }
        vlhKey = key
        vlhDragZ = nil
        vlhPreview = nil
        let objectID = selection.objectID
        // Engine ModelObject::max_z() semantics (Model.cpp:1466 — the
        // Bridge validates profile tops against it to 1e-6): the max z
        // over EVERY instance's transformed mesh, computed like
        // TriangleMesh::transformed_bounding_box — the double instance
        // matrix applied to the float vertex values (the snapshot's
        // double matrix keeps this bit-exact; a float matrix would drift
        // past the tolerance).
        let snapshotObject = scene?.object(id: objectID)
        let positions = snapshotObject?.mesh.positions ?? []
        let matrices = (snapshotObject?.instances ?? []).map(\.matrix)
        let context: (profile: [Double], layerHeight: Double, minLayer: Double, maxLayer: Double, maxZ: Double)?
        if let presets {
            let result = await BackgroundWork.run(operation: "load layer-height profile") {
                let profile = try plater.heightProfile(objectID: objectID)
                let config = try presets.resolvedConfig().get()
                guard let data = config.data(using: .utf8) else {
                    throw AppFailure.invariant(
                        operation: "load layer-height profile",
                        diagnostic: "resolved config is not UTF-8 data")
                }
                let values: [String: String]
                do {
                    values = try JSONDecoder().decode([String: String].self, from: data)
                } catch {
                    throw AppFailure.invariant(
                        operation: "load layer-height profile",
                        diagnostic: "resolved config decode failed: \(error.localizedDescription)")
                }
                guard let layerHeight = Double(values["layer_height"] ?? ""),
                      let minLayer = Double(values["min_layer_height"] ?? ""),
                      let maxLayer = Double(values["max_layer_height"] ?? "") else {
                    throw AppFailure.invariant(
                        operation: "load layer-height profile",
                        diagnostic: "resolved config is missing " +
                            "layer_height / min_layer_height / max_layer_height")
                }
                return (profile, layerHeight, minLayer, maxLayer,
                        VLHApproximation.engineMaxZ(
                            positions: positions, matrices: matrices))
            }
            switch result {
            case .success(let loaded):
                context = loaded
            case .failure(let failure):
                status.report(.document, failure: failure)
                context = nil
            }
        } else {
            status.report(.document, "layers: presets are not loaded — showing the profile only")
            let result = await BackgroundWork.run(operation: "load layer-height profile") {
                try plater.heightProfile(objectID: objectID)
            }
            switch result {
            case .success(let profile):
                context = (profile, vlhLayerHeight, vlhMinLayerHeight, vlhMaxLayerHeight,
                           VLHApproximation.engineMaxZ(
                               positions: positions, matrices: matrices))
            case .failure(let failure):
                status.report(.document, failure: failure)
                context = nil
            }
        }
        // A revision may have advanced while the read ran — a stale load
        // is dropped; the canvas task re-drives with the new key.
        guard vlhKey?.revision == key.revision,
              vlhKey?.objectID == key.objectID else { return }
        if let context {
            vlhProfile = context.profile
            vlhLayerHeight = context.layerHeight
            vlhMinLayerHeight = context.minLayer
            vlhMaxLayerHeight = context.maxLayer
            vlhDisplayMax = max(1.12 * context.maxLayer, 0.6)
            vlhObjectMaxZ = context.maxZ
        } else {
            vlhProfile = []
            vlhObjectMaxZ = VLHApproximation.engineMaxZ(
                positions: positions, matrices: matrices)
        }
    }

    /// Clears the VLH session (gizmo off / selection gone).
    func clearVLH() {
        vlhProfile = []
        vlhPreview = nil
        vlhDragZ = nil
        vlhKey = nil
    }

    /// Live drag feedback: records the gesture z and approximates the
    /// engine's adjust locally (display only — the commit replaces it with
    /// engine truth). Follows Slicing.cpp adjust_layer_height_profile: the
    /// band [z − band/2, z + band/2] is resampled at 0.1 mm and shifted by
    /// weight·delta with weight = 0.5 + 0.5·cos(2π·Δz/band), clamped to
    /// the machine min/max. Smooth (3) shows no local change.
    func setVLHDrag(_ z: Double?) {
        vlhDragZ = z
        guard let z, z >= 0, vlhObjectMaxZ > 0 else {
            vlhPreview = nil
            return
        }
        vlhPreview = VLHApproximation.adjust(
            profile: vlhProfile,
            z: min(z, vlhObjectMaxZ),
            thicknessDelta: vlhThicknessDelta,
            bandWidth: vlhBandWidth,
            action: vlhAction,
            layerHeight: vlhLayerHeight,
            minLayerHeight: vlhMinLayerHeight,
            maxLayerHeight: vlhMaxLayerHeight,
            maxZ: vlhObjectMaxZ)
    }

    /// Commits ONE adjust mutation at the drag's end z (one undo step). An
    /// empty engine profile is first materialized as the uniform profile
    /// (desktop's update_layer_height_profile, which the Bridge leaves to
    /// the caller) — one extra undo step the first time only.
    func commitVLHAdjust(presets: EnginePresets, z: Double) async {
        guard let plater, let selection, !isBusy else {
            status.report(.document, "layer edit blocked: document is busy or object missing")
            return
        }
        let objectID = selection.objectID
        let delta = vlhThicknessDelta
        let band = vlhBandWidth
        let action = vlhAction
        let materialize = vlhProfile.count < 4
        let layerHeight = vlhLayerHeight
        let maxZ = vlhObjectMaxZ
        isMutating = true
        let result = await BackgroundWork.run(operation: "adjust layer height") {
            if materialize {
                guard maxZ > 0 else {
                    throw AppFailure.invariant(
                        operation: "adjust layer height",
                        diagnostic: "the object has no height")
                }
                _ = try plater.apply(
                    .setHeightProfile(objectID: objectID, pairs: [0, layerHeight, maxZ, layerHeight]))
            }
            let mutation = try plater.adjustHeightProfile(
                presets: presets, objectID: objectID, z: z,
                thicknessDelta: delta, bandWidth: band, action: action)
            let profile = try plater.heightProfile(objectID: objectID)
            return (mutation: mutation, profile: profile)
        }
        isMutating = false
        switch result {
        case .success(let outcome):
            install(outcome.mutation.snapshot)
            vlhProfile = outcome.profile
            vlhPreview = nil
            vlhDragZ = nil
            vlhKey = (revision: outcome.mutation.snapshot.revision, objectID: objectID)
        case .failure(let failure):
            status.report(.document, failure: failure)
        }
    }

    /// Desktop "Adaptive" (GLCanvas3D.cpp:660): regenerates the profile
    /// from the mesh at the given quality (−0.1..1; desktop slider 0..1,
    /// panel displays percent). One undo step.
    func vlhAdaptive(presets: EnginePresets, quality: Double) async {
        guard let plater, let selection, !isBusy else {
            status.report(.document, "adaptive layers blocked: document is busy or object missing")
            return
        }
        let objectID = selection.objectID
        isMutating = true
        let result = await BackgroundWork.run(operation: "adaptive layer height") {
            let outcome = try plater.adaptiveHeightProfile(
                presets: presets, objectID: objectID, quality: quality)
            let snapshot = try plater.snapshot()
            guard snapshot.revision.rawValue == outcome.revision else {
                throw AppFailure.invariant(
                    operation: "adaptive layer height",
                    diagnostic: "revision mismatch after adaptive profile")
            }
            return (snapshot, outcome.pairs)
        }
        isMutating = false
        switch result {
        case .success(let outcome):
            install(outcome.0)
            vlhProfile = outcome.1
            vlhPreview = nil
            vlhDragZ = nil
            vlhKey = (revision: outcome.0.revision, objectID: objectID)
            status.report(.document, "adaptive layers applied")
        case .failure(let failure):
            status.report(.document, failure: failure)
        }
    }

    /// Desktop "Smooth": gaussian-blurs the profile over `radius` layers
    /// (keepMin never raises a height). One undo step.
    func vlhSmooth(presets: EnginePresets, radius: UInt32, keepMin: Bool) async {
        guard let plater, let selection, !isBusy else {
            status.report(.document, "smooth layers blocked: document is busy or object missing")
            return
        }
        let objectID = selection.objectID
        isMutating = true
        let result = await BackgroundWork.run(operation: "smooth layer height") {
            let outcome = try plater.smoothHeightProfile(
                presets: presets, objectID: objectID,
                radius: radius, keepMin: keepMin)
            let snapshot = try plater.snapshot()
            guard snapshot.revision.rawValue == outcome.revision else {
                throw AppFailure.invariant(
                    operation: "smooth layer height",
                    diagnostic: "revision mismatch after smoothed profile")
            }
            return (snapshot, outcome.pairs)
        }
        isMutating = false
        switch result {
        case .success(let outcome):
            install(outcome.0)
            vlhProfile = outcome.1
            vlhPreview = nil
            vlhDragZ = nil
            vlhKey = (revision: outcome.0.revision, objectID: objectID)
            status.report(.document, "layers smoothed")
        case .failure(let failure):
            status.report(.document, failure: failure)
        }
    }

    /// Desktop "Reset": clears the profile back to uniform slicing.
    func vlhReset() async {
        guard let selection else { return }
        if await applyMutation(
            .setHeightProfile(objectID: selection.objectID, pairs: []),
            operation: "reset layer height"
        ) != nil {
            vlhProfile = []
            vlhPreview = nil
            vlhDragZ = nil
            status.report(.document, "layer heights reset")
        }
    }

    /// Assembles the renderer overlay payload (object space): the preview
    /// curve while a drag runs, else the engine profile.
    func vlhRendererOverlay() -> Renderer.VLHOverlay? {
        guard let selection else { return nil }
        return Renderer.VLHOverlay(
            objectID: selection.objectID,
            profile: vlhPreview ?? vlhProfile,
            layerHeight: vlhLayerHeight,
            minLayerHeight: vlhMinLayerHeight,
            maxLayerHeight: vlhMaxLayerHeight,
            displayMax: vlhDisplayMax,
            dragBand: vlhDragZ.map { (z: $0, band: vlhBandWidth) }
        )
    }

    /// Profile stats for the panel: min/max layer height over the curve
    /// and the layer-count estimate Σ dz/h (nil = uniform, one line).
    var vlhStats: (minHeight: Double, maxHeight: Double, layerEstimate: Int)? {
        guard vlhProfile.count >= 4, vlhProfile.count % 2 == 0,
              vlhObjectMaxZ > 0 else { return nil }
        var minHeight = Double.greatestFiniteMagnitude
        var maxHeight = 0.0
        var layers = 0.0
        for index in stride(from: 0, to: vlhProfile.count - 2, by: 2) {
            let z0 = vlhProfile[index], h0 = vlhProfile[index + 1]
            let z1 = vlhProfile[index + 2], h1 = vlhProfile[index + 3]
            minHeight = min(minHeight, min(h0, h1))
            maxHeight = max(maxHeight, max(h0, h1))
            let span = z1 - z0
            if span > 0, h0 > 0, h1 > 0 {
                // Trapezoid of dz/h over the segment.
                layers += span * (1 / h0 + 1 / h1) / 2
            }
        }
        guard minHeight <= maxHeight, layers > 0 else { return nil }
        return (minHeight, maxHeight, Int(layers.rounded(.up)))
    }

    /// Objects carrying a non-empty profile (object-list indicator) — one
    /// pass for every object, called lazily by the objects sheet.
    func loadVLHObjectIDs() async {
        guard let plater, let scene, !isBusy else { return }
        let ids = scene.objects.map(\.id)
        let result = await BackgroundWork.run(operation: "scan layer-height profiles") {
            var found: [ObjectID] = []
            for id in ids where !(try plater.heightProfile(objectID: id).isEmpty) {
                found.append(id)
            }
            return found
        }
        switch result {
        case .success(let found):
            vlhObjectIDs = Set(found)
        case .failure(let failure):
            status.report(.document, failure: failure)
        }
    }

    // MARK: Simplify / Subdivide (desktop Simplify gizmo + "Subdivision mesh", ABI v40)

    /// The volume simplify/subdivide acts on: the selected part when one is
    /// refined, else the object's first part (single-mesh imports carry
    /// exactly one part volume — same target as the painter gizmo).
    private var selectedMeshVolumeID: VolumeID? {
        guard let selection else { return nil }
        if let volumeID = selection.volumeID { return volumeID }
        return scene?.object(id: selection.objectID)?
            .volumes.first(where: { $0.role == .part })?.id
    }

    /// Desktop Simplify gizmo (quadric edge collapse, one undo step
    /// "Simplify"): either toward a wanted triangle count or by quality
    /// (maxError 1e-3…1, the desktop presets). Status reports the counts.
    func simplifySelected(
        useCount: Bool, wantedCount: UInt32, maxError: Double
    ) async {
        guard let selection, let volumeID = selectedMeshVolumeID else {
            status.report(.document, failure: .invariant(
                operation: "simplify",
                diagnostic: "select an object with a part volume"))
            return
        }
        let before = (scene?.object(id: selection.objectID)?.mesh.indices.count ?? 0) / 3
        if let mutation = await applyMutation(
            .simplifyVolume(
                objectID: selection.objectID,
                volumeID: volumeID,
                useCount: useCount,
                wantedCount: wantedCount,
                maxError: maxError),
            operation: "simplify"
        ) {
            let after = (mutation.snapshot.object(id: selection.objectID)?
                .mesh.indices.count ?? 0) / 3
            status.report(.document, "simplified: \(before) → \(after) triangles")
        }
    }

    /// Desktop "Subdivision mesh" (igl Loop, ×4 triangles, one undo step).
    /// The Bridge typed-rejects meshes over 1M faces — that failure surfaces
    /// through the mutation's status report.
    func subdivideSelected() async {
        guard let selection, let volumeID = selectedMeshVolumeID else {
            status.report(.document, failure: .invariant(
                operation: "subdivide",
                diagnostic: "select an object with a part volume"))
            return
        }
        let before = (scene?.object(id: selection.objectID)?.mesh.indices.count ?? 0) / 3
        if let mutation = await applyMutation(
            .subdivideVolume(objectID: selection.objectID, volumeID: volumeID),
            operation: "subdivide"
        ) {
            let after = (mutation.snapshot.object(id: selection.objectID)?
                .mesh.indices.count ?? 0) / 3
            status.report(.document, "subdivided: \(before) → \(after) triangles")
        }
    }

    // MARK: Hidden objects (desktop GUI_Factories "Hide"/"Show")

    /// View-only per-object visibility. Desktop semantics: a render flag on
    /// the GLVolume — NOT engine state, NOT persisted, and hidden objects
    /// still SLICE (this is not the printable toggle). Deleted objects are
    /// pruned from the set on every authoritative install.
    private(set) var hiddenObjectIDs: Set<ObjectID> = []

    func setHidden(_ hidden: Bool, objectID: ObjectID) {
        if hidden {
            hiddenObjectIDs.insert(objectID)
        } else {
            hiddenObjectIDs.remove(objectID)
        }
    }

    func showAllHidden() {
        guard !hiddenObjectIDs.isEmpty else { return }
        hiddenObjectIDs.removeAll()
    }

    // MARK: Custom G-code at layers (desktop layer ticks, selected plate)

    /// The selected plate's custom G-code ticks (nil on engine failure).
    func customGcodes() async -> [EnginePlater.CustomGcodeItem]? {
        guard let plater else { return nil }
        let result = await BackgroundWork.run(operation: "read custom G-code") {
            try plater.customGcodes()
        }
        switch result {
        case .success(let items):
            return items
        case .failure(let failure):
            status.report(.document, failure: failure)
            return nil
        }
    }

    /// Adds a tick at `printZ` on the selected plate (one undo step).
    func addCustomGcode(
        printZ: Double, kind: EnginePlater.CustomGcodeKind,
        extruder: Int, color: String, extra: String
    ) async {
        _ = await applyMutation(
            .addCustomGcode(
                printZ: printZ, kind: kind, extruder: extruder,
                color: color, extra: extra),
            operation: "add custom G-code"
        )
    }

    /// ABI v40 edit: replaces the tick at `printZ` in ONE undo step
    /// (fails typed NOT_FOUND when it vanished mid-edit — no re-insert).
    func editCustomGcode(
        printZ: Double, kind: EnginePlater.CustomGcodeKind,
        extruder: Int, color: String, extra: String
    ) async {
        _ = await applyMutation(
            .editCustomGcode(
                printZ: printZ, kind: kind, extruder: extruder,
                color: color, extra: extra),
            operation: "edit custom G-code"
        )
    }

    func deleteCustomGcode(printZ: Double) async {
        _ = await applyMutation(
            .deleteCustomGcode(printZ: printZ),
            operation: "delete custom G-code"
        )
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

    // MARK: Brim ears (desktop GLGizmoBrimEars, ABI v42)

    /// The selected object's placed ears (object space). Loaded when the
    /// gizmo activates / the document changes (the Plate tab's canvas
    /// task drives `loadBrimEars` like the flatten planes).
    private(set) var brimPoints: [(position: SIMD3<Double>, radius: Double)] = []
    private(set) var brimEarsObjectID: ObjectID?
    private(set) var brimEarSelection: Int?
    private var brimEarsKey: (revision: DocumentRevision, objectID: ObjectID)?
    /// Panel fields (desktop input window): ear diameter (desktop "Head
    /// diameter"; the engine default is initial_layer_line_width × 16 ≈
    /// 6.5 mm on a 0.4 nozzle), auto-detection angle and detection length.
    var brimEarDiameter: Double = 6.5
    var brimEarMaxAngleDeg: Double = 125
    var brimEarDetectionLength: Double = 1

    /// Loads (and caches per revision + object) the selected object's ears.
    func loadBrimEars() async {
        guard let plater, let selection, !isBusy else {
            brimPoints = []
            brimEarsObjectID = nil
            brimEarsKey = nil
            return
        }
        let key = (revision: scene?.revision ?? DocumentRevision(rawValue: 0),
                   objectID: selection.objectID)
        if let brimEarsKey,
           brimEarsKey.revision == key.revision,
           brimEarsKey.objectID == key.objectID { return }
        brimEarsKey = key
        let objectID = selection.objectID
        let result = await BackgroundWork.run(operation: "read brim ears") {
            try plater.brimPoints(objectID: objectID)
        }
        switch result {
        case .success(let points):
            brimEarsObjectID = objectID
            brimPoints = points
            if let selection = brimEarSelection, selection >= points.count {
                brimEarSelection = nil
            }
        case .failure(let failure):
            brimPoints = []
            brimEarsObjectID = nil
            status.report(.document, failure: failure)
        }
    }

    /// Clears the brim-ears session (gizmo off).
    func clearBrimEars() {
        brimPoints = []
        brimEarsObjectID = nil
        brimEarSelection = nil
        brimEarsKey = nil
    }

    /// Toggles (or clears with nil) the selected ear marker.
    func setBrimEarSelection(_ index: Int?) {
        if let index, index == brimEarSelection {
            brimEarSelection = nil
        } else {
            brimEarSelection = index
        }
    }

    /// One manual ear at a mesh tap (desktop on_mouse LeftDown: the world
    /// hit's z is forced to bed level and converted back to object space —
    /// ears always sit on the first layer, facing up). Only taps on the
    /// SELECTED instance place ears (desktop raycasts the selected
    /// volume); other taps fall through to selection/camera as usual.
    func addBrimEar(at pick: Renderer.FacePick) async {
        guard let selection,
              selection.objectID == pick.objectID,
              selection.instanceID == pick.instanceID,
              let object = scene?.object(id: pick.objectID),
              let instance = object.instances.first(where: {
                  $0.id == pick.instanceID
              }) else { return }
        let matrix = instance.matrix
        let hit = matrix * SIMD4<Double>(
            pick.objectPoint.x, pick.objectPoint.y, pick.objectPoint.z, 1)
        let bedLevel = SIMD3<Double>(hit.x, hit.y, -0.0001)
        let objectPoint = matrix.inverse * SIMD4<Double>(
            bedLevel.x, bedLevel.y, bedLevel.z, 1)
        guard objectPoint.w != 0 else { return }
        let position = SIMD3<Double>(
            objectPoint.x / objectPoint.w,
            objectPoint.y / objectPoint.w,
            objectPoint.z / objectPoint.w)
        let radius = brimEarDiameter / 2
        if await applyMutation(
            .addBrimPoint(objectID: pick.objectID, position: position, radius: radius),
            operation: "add brim ear"
        ) != nil {
            status.report(.document, "brim ear added")
        }
    }

    /// Desktop "Delete selected" on ears: the ABI exposes clear-all +
    /// add-one only, so the removal clears and re-adds the remaining ears
    /// (sequential one-undo-step mutations for ONE user action — undo
    /// steps back through them).
    func removeSelectedBrimEar() async {
        guard let brimEarsObjectID,
              let index = brimEarSelection,
              index < brimPoints.count else { return }
        let objectID = brimEarsObjectID
        let remaining = brimPoints.enumerated()
            .filter { $0.offset != index }
            .map { $0.element }
        brimEarSelection = nil
        guard await applyMutation(
            .clearBrimPoints(objectID: objectID),
            operation: "remove brim ear"
        ) != nil else { return }
        for ear in remaining {
            guard await applyMutation(
                .addBrimPoint(
                    objectID: objectID, position: ear.position, radius: ear.radius),
                operation: "remove brim ear"
            ) != nil else { return }
        }
    }

    /// Panel "Remove all": clears every ear of the selected object.
    func clearAllBrimEars() async {
        guard let brimEarsObjectID else { return }
        brimEarSelection = nil
        _ = await applyMutation(
            .clearBrimPoints(objectID: brimEarsObjectID),
            operation: "clear brim ears"
        )
    }

    /// Desktop auto-generate ("Auto add brim ears"): corners of the
    /// first-layer contour past max angle. Replaces the existing ears —
    /// clear + auto in one background run (desktop's auto ADDS to the
    /// cache; a destructive regenerate is the predictable touch semantic
    /// and matches the panel's "Auto-generate" wording). radius <= 0 =
    /// the engine default (initial_layer_line_width × 16).
    func autoBrimEars(presets: EnginePresets) async {
        guard let plater, let selection, !isBusy else {
            status.report(.document, "auto brim ears blocked: document is busy or object missing")
            return
        }
        let objectID = selection.objectID
        let hadEars = !brimPoints.isEmpty
        let maxAngle = brimEarMaxAngleDeg
        let detection = brimEarDetectionLength
        isMutating = true
        let result = await BackgroundWork.run(operation: "auto brim ears") {
            if hadEars {
                _ = try plater.apply(.clearBrimPoints(objectID: objectID))
            }
            return try plater.autoBrimEars(
                presets: presets, objectID: objectID,
                maxAngleDeg: maxAngle, detectionLengthMM: detection,
                radiusMM: 0)
        }
        isMutating = false
        switch result {
        case .success(let outcome):
            // Re-sync from the engine (the run bypassed applyMutation's
            // install; snapshot read keeps revision checks honest).
            let snapshot = await BackgroundWork.run(operation: "read snapshot") {
                try plater.snapshot()
            }
            switch snapshot {
            case .success(let snapshot):
                install(snapshot)
            case .failure(let failure):
                status.report(.document, failure: failure)
            }
            status.report(.document, "auto brim ears: \(outcome.added) ear(s) added")
        case .failure(let failure):
            status.report(.document, failure: failure)
        }
    }

    /// Assembles the renderer overlay payload for the Plate tab.
    func brimEarsOverlay() -> Renderer.BrimEarsOverlay? {
        guard let brimEarsObjectID else { return nil }
        return Renderer.BrimEarsOverlay(
            objectID: brimEarsObjectID,
            points: brimPoints,
            selectedIndex: brimEarSelection
        )
    }

    // MARK: Cut connectors (desktop CutDialog, ABI v42)

    /// Placement parameters of the cut flow (desktop CutDialog defaults:
    /// Plug / Prism / Circle, size 2.5 mm, depth 3 mm, depth tolerance
    /// 0.1). Store-owned so the placement bar and the sheet stay in sync.
    struct CutConnectorParams: Sendable, Equatable {
        /// 0 plug, 1 dowel, 2 snap.
        var type: Int32 = 0
        /// 0 prism, 1 frustum.
        var style: Int32 = 0
        /// 0 triangle, 1 square, 2 hexagon, 3 circle.
        var shape: Int32 = 3
        var radius: Double = 1.25
        var height: Double = 3
        var radiusTolerance: Double = 0
        var heightTolerance: Double = 0.1
    }

    var cutConnectorParams = CutConnectorParams()
    /// The selected object's placed connectors (object space); loaded while
    /// the cut flow is active (sheet or placement mode).
    private(set) var cutConnectors: [EnginePlater.CutConnector] = []
    private(set) var cutConnectorsObjectID: ObjectID?
    private var cutConnectorsKey: (revision: DocumentRevision, objectID: ObjectID)?

    /// Loads (and caches per revision + object) the selected object's
    /// cut connectors; the Plate tab's cut-flow task drives it.
    func loadCutConnectors() async {
        guard let plater, let selection, !isBusy else {
            cutConnectors = []
            cutConnectorsObjectID = nil
            cutConnectorsKey = nil
            return
        }
        let key = (revision: scene?.revision ?? DocumentRevision(rawValue: 0),
                   objectID: selection.objectID)
        if let cutConnectorsKey,
           cutConnectorsKey.revision == key.revision,
           cutConnectorsKey.objectID == key.objectID { return }
        cutConnectorsKey = key
        let objectID = selection.objectID
        let result = await BackgroundWork.run(operation: "read cut connectors") {
            try plater.cutConnectors(objectID: objectID)
        }
        switch result {
        case .success(let connectors):
            cutConnectorsObjectID = objectID
            cutConnectors = connectors
        case .failure(let failure):
            cutConnectors = []
            cutConnectorsObjectID = nil
            status.report(.document, failure: failure)
        }
    }

    /// Clears the cut-connector session (cut flow closed).
    func clearCutConnectorsCache() {
        cutConnectors = []
        cutConnectorsObjectID = nil
        cutConnectorsKey = nil
    }

    /// The cut plane for connector placement: the Cut sheet's axis/fraction
    /// through the selected instance's world bbox (the exact `cutSelected`
    /// geometry), converted to viewer space for the renderer.
    func cutPlaneForSelection(
        axis: EngineAxis, fraction: Double, bedCenter: SIMD2<Float>
    ) -> Renderer.CutPlane? {
        guard let selection,
              let object = scene?.object(id: selection.objectID),
              let instance = object.instances.first(where: {
                  $0.id == selection.instanceID
              }) else { return nil }
        let matrix = instance.matrix
        var low = SIMD3<Double>(repeating: .infinity)
        var high = SIMD3<Double>(repeating: -.infinity)
        for position in object.mesh.positions {
            let p = SIMD3<Double>(Double(position.x), Double(position.y), Double(position.z))
            let world = matrix * SIMD4<Double>(p.x, p.y, p.z, 1)
            low = simd_min(low, SIMD3<Double>(world.x, world.y, world.z))
            high = simd_max(high, SIMD3<Double>(world.x, world.y, world.z))
        }
        let axisIndex = Int(axis.rawValue)
        let point = SIMD3<Double>(
            axisIndex == 0 ? low.x + (high.x - low.x) * fraction : 0.5 * (low.x + high.x),
            axisIndex == 1 ? low.y + (high.y - low.y) * fraction : 0.5 * (low.y + high.y),
            axisIndex == 2 ? low.z + (high.z - low.z) * fraction : 0.5 * (low.z + high.z))
        let viewerPoint = CoordinateMapper.viewerPoint(
            fromEngine: SIMD3<Float>(Float(point.x), Float(point.y), Float(point.z)),
            bedCenter: bedCenter)
        let viewerNormal = CoordinateMapper.viewerAxis(axis)
        return Renderer.CutPlane(
            objectID: selection.objectID,
            instanceID: selection.instanceID,
            point: viewerPoint,
            normal: viewerNormal)
    }

    /// One connector placed on the cut plane (the renderer already
    /// converted the hit to object space; the normal is the cut plane's
    /// axis normal rotated into object space).
    func addCutConnector(at pick: Renderer.CutPlanePick) async {
        guard let object = scene?.object(id: pick.objectID),
              let instance = object.instances.first(where: {
                  $0.id == pick.instanceID
              }) else { return }
        let rotation = instance.matrix.inverse * SIMD4<Double>(
            pick.engineNormal.x, pick.engineNormal.y, pick.engineNormal.z, 0)
        let objectNormal = simd_normalize(SIMD3<Double>(
            rotation.x, rotation.y, rotation.z))
        let connector = EnginePlater.CutConnector(
            position: pick.objectPoint,
            normal: objectNormal,
            radius: Float(cutConnectorParams.radius),
            height: Float(cutConnectorParams.height),
            radiusTolerance: Float(cutConnectorParams.radiusTolerance),
            heightTolerance: Float(cutConnectorParams.heightTolerance),
            type: cutConnectorParams.type,
            style: cutConnectorParams.style,
            shape: cutConnectorParams.shape
        )
        _ = await applyMutation(
            .addCutConnector(objectID: pick.objectID, connector: connector),
            operation: "add cut connector"
        )
    }

    /// Panel "Remove all" of the cut flow (one undo step).
    func clearCutConnectors() async {
        guard let cutConnectorsObjectID else { return }
        _ = await applyMutation(
            .clearCutConnectors(objectID: cutConnectorsObjectID),
            operation: "clear cut connectors"
        )
    }

    /// Assembles the renderer overlay payload for the Plate tab.
    func cutConnectorsOverlay() -> Renderer.CutConnectorsOverlay? {
        guard let cutConnectorsObjectID else { return nil }
        return Renderer.CutConnectorsOverlay(
            objectID: cutConnectorsObjectID,
            connectors: cutConnectors
        )
    }

    // MARK: Assembly (desktop AssembleView explode, ABI v42)

    /// Per-object, per-instance assemble data (the facade returns one
    /// entry per instance IN the object's instance order).
    private(set) var assemblyData: [ObjectID: [(instanceID: InstanceID,
                                                info: EnginePlater.AssembleInfo)]] = [:]
    private var assemblyKey: DocumentRevision?

    /// Loads the whole document's assemble info (assembly mode explodes
    /// EVERYTHING, desktop parity); cached per revision.
    func loadAssemblyData() async {
        guard let plater, let scene, !isBusy else {
            assemblyData = [:]
            assemblyKey = nil
            return
        }
        let revision = scene.revision
        if let assemblyKey, assemblyKey == revision { return }
        assemblyKey = revision
        let objects = scene.objects
        let result = await BackgroundWork.run(operation: "read assemble info") {
            var data: [ObjectID: [(instanceID: InstanceID,
                                   info: EnginePlater.AssembleInfo)]] = [:]
            for object in objects {
                let infos = try plater.assembleInfo(objectID: object.id)
                data[object.id] = zip(object.instances, infos).map {
                    (instanceID: $0.0.id, info: $0.1)
                }
            }
            return data
        }
        switch result {
        case .success(let data):
            assemblyData = data
        case .failure(let failure):
            assemblyData = [:]
            status.report(.document, failure: failure)
        }
    }

    /// Clears the assembly session (assembly mode off).
    func clearAssemblyData() {
        assemblyData = [:]
        assemblyKey = nil
    }

    /// Per-instance viewer-space render matrices for the explode slider:
    /// ratio 0 = the plater placement, ratio 1 = the 3MF assembled
    /// placement (translation lerped, rotation slerped in object space).
    /// Instances without initialized assemble data fall back to a radial
    /// explode away from the plate center by ratio × object diagonal
    /// (desktop has no fallback — projects without 3MF assembly data stay
    /// put there; OrcaPad always gives the slider meaning).
    func assemblyOverrides(ratio: Double, bedCenter: SIMD2<Float>)
        -> [InstanceID: simd_float4x4] {
        guard ratio > 0.001, let scene else { return [:] }
        let clamped = min(max(ratio, 0), 1)
        var overrides: [InstanceID: simd_float4x4] = [:]
        for object in scene.objects {
            let diagonal = Double(simd_distance(
                object.mesh.bounds.minimum, object.mesh.bounds.maximum))
            for instance in object.instances {
                let engineMatrix: simd_double4x4
                let info = assemblyData[object.id]?.first {
                    $0.instanceID == instance.id
                }?.info
                if let info, info.initialized {
                    // Object-space delta current -> assembled, interpolated
                    // by the ratio (desktop GLVolume::world_matrix explodes
                    // by translation; OrcaPad also blends the rotation so
                    // re-oriented assemblies read correctly mid-slider).
                    let current = instance.matrix
                    let delta = current.inverse * info.matrix
                    let columns = delta.columns
                    let scale3 = (
                        simd_length(SIMD3<Double>(columns.0.x, columns.0.y, columns.0.z))
                            + simd_length(SIMD3<Double>(columns.1.x, columns.1.y, columns.1.z))
                            + simd_length(SIMD3<Double>(columns.2.x, columns.2.y, columns.2.z))) / 3
                    let rotation = simd_double3x3(
                        SIMD3<Double>(columns.0.x, columns.0.y, columns.0.z),
                        SIMD3<Double>(columns.1.x, columns.1.y, columns.1.z),
                        SIMD3<Double>(columns.2.x, columns.2.y, columns.2.z))
                    let quaternion = simd_quatd(rotation)
                    let identity = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
                    let blended = simd_slerp(identity, quaternion, clamped)
                    let blendedRotation = simd_double3x3(blended)
                    let blendedScale = 1 + (scale3 - 1) * clamped
                    let translation = SIMD3<Double>(
                        columns.3.x, columns.3.y, columns.3.z) * clamped
                    let engineDelta = simd_double4x4(
                        SIMD4<Double>(
                            blendedRotation.columns.0.x * blendedScale,
                            blendedRotation.columns.0.y * blendedScale,
                            blendedRotation.columns.0.z * blendedScale, 0),
                        SIMD4<Double>(
                            blendedRotation.columns.1.x * blendedScale,
                            blendedRotation.columns.1.y * blendedScale,
                            blendedRotation.columns.1.z * blendedScale, 0),
                        SIMD4<Double>(
                            blendedRotation.columns.2.x * blendedScale,
                            blendedRotation.columns.2.y * blendedScale,
                            blendedRotation.columns.2.z * blendedScale, 0),
                        SIMD4<Double>(translation.x, translation.y, translation.z, 1))
                    engineMatrix = current * engineDelta
                } else {
                    // Radial fallback: away from the plate center in X/Y.
                    let origin = instance.matrix * SIMD4<Double>(0, 0, 0, 1)
                    var direction = SIMD2<Double>(origin.x, origin.y)
                        - SIMD2<Double>(Double(bedCenter.x), Double(bedCenter.y))
                    let length = simd_length(direction)
                    if length < 1e-6 {
                        direction = SIMD2<Double>(1, 0)
                    } else {
                        direction /= length
                    }
                    let offset = direction * (clamped * max(diagonal, 10))
                    engineMatrix = simd_double4x4(
                        SIMD4<Double>(1, 0, 0, 0),
                        SIMD4<Double>(0, 1, 0, 0),
                        SIMD4<Double>(0, 0, 1, 0),
                        SIMD4<Double>(offset.x, offset.y, 0, 1)) * instance.matrix
                }
                overrides[instance.id] = CoordinateMapper.modelMatrix(
                    engineMatrix: EngineMatrix.float(engineMatrix),
                    enginePivot: object.mesh.pivot,
                    bedCenter: bedCenter
                )
            }
        }
        return overrides
    }

    /// Assembly actions from the Measure panel (desktop gizmo assemble):
    /// 0 set parallel, 1 center coincident, 2/3 reverse rotation — applied
    /// to the SELECTED instance using the two picked measure features.
    func assembleAction(_ action: Int32) async {
        guard let selection,
              let a = measureFeatures[0],
              let b = measureFeatures[1] else { return }
        if await applyMutation(
            .assembleAction(
                objectID: selection.objectID,
                instanceID: selection.instanceID,
                a: a, b: b, action: action),
            operation: "assembly action"
        ) != nil {
            status.report(.document, "assembly action applied")
        }
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

    // MARK: Per-plate settings (desktop PlateSettingsDialog, ABI v41)

    /// Reads one plate's print settings (nil fields = project defaults);
    /// the settings sheet loads itself through this on appear.
    func plateSettings(plateID: PlateID) async -> EnginePlater.PlateSettings? {
        guard let plater else { return nil }
        let result = await BackgroundWork.run(operation: "read plate settings") {
            try plater.plateSettings(plateID: plateID)
        }
        switch result {
        case .success(let settings):
            return settings
        case .failure(let failure):
            status.report(.document, failure: failure)
            return nil
        }
    }

    /// Saves one plate's settings as ONE undoable mutation (nil fields
    /// return that setting to the project defaults; slicing consumes the
    /// overrides automatically — no client slice changes).
    func applyPlateSettings(
        plateID: PlateID, settings: EnginePlater.PlateSettings
    ) async {
        if await applyMutation(
            .setPlateSettings(plateID: plateID, settings: settings),
            operation: "plate settings"
        ) != nil {
            status.report(.document, "plate settings saved")
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
        // Hidden objects are view-only client state: deleted objects leave
        // the set (newProject/openProject replace the whole object list).
        hiddenObjectIDs.formIntersection(
            Set(authoritativeScene.objects.map(\.id)))
        // Measure gizmo (ABI v40): the session's triangle indices are pinned
        // to ONE document + mesh revision — any document change, or the
        // measured object's replacement/deletion, invalidates it (dispose +
        // clear; desktop keeps one Measure session per mesh state).
        if let measureObjectID {
            let meshStillCurrent = authoritativeScene.object(id: measureObjectID)?
                .mesh.revision == measureMeshRevision
            if authoritativeScene.revision != measureRevision || !meshStillCurrent {
                clearMeasure()
            }
        }
        // VLH (ABI v41): gesture previews are transient — every
        // authoritative install clears them (the engine result is the
        // new curve; the canvas task reloads the profile for the new
        // revision when the gizmo is active).
        vlhPreview = nil
        vlhDragZ = nil
        // Replay a bed sync that arrived while the engine was busy.
        if let pending = pendingBedSync {
            pendingBedSync = nil
            Task { await syncBed(pending) }
        }
    }
}

/// Display-only approximation of the engine's
/// `adjust_layer_height_profile` (Slicing.cpp:518): the band
/// [z − band/2, z + band/2] is resampled at 0.1 mm and every sample is
/// shifted by weight·delta with weight = 0.5 + 0.5·cos(2π·Δz/band)
/// (0 outside the band), clamped to the machine min/max. Reduce pulls
/// toward the process height like the engine; smooth changes nothing
/// locally (the engine's gaussian runs only on commit). Engine truth
/// replaces the approximation on every commit.
enum VLHApproximation {
    /// Engine `ModelObject::max_z()` (Model.cpp:1466): the max z over
    /// EVERY instance's transformed mesh — the Bridge validates profile
    /// tops against it to 1e-6. Computed like
    /// `TriangleMesh::transformed_bounding_box` (TriangleMesh.cpp:440):
    /// the DOUBLE instance matrix applied to the float vertex values —
    /// the snapshot's double matrix keeps this within the tolerance (a
    /// float matrix would drift ~1e-5 mm past it).
    static func engineMaxZ(
        positions: [SIMD3<Float>], matrices: [simd_double4x4]
    ) -> Double {
        var maxZ = 0.0
        for matrix in matrices {
            for p in positions {
                let transformed = matrix * SIMD4<Double>(
                    Double(p.x), Double(p.y), Double(p.z), 1)
                if transformed.z > maxZ { maxZ = transformed.z }
            }
        }
        return maxZ
    }

    static func adjust(
        profile: [Double],
        z: Double,
        thicknessDelta: Double,
        bandWidth: Double,
        action: Int32,
        layerHeight: Double,
        minLayerHeight: Double,
        maxLayerHeight: Double,
        maxZ: Double
    ) -> [Double]? {
        guard action >= 0, action <= 2, thicknessDelta > 0, bandWidth > 0,
              maxZ > 0 else { return nil }
        // The base curve: the engine profile, or the uniform line.
        var pairs: [(z: Double, h: Double)] = []
        if profile.count >= 4, profile.count % 2 == 0 {
            for index in stride(from: 0, to: profile.count - 1, by: 2) {
                pairs.append((z: profile[index], h: profile[index + 1]))
            }
        } else {
            pairs = [(z: 0, h: layerHeight), (z: maxZ, h: layerHeight)]
        }
        guard pairs.count >= 2 else { return nil }
        func height(at sampleZ: Double) -> Double {
            var previous = pairs[0]
            for pair in pairs.dropFirst() {
                if sampleZ <= pair.z {
                    let span = pair.z - previous.z
                    if span <= 0 { return pair.h }
                    let fraction = (sampleZ - previous.z) / span
                    return previous.h + (pair.h - previous.h) * fraction
                }
                previous = pair
            }
            return pairs[pairs.count - 1].h
        }
        let low = max(0, z - bandWidth * 0.5)
        let high = min(maxZ, z + bandWidth * 0.5)
        guard low < high else { return nil }
        // Resampled band with the engine's weight falloff.
        var band: [(z: Double, h: Double)] = []
        var sample = low
        let step = 0.1
        while sample < high {
            var h = height(at: sample)
            let weight = abs(sample - z) < bandWidth * 0.5
                ? 0.5 + 0.5 * cos(2 * Double.pi * (sample - z) / bandWidth)
                : 0
            switch action {
            case 0:  // increase
                h += weight * thicknessDelta
            case 1:  // decrease
                h -= weight * thicknessDelta
            default:  // reduce — pull toward the process height
                let delta = h - layerHeight
                let pull = weight * thicknessDelta
                h += abs(delta) > pull ? (delta > 0 ? -pull : pull) : -delta
            }
            band.append((z: sample, h: min(max(h, minLayerHeight), maxLayerHeight)))
            sample += step
        }
        if band.isEmpty { return nil }
        band.append((z: high, h: {
            var h = height(at: high)
            let weight = abs(high - z) < bandWidth * 0.5
                ? 0.5 + 0.5 * cos(2 * Double.pi * (high - z) / bandWidth)
                : 0
            if action == 0 {
                h += weight * thicknessDelta
            } else if action == 1 {
                h -= weight * thicknessDelta
            } else {
                let delta = h - layerHeight
                let pull = weight * thicknessDelta
                h += abs(delta) > pull ? (delta > 0 ? -pull : pull) : -delta
            }
            return min(max(h, minLayerHeight), maxLayerHeight)
        }()))
        // Splice: keep the pairs below the band, the resampled band, then
        // the pairs above it.
        var result: [Double] = []
        for pair in pairs where pair.z < low {
            result.append(pair.z)
            result.append(pair.h)
        }
        for pair in band {
            result.append(pair.z)
            result.append(pair.h)
        }
        for pair in pairs where pair.z > high {
            result.append(pair.z)
            result.append(pair.h)
        }
        guard result.count >= 4, result.count % 2 == 0 else { return nil }
        return result
    }
}
