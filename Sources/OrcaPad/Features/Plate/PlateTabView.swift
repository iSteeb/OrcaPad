import OrcaBridge
import SwiftUI
import UniformTypeIdentifiers

/// Plate tab: the pre-slice 3D view (desktop parity). A left gizmo toolbar
/// picks the one-finger manipulation (Move / Rotate / Scale), the selected
/// instance shows an on-canvas gizmo, and the Object manipulation panel
/// offers exact numeric entry. Presentation-only — document state belongs
/// to the AppEnvironment stores.
struct PlateTabView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var importPresented = false
    @State private var importMode: ImportMode = .model
    @State private var replaceConfirmation: URL?
    @State private var savePresented = false
    @State private var projectName = ""
    @State private var objectsPresented = false
    @State private var gizmoMode: GizmoMode = .move
    @State private var rotationAxis: EngineAxis = .z
    @State private var renameTarget: RenameTarget?
    @State private var settingsTarget: SettingsTarget?
    @State private var countTarget: CountPrompt?
    @State private var countText = ""
    @State private var renameText = ""
    @State private var deleteAllConfirmation = false

    private var document: DocumentStore { environment.document }

    private var bed: EngineBed {
        environment.presets.printVolume.map(EngineBed.init) ?? EngineBed.fallback
    }

    var body: some View {
        ZStack {
            canvas.ignoresSafeArea()

            HStack(alignment: .center) {
                GizmoToolbar(
                    mode: $gizmoMode,
                    hasSelection: document.selection != nil,
                    isBusy: document.isBusy,
                    onDuplicate: duplicateSelection,
                    onDelete: deleteSelection
                )
                .padding(.leading, 12)
                Spacer()
            }

            VStack {
                HStack {
                    Spacer()
                    fileActions
                }
                .padding(.trailing, 12)
                .padding(.top, 8)
                Spacer()
                if let selection = document.selection,
                   let object = document.scene?.object(id: selection.objectID),
                   let transform = document.selectedDisplayTransform {
                    ManipulationPanel(
                        mode: gizmoMode,
                        header: PanelHeader(
                            name: object.name,
                            instanceOrdinal: (object.instances.firstIndex { $0.id == selection.instanceID } ?? 0) + 1,
                            instanceCount: object.instances.count,
                            size: document.selectedSize ?? .zero,
                            selectionCount: document.selectedGroup.count
                        ),
                        transform: transform,
                        meshSize: object.mesh.bounds.size,
                        bedCenter: SIMD2(Double(bed.center.x), Double(bed.center.y)),
                        rotationAxis: $rotationAxis,
                        isBusy: document.isBusy,
                        actions: ManipulationActions(
                            setTransform: { newTransform, label in
                                Task { await document.setSelectedTransform(newTransform, label: label) }
                            },
                            rotate: { axis, degrees in
                                Task { await document.rotateSelected(axis: axis, degrees: degrees) }
                            },
                            resetRotation: {
                                Task { await document.resetRotation() }
                            }
                        )
                    )
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
            }
        }
        .fileImporter(
            isPresented: $importPresented,
            allowedContentTypes: importMode == .project ? ImportTypes.projects : ImportTypes.models,
            onCompletion: handleImport
        )
        .sheet(isPresented: $objectsPresented) { objectsList }
        .confirmationDialog(
            "Open project?",
            isPresented: Binding(
                get: { replaceConfirmation != nil },
                set: { if !$0 { replaceConfirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Replace current plate", role: .destructive) {
                if let url = replaceConfirmation {
                    Task { await environment.openProject(url) }
                }
                replaceConfirmation = nil
            }
        } message: {
            Text("Opening a project replaces the objects on the plate and loads the project's printer, filament and process settings. Unsaved changes are lost.")
        }
        .alert("Save project", isPresented: $savePresented) {
            TextField("Project name", text: $projectName)
            Button("Save") {
                let name = projectName
                Task { await environment.saveProject(named: name) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saved as a 3MF project in Files ▸ OrcaPad ▸ Projects (opens in OrcaSlicer and Bambu Studio).")
        }
    }

    private enum ImportMode: Equatable {
        case model
        case project
        /// Desktop "Load..." subobject: a file added as one volume.
        case volume(role: VolumeRole, objectID: ObjectID)
    }

    // MARK: Canvas

    @ViewBuilder
    private var canvas: some View {
        if let scene = document.scene {
            MetalCanvas(
                onStatus: { environment.status.report(.renderer, $0) },
                scene: SceneSync(
                    snapshot: scene,
                    bed: bed,
                    selectedObjectID: document.selection?.objectID,
                    selectedInstanceID: document.selection?.instanceID,
                    highlightedInstanceIDs: Set(document.selectedGroup.map(\.instanceID)),
                    previewMatrices: document.previewMatrices,
                    presentationRevision: document.presentationRevision,
                    frameRequest: document.frameRequest,
                    cameraRequest: (document.cameraRequestID, document.cameraPreset),
                    gizmoMode: gizmoMode,
                    rotationAxis: rotationAxis
                ),
                manipulation: CanvasManipulation(
                    onSelect: { document.select(objectID: $0, instanceID: $1) },
                    onToggleSelect: { document.toggleSelect(objectID: $0, instanceID: $1) },
                    onMove: { document.moveSelected(by: $0) },
                    onBegin: { document.beginManipulation() },
                    onRotate: { document.previewRotation(axis: rotationAxis, deltaRadians: $0) },
                onScale: { document.previewScale(factor: $0) },
                onLayFlat: { normal in
                    guard let engine = environment.presets.engineForSlicing else {
                        environment.status.report(
                            .document,
                            failure: .invariant(
                                operation: "lay flat",
                                diagnostic: "presets are not loaded"
                            )
                        )
                        return
                    }
                    Task { await document.layFlatSelected(normal: normal, presets: engine) }
                },
                onEnd: { Task { await document.commitSelectedTransform() } }
                )
            )
        } else {
            Color(red: 0.075, green: 0.078, blue: 0.093)
        }
    }

    // MARK: File / object actions (top-right)

    private var fileActions: some View {
        HStack(spacing: 4) {
            PlateActionButton(
                symbol: "arrow.uturn.backward",
                label: "Undo",
                disabled: document.history?.canUndo != true || document.isBusy
            ) {
                Task { await document.undo() }
            }
            .keyboardShortcut("z", modifiers: .command)
            .accessibilityHint(document.history.map { "Undo \($0.undoLabel)" } ?? "")
            PlateActionButton(
                symbol: "arrow.uturn.forward",
                label: "Redo",
                disabled: document.history?.canRedo != true || document.isBusy
            ) {
                Task { await document.redo() }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .accessibilityHint(document.history.map { "Redo \($0.redoLabel)" } ?? "")
            Divider().frame(height: 28)
            Menu {
                Button {
                    importMode = .model
                    importPresented = true
                } label: {
                    Label("Import model…", systemImage: "plus.square")
                }
                Menu {
                    ForEach(CameraViewPreset.allCases) { preset in
                        Button(preset.rawValue) {
                            document.applyCameraView(preset)
                        }
                    }
                } label: {
                    Label("View", systemImage: "camera")
                }
                Menu {
                    ForEach(
                        PrimitiveShape.allCases.filter(\.isObjectShape),
                        id: \.self
                    ) { shape in
                        Button(shape.label) {
                            Task {
                                await document.addShapeObject(
                                    shape: shape,
                                    sizeMM: shapeSize,
                                    bedCenter: bedCenter
                                )
                            }
                        }
                    }
                } label: {
                    Label("Add shape", systemImage: "cube")
                }
                Divider()
                Button {
                    importMode = .project
                    importPresented = true
                } label: {
                    Label("Open project…", systemImage: "folder")
                }
                Button {
                    projectName = defaultProjectName
                    savePresented = true
                } label: {
                    Label("Save project…", systemImage: "square.and.arrow.down")
                }
                .disabled(document.scene?.objects.isEmpty != false)
                if let project = document.lastSavedProject {
                    ShareLink(item: project) {
                        Label("Share \(project.lastPathComponent)", systemImage: "square.and.arrow.up")
                    }
                }
                Divider()
                Button {
                    Task { await document.copySelected() }
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .disabled(document.selection == nil)
                .keyboardShortcut("c", modifiers: .command)
                Button {
                    Task {
                        await document.pasteObject(bedCenter: bedCenter)
                    }
                } label: {
                    Label("Paste", systemImage: "clipboard")
                }
                .disabled(document.isBusy)
                .keyboardShortcut("v", modifiers: .command)
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 17, weight: .medium))
                    Text("File")
                        .font(.system(size: 9))
                }
                .frame(minWidth: 52, minHeight: 40)
                .contentShape(Rectangle())
            }
            .foregroundStyle(document.isBusy ? .secondary : .primary)
            .disabled(document.isBusy)
            PlateActionButton(
                symbol: "list.bullet",
                label: "Objects",
                disabled: document.scene?.objects.isEmpty != false || document.isMutating
            ) {
                objectsPresented = true
            }
            PlateActionButton(
                symbol: "square.grid.3x3", label: "Arrange",
                disabled: document.scene?.objects.isEmpty != false || document.isMutating
            ) {
                guard let engine = environment.presets.engineForSlicing else { return }
                Task { await document.arrangeAll(presets: engine, allowRotations: false) }
            }
            PlateActionButton(
                symbol: "location.north.circle", label: "Orient",
                disabled: document.scene?.objects.isEmpty != false || document.isMutating
            ) {
                guard let engine = environment.presets.engineForSlicing else { return }
                Task { await document.orientAll(presets: engine) }
            }
        }
        .padding(6)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func duplicateSelection() {
        guard let selection = document.selection else { return }
        Task { await document.addInstance(to: selection.objectID) }
    }

    private func deleteSelection() {
        if document.hasMultiSelection {
            Task { await document.deleteSelectedGroup() }
            return
        }
        guard let selection = document.selection,
              let object = document.scene?.object(id: selection.objectID) else { return }
        Task {
            if object.instances.count > 1 {
                await document.deleteInstance(selection.instanceID, of: selection.objectID)
            } else {
                await document.deleteObject(selection.objectID)
            }
        }
    }

    private var bedCenter: SIMD2<Double> {
        SIMD2(Double(bed.center.x), Double(bed.center.y))
    }

    /// Desktop get_size_proportional_to_max_bed_size(0.1).
    private var shapeSize: Double {
        max(Double(bed.size.x), Double(bed.size.y)) * 0.1
    }

    private var defaultProjectName: String {
        let first = document.scene?.objects.first?.name ?? ""
        let base = (first as NSString).deletingPathExtension
        return base.isEmpty ? "OrcaPad project" : base
    }

    private func handleImport(_ result: Result<URL, any Error>) {
        if case .volume(let role, let objectID) = importMode,
            case .success(let url) = result {
            Task { await document.addVolume(from: url, role: role, objectID: objectID) }
            return
        }
        if importMode == .project, case .success(let url) = result {
            if document.scene?.objects.isEmpty == false {
                replaceConfirmation = url
            } else {
                Task { await environment.openProject(url) }
            }
            return
        }
        switch result {
        case .success(let url):
            Task {
                if !document.isReady {
                    await environment.bootstrap()
                }
                guard document.isReady else { return }
                let bedCenter = environment.presets.printVolume.map {
                    SIMD2<Double>($0.centerX, $0.centerY)
                } ?? .zero
                await document.importModel(from: url, bedCenter: bedCenter)
            }
        case .failure(let error):
            environment.status.report(
                .document,
                failure: AppFailure.wrap(error, operation: "choose import file")
            )
        }
    }

    // MARK: Objects sheet

    private var objectsList: some View {
        let objects = document.scene?.objects ?? []
        return NavigationStack {
            Group {
                if objects.isEmpty {
                    Text("No objects — import a model (STL, OBJ, AMF, 3MF)")
                        .foregroundStyle(.secondary)
                } else {
                    List {
                        ForEach(objects) { object in
                            objectRow(object)
                        }
                        .onDelete { indexSet in
                            let objectIDs = indexSet.map { objects[$0].id }
                            Task { await document.deleteObjects(objectIDs) }
                        }
                    }
                }
            }
            .navigationTitle("Objects")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { objectsPresented = false }
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button(role: .destructive) {
                        deleteAllConfirmation = true
                    } label: {
                        Label("Delete all", systemImage: "trash.slash")
                    }
                    .disabled(objects.isEmpty || document.isBusy)
                }
                ToolbarItem(placement: .topBarLeading) {
                    if document.hasMultiSelection {
                        HStack {
                            Button("Clear selection") { document.clearMultiSelection() }
                            Button("Assemble") {
                                Task { await document.assembleSelection() }
                            }
                            .disabled(document.isBusy)
                        }
                    } else {
                        Button("Select all") { document.selectAll() }
                            .disabled(objects.isEmpty)
                    }
                }
            }
            .alert("Rename", isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )) {
                TextField("Name", text: $renameText)
                Button("Rename") {
                    if let target = renameTarget {
                        let name = renameText
                        Task {
                            switch target {
                            case .object(let objectID):
                                await document.rename(objectID, to: name)
                            case .volume(let objectID, let volumeID):
                                await document.renameVolume(
                                    volumeID, to: name, objectID: objectID
                                )
                            }
                        }
                    }
                    renameTarget = nil
                }
                Button("Cancel", role: .cancel) { renameTarget = nil }
            }
            .alert(
                countTarget?.kind == .clones ? "Clone object" : "Number of instances",
                isPresented: Binding(
                    get: { countTarget != nil },
                    set: { if !$0 { countTarget = nil } }
                )
            ) {
                TextField("Count", text: $countText)
                    .keyboardType(.numberPad)
                if let target = countTarget {
                    if target.kind == .clones {
                        Button("Clone") { runCount(target, arrange: false) }
                        Button("Clone and arrange") { runCount(target, arrange: true) }
                    } else {
                        Button("Set") { runCount(target, arrange: false) }
                    }
                }
                Button("Cancel", role: .cancel) { countTarget = nil }
            }
            .sheet(item: $settingsTarget) { target in
                ObjectSettingsSheet(
                    objectID: target.objectID,
                    volumeID: target.volumeID,
                    title: target.title
                )
            }
            .confirmationDialog(
                "Delete all objects?",
                isPresented: $deleteAllConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete all", role: .destructive) {
                    Task { await document.deleteAll() }
                }
            } message: {
                Text("Removes every object from the plate. You can undo this.")
            }
        }
    }
}

