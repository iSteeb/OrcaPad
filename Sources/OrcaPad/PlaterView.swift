import SwiftUI
import UniformTypeIdentifiers
import OrcaBridge
import simd
import os

private let presetsLogger = Logger(subsystem: "ie.duz.OrcaPad", category: "presets")

/// Root scene: the plater. The C++ document is authoritative; this view keeps
/// only its latest immutable snapshot plus transient gesture presentation.
struct PlaterView: View {
    @State private var rendererStatus = "Metal: starting…"
    @State private var engineStatus = "engine: ready (import an STL)"
    @State private var importPresented = false
    @State private var objectsPresented = false
    @State private var plater: EnginePlater?
    @State private var presets: EnginePresets?
    @State private var settingsPresented = false
    @State private var scene: SceneSnapshot?
    @State private var selection: (objectID: ObjectID, instanceID: InstanceID)?
    @State private var slicing = false
    @State private var documentMutationInFlight = false
    @State private var previewTransform: InstanceTransform?
    @State private var presentationRevision: UInt64 = 0
    @State private var frameRequest: UInt64 = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            canvas
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 3) {
                Text("OrcaPad")
                    .font(.caption.weight(.semibold))
                Text(rendererStatus)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(engineStatus)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
            }
            .padding(10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding(12)
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 10) {
                if let selection,
                   let object = scene?.object(id: selection.objectID),
                   !object.instances.isEmpty {
                    selectionHUD(for: selection, object: object)
                }
                platerToolbar
            }
            .padding(.bottom, 14)
        }
        .preferredColorScheme(.dark)
        .fileImporter(isPresented: $importPresented,
                      allowedContentTypes: ImportSupport.stlTypes,
                      onCompletion: handleImport)
        .sheet(isPresented: $objectsPresented) { objectsList }
        .sheet(isPresented: $settingsPresented) {
            if let presets {
                SettingsView(presets: presets) { engineStatus = $0 }
            }
        }
        .onAppear {
            if plater == nil {
                do {
                    let document = try EnginePlater()
                    scene = try document.snapshot()
                    plater = document
                } catch {
                    engineStatus = "plater init FAILED: \(error.localizedDescription)"
                }
            }
            if presets == nil {
                loadPresets()
            }
        }
    }

    /// Preset bundle load walks ~12k JSON files — strictly off-main. The
    /// resource dir is the app bundle's read-only copy of the upstream
    /// profile tree (engine expects data_dir()/system/…).
    private func loadPresets() {
        // Desktop contract: data_dir is WRITABLE and contains system/ (vendor
        // presets, read-only) + user/ (user presets + selections). We provide
        // Documents/orcapad-data with user/default/ and system/ symlinked to
        // the bundle's profile tree — zero copying of 12k files.
        let prep = preparePresetDataDir()
        if let msg = prep.failure {
            presetsLogger.error("\(msg, privacy: .public)")
            engineStatus = msg
            return
        }
        guard let dataDir = prep.dataDir else {
            engineStatus = "presets FAILED: no data dir (internal error)"
            return
        }
        loadPresetsFrom(dataDir: dataDir)
    }

    private func loadPresetsFrom(dataDir: String) {
        engineStatus = "presets: loading…"
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                EnginePresets.create(dataDir: dataDir)
            }.value
            switch result {
            case .failure(let err):
                presetsLogger.error("load failed (dataDir=\(dataDir, privacy: .public)): \(err.message, privacy: .public)")
                engineStatus = "presets FAILED: \(err.message)"
            case .success(let p):
                presets = p
                presetsLogger.notice("presets ready (dataDir=\(dataDir, privacy: .public))")
                engineStatus = "presets: ready"
                if case .success(let m) = p.current(kind: .machine) {
                    UserDefaults.standard.set(m, forKey: "preset.machine")
                }
                if case .success(let f) = p.current(kind: .filament) {
                    UserDefaults.standard.set(f, forKey: "preset.filament")
                }
                if case .success(let pr) = p.current(kind: .process) {
                    UserDefaults.standard.set(pr, forKey: "preset.process")
                }
            }
        }
    }

    @ViewBuilder
    private var canvas: some View {
        if let scene {
            MetalCanvas(
                onStatus: { rendererStatus = $0 },
                scene: SceneSync(
                    snapshot: scene,
                    selectedObjectID: selection?.objectID,
                    selectedInstanceID: selection?.instanceID,
                    previewTransform: previewTransform,
                    presentationRevision: presentationRevision,
                    frameRequest: frameRequest
                ),
                onSelect: { objectID, instanceID in
                    if let objectID, let instanceID {
                        selection = (objectID, instanceID)
                    } else {
                        selection = nil
                    }
                    previewTransform = nil
                    presentationRevision += 1
                },
                onMoveSelected: { delta in moveSelected(by: delta) },
                onMoveEnded: { commitSelectedTransform() }
            )
        } else {
            Color(red: 0.075, green: 0.078, blue: 0.093)
        }
    }

    // MARK: - Import flow

    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let err):
            engineStatus = "import failed: \(err.localizedDescription)"
        case .success(let url):
            importSTL(url)
        }
    }

    private func importSTL(_ url: URL) {
        guard let plater, !documentMutationInFlight, !slicing else { return }
        guard let tmp = ImportSupport.copyIntoSandbox(url) else {
            engineStatus = "import: copy into sandbox failed"
            return
        }
        let name = url.lastPathComponent
        documentMutationInFlight = true
        engineStatus = "\(name): loading…"
        Task { @MainActor in
            let outcome = await Task.detached(priority: .userInitiated) {
                do {
                    let mutation = try plater.apply(.importModel(path: tmp.path))
                    guard let objectID = mutation.createdObjectID,
                          let object = mutation.snapshot.object(id: objectID) else {
                        return ImportSupport.Outcome(
                            status: "import FAILED: created object is absent from snapshot",
                            mutation: nil
                        )
                    }
                    let dimensions = object.mesh.bounds.size
                    let line = "\(name) · \(object.mesh.indices.count / 3) tris · " +
                        String(
                            format: "%.0f×%.0f×%.0f mm",
                            dimensions.x,
                            dimensions.y,
                            dimensions.z
                        )
                    return ImportSupport.Outcome(
                        status: line,
                        mutation: mutation
                    )
                } catch {
                    return ImportSupport.Outcome(
                        status: "import FAILED: \(error.localizedDescription)",
                        mutation: nil
                    )
                }
            }.value

            documentMutationInFlight = false
            if let mutation = outcome.mutation {
                install(mutation.snapshot)
                frameRequest += 1
            }
            engineStatus = outcome.status
        }
    }

    /// Documents/orcapad-data with user/default/ + system symlink → bundle.
    /// Bundle DIRECTORY resources aren't reachable via Bundle.url(forResource:)
    /// (iOS quirk) — the path is composed from bundleURL and verified with
    /// FileManager instead. Failure message is returned for screen + os_log.
    private func preparePresetDataDir() -> (dataDir: String?, failure: String?) {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dataDir = docs.appendingPathComponent("orcapad-data", isDirectory: true)
        do {
            try fm.createDirectory(at: dataDir.appendingPathComponent("user/default", isDirectory: true),
                                   withIntermediateDirectories: true)
            let systemLink = dataDir.appendingPathComponent("system")
            // The symlink MUST be recreated every launch: the app bundle
            // path changes UUID on every xtool install, leaving the old
            // link dangling (fileExists reports false for dangling links,
            // which made createSymbolicLink throw "already exists").
            if (try? fm.destinationOfSymbolicLink(atPath: systemLink.path)) != nil {
                try fm.removeItem(at: systemLink)
            }
            let bundleSystem = Bundle.module.bundleURL
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent("system", isDirectory: true)
            guard fm.fileExists(atPath: bundleSystem.path) else {
                let msg = "presets FAILED: no system profiles at \(bundleSystem.path)"
                presetsLogger.fault("\(msg, privacy: .public)")
                return (nil, msg)
            }
            try fm.createSymbolicLink(at: systemLink, withDestinationURL: bundleSystem)
            return (dataDir.path, nil)
        } catch {
            let msg = "presets FAILED: data-dir prep: \(error.localizedDescription)"
            presetsLogger.fault("\(msg, privacy: .public)")
            return (nil, msg)
        }
    }

    // MARK: - Instance ops

    private func addInstance(to objectID: ObjectID) {
        runMutation(
            .addInstance(objectID: objectID),
            operation: "add instance"
        ) { mutation in
            if let instanceID = mutation.createdInstanceID {
                selection = (objectID, instanceID)
            }
        }
    }

    private func deleteInstance(_ instanceID: InstanceID, of objectID: ObjectID) {
        runMutation(
            .deleteInstance(objectID: objectID, instanceID: instanceID),
            operation: "delete instance"
        )
    }

    private func deleteObject(_ objectID: ObjectID) {
        runMutation(.deleteObject(objectID), operation: "delete object")
    }

    private func deleteObjects(_ objectIDs: [ObjectID]) {
        guard let plater, !documentMutationInFlight, !slicing else {
            engineStatus = "delete objects blocked: document is busy"
            return
        }
        documentMutationInFlight = true
        Task { @MainActor in
            let outcome = await Task.detached(priority: .userInitiated) {
                var latest: EnginePlater.MutationResult?
                for objectID in objectIDs {
                    do {
                        latest = try plater.apply(.deleteObject(objectID))
                    } catch {
                        return DocumentMutationTaskOutcome(
                            mutation: latest,
                            failure: error.localizedDescription
                        )
                    }
                }
                return DocumentMutationTaskOutcome(
                    mutation: latest,
                    failure: nil
                )
            }.value
            documentMutationInFlight = false
            if let mutation = outcome.mutation {
                install(mutation.snapshot)
            }
            if let failure = outcome.failure {
                engineStatus = "delete objects FAILED: \(failure)"
            }
        }
    }

    private func runMutation(
        _ mutation: EnginePlater.Mutation,
        operation: String,
        onSuccess: @escaping (EnginePlater.MutationResult) -> Void = { _ in }
    ) {
        guard let plater, !documentMutationInFlight, !slicing else {
            engineStatus = "\(operation) blocked: document is busy"
            return
        }
        documentMutationInFlight = true
        Task { @MainActor in
            let outcome = await Task.detached(priority: .userInitiated) {
                do {
                    return DocumentMutationTaskOutcome(
                        mutation: try plater.apply(mutation),
                        failure: nil
                    )
                } catch {
                    return DocumentMutationTaskOutcome(
                        mutation: nil,
                        failure: error.localizedDescription
                    )
                }
            }.value
            documentMutationInFlight = false
            if let mutation = outcome.mutation {
                install(mutation.snapshot)
                onSuccess(mutation)
            } else if let failure = outcome.failure {
                previewTransform = nil
                presentationRevision += 1
                engineStatus = "\(operation) FAILED: \(failure)"
            }
        }
    }

    // MARK: - Move / rotate (selected instance)

    private func moveSelected(by delta: SIMD2<Float>) {
        guard !documentMutationInFlight,
              !slicing,
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

    private func commitSelectedTransform() {
        commitTransform()
    }

    private func rotateSelected(by degrees: Double) {
        guard !documentMutationInFlight,
              !slicing,
              let selection,
              let authoritative = scene?.instance(
                  objectID: selection.objectID,
                  instanceID: selection.instanceID
              )?.transform else { return }
        var transform = previewTransform ?? authoritative
        transform.rotationZ += degrees * .pi / 180
        previewTransform = transform
        presentationRevision += 1
        commitTransform()
    }

    private func commitTransform() {
        guard let selection,
              let authoritative = scene?.instance(
                  objectID: selection.objectID,
                  instanceID: selection.instanceID
              )?.transform else { return }
        let transform = previewTransform ?? authoritative
        runMutation(
            .setTransform(
                objectID: selection.objectID,
                instanceID: selection.instanceID,
                transform: transform
            ),
            operation: "transform"
        )
    }

    private func install(_ authoritativeScene: SceneSnapshot) {
        if let current = scene,
           current.documentID == authoritativeScene.documentID,
           authoritativeScene.revision < current.revision {
            previewTransform = nil
            presentationRevision += 1
            engineStatus = "snapshot rejected: stale revision " +
                "\(authoritativeScene.revision.rawValue) < \(current.revision.rawValue)"
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

    // MARK: - Slice flow

    private func sliceTapped() {
        guard let plater,
              let scene,
              !scene.objects.isEmpty,
              !documentMutationInFlight,
              !slicing else { return }
        let name = scene.objects.first?.name.isEmpty == false
            ? scene.objects[0].name
            : "plater"
        let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]
        let gcodeDirectory = documents.appendingPathComponent(
            "G-code",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: gcodeDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            engineStatus = "slice FAILED: \(error.localizedDescription)"
            return
        }
        let gcodePath = gcodeDirectory.appendingPathComponent(
            (name as NSString).deletingPathExtension + ".gcode"
        ).path
        let count = scene.objects.reduce(0) { $0 + $1.instances.count }
        slicing = true

        Task { @MainActor in
            let presetText = presets != nil
                ? ""
                : " (defaults — presets unavailable)"
            engineStatus = "\(count) instance(s): slicing…\(presetText)"
            let outcome = await Task.detached(priority: .userInitiated) { [presets] in
                do {
                    let result: SliceResult
                    if let presets {
                        result = try plater.slice(
                            to: gcodePath,
                            presets: presets
                        ) { percent, message in
                            Task { @MainActor in
                                engineStatus = "\(count) instance(s): \(percent)% \(message)"
                            }
                        }
                    } else {
                        result = try plater.slice(to: gcodePath) { percent, message in
                            Task { @MainActor in
                                engineStatus = "\(count) instance(s): \(percent)% \(message)"
                            }
                        }
                    }
                    return SliceTaskOutcome(result: result, failure: nil)
                } catch {
                    return SliceTaskOutcome(
                        result: nil,
                        failure: error.localizedDescription
                    )
                }
            }.value
            slicing = false
            if let failure = outcome.failure {
                engineStatus = "slice FAILED: \(failure)"
            } else if let result = outcome.result {
                let minutes = Int(result.timeEstimateSeconds / 60)
                let kilobytes = result.gcodeBytes / 1024
                engineStatus = "\(count) instance(s): G-code ready\n" +
                    "\(kilobytes) KB · ~\(minutes) min print · " +
                    "Files → On My iPhone → OrcaPad"
            }
        }
    }

    // MARK: - Selection HUD

    @ViewBuilder
    private func selectionHUD(
        for selection: (objectID: ObjectID, instanceID: InstanceID),
        object: SceneObject
    ) -> some View {
        let ordinal = (object.instances.firstIndex {
            $0.id == selection.instanceID
        } ?? 0) + 1
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text(object.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text("instance \(ordinal)/\(object.instances.count) · drag to move")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 160, alignment: .leading)
            Divider().frame(height: 30)
            HUDButton(symbol: "rotate.left", label: "−45°") { rotateSelected(by: -45) }
            HUDButton(symbol: "rotate.left", label: "−15°") { rotateSelected(by: -15) }
            HUDButton(symbol: "rotate.right", label: "+15°") { rotateSelected(by: 15) }
            HUDButton(symbol: "rotate.right", label: "+45°") { rotateSelected(by: 45) }
            Divider().frame(height: 30)
            HUDButton(symbol: "plus.rectangle.on.rectangle", label: "Copy") {
                addInstance(to: selection.objectID)
            }
            HUDButton(symbol: "trash", label: "Del inst") {
                if object.instances.count > 1 {
                    deleteInstance(selection.instanceID, of: selection.objectID)
                } else {
                    deleteObject(selection.objectID)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Objects sheet

    private var objectsList: some View {
        let objects = scene?.objects ?? []
        return NavigationStack {
            Group {
                if objects.isEmpty {
                    Text("No objects — import an STL")
                        .foregroundStyle(.secondary)
                } else {
                    List {
                        ForEach(objects) { obj in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(obj.name).lineLimit(1)
                                    Text("\(obj.instances.count) instance(s)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button { addInstance(to: obj.id) } label: {
                                    Image(systemName: "plus.rectangle.on.rectangle")
                                }
                                .buttonStyle(.borderless)
                                Button { deleteObject(obj.id) } label: {
                                    Image(systemName: "trash")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.borderless)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if let instanceID = obj.instances.first?.id {
                                    selection = (obj.id, instanceID)
                                    previewTransform = nil
                                    presentationRevision += 1
                                }
                                objectsPresented = false
                            }
                        }
                        .onDelete { indexSet in
                            let objectIDs = indexSet.map { objects[$0].id }
                            deleteObjects(objectIDs)
                        }
                    }
                }
            }
            .navigationTitle("Objects")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { objectsPresented = false }
                }
            }
        }
    }

    // MARK: - Toolbar

    private var platerToolbar: some View {
        HStack(spacing: 22) {
            ToolbarButton(
                symbol: "plus",
                label: "Import",
                disabled: documentMutationInFlight
            ) { importPresented = true }
            ToolbarButton(
                symbol: "list.bullet",
                label: "Objects",
                disabled: scene?.objects.isEmpty != false || documentMutationInFlight
            ) { objectsPresented = true }
            ToolbarButton(symbol: "arrow.2.circlepath", label: "Arrange",
                          disabled: true) {
                // Phase 2: engine arrange (Arrange.cpp + libnest2d)
            }
            ToolbarButton(symbol: "scissors",
                          label: slicing ? "Slicing" : "Slice",
                          disabled: scene?.objects.isEmpty != false ||
                              documentMutationInFlight || slicing) {
                sliceTapped()
            }
            ToolbarButton(symbol: "gearshape", label: "Settings",
                          disabled: presets == nil) {
                settingsPresented = true
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

private struct DocumentMutationTaskOutcome: Sendable {
    let mutation: EnginePlater.MutationResult?
    let failure: String?
}

private struct SliceTaskOutcome: Sendable {
    let result: SliceResult?
    let failure: String?
}

// MARK: - Import support (pure statics — no view capture, Sendable-safe)

private enum ImportSupport {
    static let stlTypes: [UTType] = [UTType(filenameExtension: "stl") ?? .data]

    struct Outcome: Sendable {
        let status: String
        let mutation: EnginePlater.MutationResult?
    }

    /// Security-scoped read + copy into the app sandbox (Swift owns paths).
    static func copyIntoSandbox(_ url: URL) -> URL? {
        let gotScope = url.startAccessingSecurityScopedResource()
        defer { if gotScope { url.stopAccessingSecurityScopedResource() } }
        do {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("import.stl")
            if FileManager.default.fileExists(atPath: tmp.path) {
                try FileManager.default.removeItem(at: tmp)
            }
            try FileManager.default.copyItem(at: url, to: tmp)
            return tmp
        } catch {
            return nil
        }
    }
}

// MARK: - Toolbar buttons

private struct ToolbarButton: View {
    let symbol: String
    let label: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .medium))
                Text(label)
                    .font(.caption2)
            }
            .frame(minWidth: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(disabled ? .secondary : .primary)
        .environment(\.isEnabled, !disabled)
    }
}

private struct HUDButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                Text(label)
                    .font(.system(size: 9))
            }
            .frame(minWidth: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