extension PlateTabView {
    /// One object row: identity, instances, per-object actions (desktop
    /// object-list context menu) and, when composed of several volumes,
    /// the volume rows.
    @ViewBuilder
    private func objectRow(_ object: SceneObject) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if document.hasMultiSelection {
                    Image(systemName: isMultiSelected(object)
                          ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isMultiSelected(object) ? Color.accentColor : .secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(object.name).lineLimit(1)
                    Text(object.volumes.count > 1
                         ? "\(object.volumes.count) volumes · \(object.instances.count) instance(s)"
                         : "\(object.instances.count) instance(s)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if object.overrideCount > 0 {
                    Label("\(object.overrideCount)", systemImage: "slider.horizontal.3")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                        .accessibilityLabel("\(object.overrideCount) setting overrides")
                }
                if object.nonPartVolumes.isEmpty == false {
                    Circle()
                        .fill(roleColor(object.nonPartVolumes[0].role))
                        .frame(width: 8, height: 8)
                        .accessibilityLabel("Has modifiers")
                }
                Button {
                    Task { await document.addInstance(to: object.id) }
                } label: {
                    Image(systemName: "plus.square.on.square")
                }
                .buttonStyle(.borderless)
                Button {
                    Task { await document.deleteObject(object.id) }
                } label: {
                    Image(systemName: "trash").foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                objectMenu(object)
            }
            if object.volumes.count > 1 || object.nonPartVolumes.isEmpty == false {
                ForEach(object.volumes) { volume in
                    volumeRow(volume, objectID: object.id)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if document.hasMultiSelection, let instanceID = object.instances.first?.id {
                document.toggleSelect(objectID: object.id, instanceID: instanceID)
                return
            }
            document.select(
                objectID: object.id,
                instanceID: object.instances.first?.id
            )
            objectsPresented = false
        }
        .onLongPressGesture {
            if let instanceID = object.instances.first?.id {
                document.toggleSelect(objectID: object.id, instanceID: instanceID)
            }
        }
    }

    /// Runs a count prompt (desktop "Set number of instances" / Clone).
    private func runCount(_ target: CountPrompt, arrange: Bool) {
        countTarget = nil
        guard let count = Int(countText.trimmingCharacters(in: .whitespaces)), count >= 1 else {
            environment.status.report(.document, failure: .invariant(
                operation: target.kind == .clones ? "clone" : "set number of instances",
                diagnostic: "\"\(countText)\" is not a positive whole number"))
            return
        }
        Task {
            switch target.kind {
            case .instances:
                await document.setInstanceCount(objectID: target.objectID, count: count)
            case .clones:
                await document.cloneObject(
                    objectID: target.objectID, count: count,
                    arrangeWith: arrange ? environment.presets.engineForSlicing : nil)
            }
        }
    }

    private func isMultiSelected(_ object: SceneObject) -> Bool {
        document.selectedGroup.contains { $0.objectID == object.id }
    }

    /// Desktop object context menu: split, add volumes, rename.
    private func objectMenu(_ object: SceneObject) -> some View {
        Menu {
            Button {
                Task { await document.splitToObjects(object.id) }
            } label: {
                Label("Split to objects", systemImage: "arrow.triangle.branch")
            }
            .disabled(object.volumes.isEmpty)
            Button {
                let partID = object.modelParts.count == 1
                    ? object.modelParts.first?.id : nil
                Task { await document.splitToParts(object.id, volumeID: partID) }
            } label: {
                Label("Split to parts", systemImage: "square.split.2x1")
            }
            .disabled(object.modelParts.isEmpty)
            Divider()
            ForEach([VolumeRole.part, .negative, .modifier, .supportBlocker, .supportEnforcer], id: \.self) { role in
                volumeAddMenu(role: role, object: object)
            }
            Divider()
            Menu {
                ForEach(EngineAxis.allCases, id: \.self) { axis in
                    Button("\(axis.label) axis") {
                        guard let instanceID = object.instances.first?.id else { return }
                        Task {
                            await document.mirrorObject(
                                objectID: object.id, instanceID: instanceID, axis: axis
                            )
                        }
                    }
                }
            } label: {
                Label("Mirror", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
            }
            Divider()
            let printable = object.instances.allSatisfy(\.printable)
            Button {
                Task {
                    await document.setPrintable(
                        objectID: object.id, instanceID: nil, printable: !printable)
                }
            } label: {
                Label(printable ? "Printable" : "Not printable",
                      systemImage: printable ? "checkmark.square" : "square")
            }
            Button {
                countText = "\(object.instances.count)"
                countTarget = CountPrompt(kind: .instances, objectID: object.id)
            } label: {
                Label("Set number of instances…", systemImage: "number")
            }
            Button {
                countText = "1"
                countTarget = CountPrompt(kind: .clones, objectID: object.id)
            } label: {
                Label("Clone…", systemImage: "square.on.square")
            }
            Button {
                let instanceID = document.selection?.objectID == object.id
                    ? document.selection?.instanceID : object.instances.last?.id
                guard let instanceID else { return }
                Task { await document.separateInstance(objectID: object.id, instanceID: instanceID) }
            } label: {
                Label("Set as an individual object", systemImage: "square.and.arrow.up.on.square")
            }
            .disabled(object.instances.count < 2)
            Button {
                guard let engine = environment.presets.engineForSlicing,
                      let instanceID = object.instances.first?.id else { return }
                Task {
                    await document.scaleToFit(
                        objectID: object.id, instanceID: instanceID, presets: engine)
                }
            } label: {
                Label("Scale to build volume", systemImage: "arrow.up.left.and.arrow.down.right.square")
            }
            Menu {
                ForEach(UnitConversion.allCases, id: \.self) { conversion in
                    Button(conversion.label) {
                        Task { await document.convertUnits(objectID: object.id, conversion: conversion) }
                    }
                }
            } label: {
                Label("Convert units", systemImage: "ruler")
            }
            Divider()
            Button {
                settingsTarget = SettingsTarget(
                    objectID: object.id, volumeID: nil, title: object.name)
            } label: {
                Label("Edit process settings…", systemImage: "slider.horizontal.3")
            }
            Button {
                renameText = object.name
                renameTarget = .object(object.id)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .disabled(document.isBusy)
    }

    /// Desktop "Add Part / Modifier / Negative volume / Support blocker /
    /// Support enforcer": from a shape or from a file.
    private func volumeAddMenu(role: VolumeRole, object: SceneObject) -> some View {
        Menu {
            ForEach(PrimitiveShape.allCases, id: \.self) { shape in
                Button("\(shape.label)\(shape == .slab ? " (modifier)" : "")") {
                    guard let instanceID = object.instances.first?.id else {
                        environment.status.report(
                            .document,
                            failure: .invariant(
                                operation: "add volume",
                                diagnostic: "object \(object.name) has no instance"
                            )
                        )
                        return
                    }
                    Task {
                        await document.addVolume(
                            role: role,
                            shape: shape,
                            sizeMM: shapeSize,
                            objectID: object.id,
                            instanceID: instanceID
                        )
                    }
                }
            }
            Divider()
            Button("From file…") {
                importMode = .volume(role: role, objectID: object.id)
                importPresented = true
            }
        } label: {
            Label("Add \(role.label.lowercased())", systemImage: "plus.square.on.square")
        }
    }

    private func roleColor(_ role: VolumeRole) -> Color {
        let c = Renderer.volumeColor(role)
        return Color(
            red: Double(c.x), green: Double(c.y), blue: Double(c.z),
            opacity: Double(c.w)
        )
    }

    /// One volume row: role color, name, type and per-volume actions.
    private func volumeRow(_ volume: SceneVolume, objectID: ObjectID) -> some View {
        HStack(spacing: 8) {
            Image(systemName: volume.role.symbol)
                .foregroundStyle(roleColor(volume.role))
                .font(.caption)
            Text(volume.name)
                .font(.caption)
                .lineLimit(1)
            if volume.extruder > 0 {
                Text("T\(volume.extruder)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            if volume.overrideCount > 0 {
                Label("\(volume.overrideCount)", systemImage: "slider.horizontal.3")
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
            }
            Spacer()
            Menu {
                Button {
                    settingsTarget = SettingsTarget(
                        objectID: objectID, volumeID: volume.id, title: volume.name)
                } label: {
                    Label("Edit settings…", systemImage: "slider.horizontal.3")
                }
                .disabled(volume.role == .negative)
                Button {
                    renameText = volume.name
                    renameTarget = .volume(objectID, volume.id)
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                if volume.role != .part {
                    Menu {
                        ForEach(VolumeRole.allCases, id: \.self) { role in
                            Button(role.label) {
                                Task {
                                    await document.setVolumeType(
                                        role, volumeID: volume.id, objectID: objectID
                                    )
                                }
                            }
                        }
                    } label: {
                        Label("Change type", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                Button(role: .destructive) {
                    Task {
                        await document.deleteVolume(volume.id, objectID: objectID)
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.caption)
            }
            .disabled(document.isBusy)
        }
        .padding(.leading, 16)
    }
}

/// Count prompt routing (instances / clones).
private struct CountPrompt {
    enum Kind { case instances, clones }
    let kind: Kind
    let objectID: ObjectID
}

/// Settings sheet routing: an object (volumeID nil) or one of its volumes.
private struct SettingsTarget: Identifiable {
    let objectID: ObjectID
    let volumeID: VolumeID?
    let title: String

    var id: String { "\(objectID)-\(volumeID?.description ?? "object")" }
}

/// Rename routing: object or volume.
private enum RenameTarget {
    case object(ObjectID)
    case volume(ObjectID, VolumeID)
}

/// SF Symbol + role iconography for the object list (desktop parity).
private extension VolumeRole {
    var symbol: String {
        switch self {
        case .part: return "cube.fill"
        case .negative: return "minus.square.dashed"
        case .modifier: return "slider.horizontal.3"
        case .supportBlocker: return "hand.raised.fill"
        case .supportEnforcer: return "hand.thumbsup.fill"
        }
    }
}

// MARK: - Gizmo toolbar (left, desktop parity)

private struct GizmoToolbar: View {
    @Binding var mode: GizmoMode
    let hasSelection: Bool
    let isBusy: Bool
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            tool(.move, symbol: "arrow.up.and.down.and.arrow.left.and.right", label: "Move")
            tool(.rotate, symbol: "arrow.clockwise.circle", label: "Rotate")
            tool(.scale, symbol: "arrow.up.left.and.arrow.down.right", label: "Scale")
            tool(.layFlat, symbol: "square.bottomhalf.filled", label: "Lay flat")
            Divider().frame(width: 32)
            action("plus.square.on.square", label: "Copy", action: onDuplicate)
            action("trash", label: "Delete", action: onDelete)
            Divider().frame(width: 32)
            future("paintbrush.pointed", label: "Supports")
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private func tool(_ target: GizmoMode, symbol: String, label: String) -> some View {
        Button {
            mode = target
        } label: {
            toolLabel(symbol: symbol, label: label)
                .foregroundStyle(mode == target ? Color.accentColor : Color.primary)
                .background(
                    mode == target ? Color.accentColor.opacity(0.18) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 10)
                )
        }
        .buttonStyle(.plain)
    }

    private func action(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            toolLabel(symbol: symbol, label: label)
        }
        .buttonStyle(.plain)
        .disabled(!hasSelection || isBusy)
        .opacity(hasSelection && !isBusy ? 1 : 0.35)
    }

    private func future(_ symbol: String, label: String) -> some View {
        toolLabel(symbol: symbol, label: label)
            .opacity(0.25)
            .accessibilityLabel("\(label) — coming later")
    }

    private func toolLabel(symbol: String, label: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
            Text(label)
                .font(.system(size: 9))
        }
        .frame(width: 52, height: 44)
        .contentShape(Rectangle())
    }
}

// MARK: - Object manipulation panels (desktop parity, one per gizmo mode)

private struct PanelHeader {
    let name: String
    let instanceOrdinal: Int
    let instanceCount: Int
    let size: SIMD3<Float>
    /// Members of a multi-selection (1 = single).
    var selectionCount = 1
}

private struct ManipulationActions {
    /// Absolute transform + the undo-step label ("Move", "Scale", ...).
    let setTransform: (InstanceTransform, String) -> Void
    let rotate: (EngineAxis, Double) -> Void
    let resetRotation: () -> Void
}

private struct ManipulationPanel: View {
    let mode: GizmoMode
    let header: PanelHeader
    let transform: InstanceTransform
    let meshSize: SIMD3<Float>
    let bedCenter: SIMD2<Double>
    @Binding var rotationAxis: EngineAxis
    let isBusy: Bool
    let actions: ManipulationActions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(header.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("instance \(header.instanceOrdinal)/\(header.instanceCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if header.selectionCount > 1 {
                    Text("+\(header.selectionCount - 1) selected")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
                Spacer()
                Text(String(format: "%.1f × %.1f × %.1f mm", header.size.x, header.size.y, header.size.z))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            switch mode {
            case .move: movePanel
            case .rotate: RotatePanel(transform: transform, axis: $rotationAxis, actions: actions)
            case .scale: ScalePanel(transform: transform, meshSize: meshSize, actions: actions)
            case .layFlat:
                Label(
                    "Tap a face of the object to lay it flat on that face.",
                    systemImage: "hand.tap"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .disabled(isBusy)
    }

    // Move: X / Y on the bed plane + center (Z is engine-managed: rests on bed).
    private var movePanel: some View {
        HStack(alignment: .bottom, spacing: 14) {
            NumericField(label: "X", unit: "mm", value: transform.offsetX, digits: 2) { value in
                var updated = transform; updated.offsetX = value; actions.setTransform(updated, "Move")
            }
            NumericField(label: "Y", unit: "mm", value: transform.offsetY, digits: 2) { value in
                var updated = transform; updated.offsetY = value; actions.setTransform(updated, "Move")
            }
            Button {
                var updated = transform
                updated.offsetX = bedCenter.x
                updated.offsetY = bedCenter.y
                actions.setTransform(updated, "Center")
            } label: {
                Label("Center on bed", systemImage: "scope")
            }
            .buttonStyle(.bordered)
            .font(.caption)
            Spacer()
        }
    }
}

/// Rotate: world-axis selector with an orientation glyph, ±15° engine steps
/// (wrapping through 360°), reset, and the engine's Euler readout.
private struct RotatePanel: View {
    let transform: InstanceTransform
    @Binding var axis: EngineAxis
    let actions: ManipulationActions

    static let step = 15.0

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            AxisGlyph(selected: axis)
                .frame(width: 70, height: 70)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    ForEach(EngineAxis.allCases, id: \.self) { candidate in
                        Button {
                            axis = candidate
                        } label: {
                            Text(candidate.label)
                                .font(.callout.weight(.semibold))
                                .frame(width: 40, height: 30)
                                .foregroundStyle(axis == candidate ? Color.white : candidate.color)
                                .background(
                                    axis == candidate ? candidate.color : candidate.color.opacity(0.15),
                                    in: RoundedRectangle(cornerRadius: 8)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack(spacing: 10) {
                    ForEach(EngineAxis.allCases, id: \.self) { candidate in
                        Text("\(candidate.label) \(Self.degrees(transform.rotation[Int(candidate.rawValue)]))°")
                            .font(.caption.monospaced())
                            .foregroundStyle(candidate == axis ? candidate.color : Color.secondary)
                    }
                }
            }
            Spacer()
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Button { actions.rotate(axis, -Self.step) } label: {
                        Label("−15°", systemImage: "arrow.counterclockwise")
                    }
                    Button { actions.rotate(axis, Self.step) } label: {
                        Label("+15°", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(axis.color)
                Button("Reset rotation", action: actions.resetRotation)
                    .buttonStyle(.bordered)
                    .font(.caption)
            }
        }
    }

    /// Engine Euler angle as a 0–359.9 display value.
    static func degrees(_ radians: Double) -> String {
        var value = (radians * 180 / .pi).truncatingRemainder(dividingBy: 360)
        if value < 0 { value += 360 }
        if value >= 359.95 { value = 0 }
        return String(format: "%.1f", value)
    }
}

/// Isometric axis triad with the selected axis emphasised and a rotation
/// arrow around it (desktop rotate-gizmo color convention).
private struct AxisGlyph: View {
    let selected: EngineAxis

    var body: some View {
        Canvas { context, size in
            let origin = CGPoint(x: size.width * 0.5, y: size.height * 0.62)
            let length = min(size.width, size.height) * 0.38
            let directions: [EngineAxis: CGVector] = [
                .x: CGVector(dx: 0.87, dy: 0.5),
                .y: CGVector(dx: -0.87, dy: 0.5),
                .z: CGVector(dx: 0, dy: -1),
            ]
            for axis in EngineAxis.allCases {
                guard let direction = directions[axis] else { continue }
                let tip = CGPoint(x: origin.x + direction.dx * length, y: origin.y + direction.dy * length)
                var path = Path()
                path.move(to: origin)
                path.addLine(to: tip)
                context.stroke(
                    path,
                    with: .color(axis.color.opacity(axis == selected ? 1 : 0.35)),
                    lineWidth: axis == selected ? 3.5 : 1.5
                )
            }
            // Rotation arrow: an ellipse around the selected axis' midpoint.
            guard let direction = directions[selected] else { return }
            let mid = CGPoint(x: origin.x + direction.dx * length * 0.55, y: origin.y + direction.dy * length * 0.55)
            let angle = atan2(direction.dy, direction.dx) + .pi / 2
            var arc = Path()
            arc.addArc(center: .zero, radius: length * 0.32, startAngle: .degrees(20), endAngle: .degrees(320), clockwise: false)
            let tipAngle = 320.0 * .pi / 180
            let arrowTip = CGPoint(x: cos(tipAngle) * length * 0.32, y: sin(tipAngle) * length * 0.32)
            arc.move(to: arrowTip)
            arc.addLine(to: CGPoint(x: arrowTip.x - 6, y: arrowTip.y - 2))
            arc.move(to: arrowTip)
            arc.addLine(to: CGPoint(x: arrowTip.x - 1, y: arrowTip.y + 6))
            let transform = CGAffineTransform(translationX: mid.x, y: mid.y)
                .rotated(by: angle)
                .scaledBy(x: 1, y: 0.45)
            context.stroke(arc.applying(transform), with: .color(selected.color), lineWidth: 2)
        }
    }
}

/// Scale: per-axis factors and sizes with a uniform lock (desktop parity).
private struct ScalePanel: View {
    let transform: InstanceTransform
    let meshSize: SIMD3<Float>
    let actions: ManipulationActions

    @State private var uniform = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Toggle(isOn: $uniform) {
                    Label("Uniform", systemImage: uniform ? "lock.fill" : "lock.open")
                }
                .toggleStyle(.button)
                .font(.caption)
                Button("100%") {
                    var updated = transform
                    updated.scaleX = 1; updated.scaleY = 1; updated.scaleZ = 1
                    actions.setTransform(updated, "Reset scale")
                }
                .buttonStyle(.bordered)
                .font(.caption)
                Spacer()
            }
            HStack(alignment: .bottom, spacing: 12) {
                Text("Scale").font(.caption).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
                ForEach(EngineAxis.allCases, id: \.self) { axis in
                    NumericField(
                        label: axis.label, unit: "%",
                        value: scale(axis) * 100, digits: 1,
                        minimum: 1, maximum: 10_000
                    ) { percent in
                        apply(axis: axis, newScale: percent / 100)
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 12) {
                Text("Size").font(.caption).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
                ForEach(EngineAxis.allCases, id: \.self) { axis in
                    let mesh = Double(meshSize[Int(axis.rawValue)])
                    NumericField(
                        label: axis.label, unit: "mm",
                        value: mesh * scale(axis), digits: 2,
                        minimum: 0.01, maximum: 100_000
                    ) { millimetres in
                        guard mesh > 0 else { return }
                        apply(axis: axis, newScale: millimetres / mesh)
                    }
                }
            }
        }
    }

    private func scale(_ axis: EngineAxis) -> Double {
        transform.scale[Int(axis.rawValue)]
    }

    private func apply(axis: EngineAxis, newScale: Double) {
        guard newScale.isFinite, newScale > 0 else { return }
        var updated = transform
        if uniform {
            let factor = newScale / scale(axis)
            updated.scaleX *= factor
            updated.scaleY *= factor
            updated.scaleZ *= factor
        } else {
            switch axis {
            case .x: updated.scaleX = newScale
            case .y: updated.scaleY = newScale
            case .z: updated.scaleZ = newScale
            }
        }
        actions.setTransform(updated, "Scale")
    }
}

private extension EngineAxis {
    var label: String {
        switch self {
        case .x: return "X"
        case .y: return "Y"
        case .z: return "Z"
        }
    }

    var color: Color {
        switch self {
        case .x: return Color(red: 0.95, green: 0.30, blue: 0.25)
        case .y: return Color(red: 0.35, green: 0.80, blue: 0.35)
        case .z: return Color(red: 0.30, green: 0.55, blue: 1.00)
        }
    }
}

/// Numeric text field committing on submit with range validation.
private struct NumericField: View {
    let label: String
    let unit: String
    let value: Double
    let digits: Int
    var minimum: Double = -.greatestFiniteMagnitude
    var maximum: Double = .greatestFiniteMagnitude
    let onCommit: (Double) -> Void

    @State private var draft = ""
    @State private var invalid = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 3) {
                TextField(label, text: $draft)
                    .onSubmit(submit)
                    .keyboardType(.numbersAndPunctuation)
                    .font(.callout.monospaced())
                    .frame(width: 76)
                    .textFieldStyle(.roundedBorder)
                    .foregroundStyle(invalid ? Color.red : Color.primary)
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { draft = formatted(value) }
        .onChange(of: value) { _, newValue in
            draft = formatted(newValue)
            invalid = false
        }
    }

    private func formatted(_ number: Double) -> String {
        String(format: "%.\(digits)f", number)
    }

    private func submit() {
        guard let parsed = Double(draft.trimmingCharacters(in: .whitespaces)),
              parsed.isFinite, parsed >= minimum, parsed <= maximum else {
            invalid = true
            return
        }
        invalid = false
        if formatted(parsed) != formatted(value) { onCommit(parsed) }
    }
}

private enum ImportTypes {
    /// Engine `Model::read_from_file` geometry formats compiled into the
    /// closure (STEP/SVG/DRC still need OCCT/draco).
    static let projects: [UTType] = ["3mf"].map { ext in
        guard let type = UTType(filenameExtension: ext, conformingTo: .data) else {
            preconditionFailure("iOS did not provide a content type for .\(ext)")
        }
        return type
    }

    static let models: [UTType] = ["stl", "obj", "amf", "3mf"].map { ext in
        guard let type = UTType(filenameExtension: ext, conformingTo: .data) else {
            preconditionFailure("iOS did not provide a content type for .\(ext)")
        }
        return type
    }
}

private struct PlateActionButton: View {
    let symbol: String
    let label: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                Text(label)
                    .font(.system(size: 9))
            }
            .frame(minWidth: 52, minHeight: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(disabled ? .secondary : .primary)
        .disabled(disabled)
    }
}
