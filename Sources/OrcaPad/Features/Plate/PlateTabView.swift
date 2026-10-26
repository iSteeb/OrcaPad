// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

import OrcaBridge
import SwiftUI
import UniformTypeIdentifiers
import UIKit

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
    /// The tools half-modal: collapsed = touch manipulation, expanded =
    /// numeric entry (per user spec).
    @State private var toolsExpanded = false
    @State private var rotationAxis: EngineAxis = .z
    @State private var renameTarget: RenameTarget?
    @State private var settingsTarget: SettingsTarget?
    @State private var countTarget: CountPrompt?
    @State private var countText = ""
    @State private var renameText = ""
    @State private var deleteAllConfirmation = false
    @State private var aboutPresented = false
    @State private var newProjectConfirmation = false
    @State private var parameterTablePresented = false
    @State private var plateRenameTarget: PlateID?
    @State private var plateRenameText = ""
    @State private var flushPresented = false

    private var document: DocumentStore { environment.document }

    private var bed: EngineBed {
        let base = environment.presets.printVolume.map(EngineBed.init) ?? EngineBed.fallback
        // The rendered bed IS the current plate (desktop): shift the
        // printer's bed box to the selected plate's world origin so the
        // grid, gestures and camera anchor there; other plates keep their
        // true relative offsets beside it.
        guard let plate = document.currentPlate else { return base }
        let width = plate.size.x > 0 ? plate.size.x : base.maxX - base.minX
        let depth = plate.size.y > 0 ? plate.size.y : base.maxY - base.minY
        return EngineBed(
            minX: plate.origin.x,
            minY: plate.origin.y,
            maxX: plate.origin.x + width,
            maxY: plate.origin.y + depth
        )
    }

    /// Bottom bar stack: plate chips, filament bar, manipulation panel.
    @ViewBuilder
    private var bottomBars: some View {
        VStack(alignment: .leading, spacing: 8) {
        PlateBar(
            plates: document.plates,
            currentID: document.currentPlate?.id,
            isBusy: document.isBusy || document.isMutating,
            onSelect: { id in Task { await document.selectPlate(id) } },
            onAdd: { Task { await document.addPlate() } },
            onRename: { plate in
                plateRenameText = plate.name
                plateRenameTarget = plate.id
            },
            onToggleLock: { plate in
                Task { await document.lockPlate(plate.id, locked: !plate.locked) }
            },
            onDuplicate: { plate in
                Task { await document.duplicatePlate(plate.id) }
            },
            onMoveFront: { plate in
                Task { await document.movePlateToFront(plate.id) }
            },
            onDelete: { plate in
                Task { await document.deletePlate(plate.id) }
            }
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $flushPresented) {
            FlushingVolumesSheet(
                slots: environment.presets.filamentSlots,
                editedMatrix: environment.presets
                    .editedConfigs[.machine]?["flush_volumes_matrix"],
                editedMultiplier: environment.presets
                    .editedConfigs[.machine]?["flush_multiplier"],
                onApply: { matrix, multiplier in
                    Task {
                        await environment.presets.setValue(
                            kind: .machine, key: "flush_volumes_matrix",
                            serializedValue: matrix
                        )
                        await environment.presets.setValue(
                            kind: .machine, key: "flush_multiplier",
                            serializedValue: multiplier
                        )
                    }
                }
            )
        }
        if let selection = document.selection,
           let object = document.scene?.object(id: selection.objectID),
           let transform = document.selectedDisplayTransform {
            ToolsPanel(
                mode: gizmoMode,
                expanded: $toolsExpanded,
                rotationAxis: $rotationAxis,
                transform: transform,
                meshSize: document.selectedSize ?? object.mesh.bounds.size,
                revision: document.presentationRevision
            ) {
            ManipulationPanel(
                mode: gizmoMode,
                header: PanelHeader(
                    name: object.name,
                    instanceOrdinal: (object.instances.firstIndex { $0.id == selection.instanceID } ?? 0) + 1,
                    instanceCount: object.instances.count,
                    size: document.selectedSize ?? .zero,
                    selectionCount: document.selectedGroup.count,
                    volumeName: selection.volumeID.flatMap { volumeID in
                        object.volumes.first { $0.id == volumeID }?.name
                    },
                    volumeRole: selection.volumeID.flatMap { volumeID in
                        object.volumes.first { $0.id == volumeID }?.role
                    }
                ),
                transform: transform,
                meshSize: object.mesh.bounds.size,
                bedCenter: SIMD2(Double(bed.center.x), Double(bed.center.y)),
                rotationAxis: $rotationAxis,
                isBusy: document.isBusy,
                extruder: object.extruder,
                filamentSlots: environment.presets.filamentSlots,
                onSetExtruder: { extruder in
                    let target: VolumeID? = selection.volumeID
                    Task {
                        // Desktop Set-extruder: 0 = default. On a part
                        // it sets the VOLUME extruder, else the object's.
                        if extruder == 0 {
                            await document.eraseSetting(
                                objectID: object.id, volumeID: target, key: "extruder"
                            )
                        } else {
                            await document.setSetting(
                                objectID: object.id, volumeID: target,
                                key: "extruder", value: String(extruder)
                            )
                        }
                    }
                },
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
                ),
                volume: selection.volumeID.flatMap { volumeID in
                    object.volumes.first { $0.id == volumeID }.map { volume in
                        SelectedVolumeInfo(
                            objectID: object.id,
                            volumeID: volume.id,
                            name: volume.name,
                            role: volume.role,
                            overrideCount: volume.overrideCount
                        )
                    }
                },
                volumeActions: selection.volumeID.map { volumeID in
                    VolumeActions(
                        editSettings: {
                            settingsTarget = SettingsTarget(
                                objectID: object.id, volumeID: volumeID,
                                title: object.volumes.first { $0.id == volumeID }?.name ?? "Part"
                            )
                        },
                        changeType: { role in
                            Task {
                                await document.setVolumeType(
                                    role, volumeID: volumeID, objectID: object.id
                                )
                            }
                        },
                        delete: {
                            Task {
                                await document.deleteVolume(volumeID, objectID: object.id)
                            }
                        }
                    )
                }
            )
            .padding(.bottom, 8)
            }
        }
        }
    }
    var body: some View {
        ZStack {
            canvas.ignoresSafeArea()
                .task(id: "\(gizmoMode.rawValue)-\(document.scene?.revision.rawValue ?? 0)-\(document.selection?.instanceID.rawValue ?? 0)") {
                    // Desktop Flatten gizmo loads its hull planes when the
                    // gizmo activates (and whenever the instance transforms).
                    if gizmoMode == .layFlat {
                        await document.loadFlattenPlanes()
                    } else {
                        document.clearFlattenPlanes()
                    }
                }

            VStack {
                // One wide pill bar (all former left-rail + top controls):
                // Undo / Redo | Menu (file + objects) | Arrange | Tools.
                topBar
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                Spacer()
                bottomBars
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
        }
        .fileImporter(
            isPresented: $importPresented,
            allowedContentTypes: importMode == .project ? ImportTypes.projects : ImportTypes.models,
            allowsMultipleSelection: importMode == .model,
            onCompletion: handleImport
        )
        .sheet(isPresented: $objectsPresented) { objectsList }
        .sheet(isPresented: $aboutPresented) { AboutView() }
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
        .confirmationDialog(
            "Start a new project?",
            isPresented: $newProjectConfirmation,
            titleVisibility: .visible
        ) {
            Button("New project", role: .destructive) {
                Task {
                    await document.newProject(bed: environment.presets.printVolume)
                }
            }
        } message: {
            Text("The plate is cleared and the undo history is discarded. Printer, filament and process selections stay.")
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
                    selectedVolumeID: document.selection?.volumeID,
                    highlightedInstanceIDs: Set(document.selectedGroup.map(\.instanceID)),
                    previewMatrices: document.previewMatrices,
                    presentationRevision: document.presentationRevision,
                    frameRequest: document.frameRequest,
                    cameraRequest: (document.cameraRequestID, document.cameraPreset),
                    gizmoMode: gizmoMode,
                    rotationAxis: rotationAxis,
                    flattenPlanes: gizmoMode == .layFlat ? document.flattenPlanes : nil,
                    flattenHighlight: document.flattenHighlight,
                    filamentColors: environment.presets.filamentSlots
                        .compactMap { slot in Color(hex: slot.colour).map { UIColor($0) } }
                        .map { ui in
                            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
                            ui.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                            return SIMD4<Float>(Float(red), Float(green), Float(blue), 1)
                        }
                ),
                manipulation: CanvasManipulation(
                    onSelect: { document.select(objectID: $0, instanceID: $1) },
                    onToggleSelect: { document.toggleSelect(objectID: $0, instanceID: $1) },
                    onSelectVolume: { objectID, instanceID, volumeID in
                        document.selectVolume(
                            objectID: objectID,
                            instanceID: instanceID,
                            volumeID: volumeID
                        )
                    },
                    onRectangleSelect: { hits in
                        document.setMultiSelection(
                            hits.map { InstanceSelection(
                                objectID: $0.objectID, instanceID: $0.instanceID
                            )}
                        )
                    },
                    onMove: { document.moveSelected(by: $0) },
                    onBegin: { document.beginManipulation() },
                    onRotate: { document.previewRotation(axis: rotationAxis, deltaRadians: $0, snapDegrees: $1) },
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
                onHighlightFlattenPlane: { document.setFlattenHighlight($0) },
                onCycleRotationAxis: {
                    let order: [EngineAxis] = [.x, .y, .z]
                    if let index = order.firstIndex(of: rotationAxis) {
                        rotationAxis = order[(index + 1) % order.count]
                    }
                },
                onEnd: { Task { await document.commitSelectedTransform() } }
                )
            )
        } else {
            Color(red: 0.075, green: 0.078, blue: 0.093)
        }
    }

    // MARK: File / object actions (top-right)

    /// The Plate tab chrome: ONE wide, horizontally SCROLLABLE pill. The
    /// main tools are first-class buttons again (no nesting): Undo / Redo |
    /// Menu (file + clipboard + objects) | Arrange / Fill bed / Orient |
    /// Select / Move / Rotate / Scale / Lay flat | filament slot chips.
    private var topBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                PlateActionButton(
                    symbol: "arrow.uturn.backward",
                    label: "Undo",
                    disabled: document.history?.canUndo != true || document.isBusy
                ) {
                    Task { await document.undo() }
                }
                .keyboardShortcut("z", modifiers: .command)
                PlateActionButton(
                    symbol: "arrow.uturn.forward",
                    label: "Redo",
                    disabled: document.history?.canRedo != true || document.isBusy
                ) {
                    Task { await document.redo() }
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                Divider().frame(height: 28)
                Menu {
                    Button {
                        importMode = .model
                        importPresented = true
                    } label: {
                        Label("Import model…", systemImage: "plus.square")
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
                    Button {
                        newProjectConfirmation = true
                    } label: {
                        Label("New project…", systemImage: "plus")
                    }
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
                    Menu {
                        if let selection = document.selection {
                            Button {
                                Task {
                                    await document.exportSTL(
                                        objectID: selection.objectID,
                                        objectName: document.scene?
                                            .object(id: selection.objectID)?.name ?? "object")
                                }
                            } label: {
                                Label("STL (selected object)…", systemImage: "cube")
                            }
                        }
                        Button {
                            let name = projectName.isEmpty ? defaultProjectName : projectName
                            Task { await document.export3mf(projectName: name) }
                        } label: {
                            Label("Generic 3MF…", systemImage: "shippingbox")
                        }
                        if let engine = environment.presets.engineForSlicing {
                            Button {
                                let name = projectName.isEmpty ? defaultProjectName : projectName
                                Task {
                                    await document.exportGcode3mf(
                                        projectName: name, presets: engine, bed: bed)
                                }
                            } label: {
                                Label("Sliced 3MF (.gcode.3mf)…", systemImage: "internaldrive")
                            }
                            .disabled(
                                document.scene?.objects.isEmpty != false || document.isBusy)
                        }
                        if let export = document.lastExport {
                            ShareLink(item: export) {
                                Label("Share \(export.lastPathComponent)", systemImage: "square.and.arrow.up")
                            }
                        }
                    } label: {
                        Label("Export…", systemImage: "square.and.arrow.up")
                    }
                    .disabled(document.scene?.objects.isEmpty != false || document.isBusy)
                    let recentProjects = EnginePaths.recentProjects()
                    if !recentProjects.isEmpty {
                        Menu {
                            ForEach(recentProjects, id: \.absoluteString) { url in
                                Button(url.deletingPathExtension().lastPathComponent) {
                                    if document.scene?.objects.isEmpty == false {
                                        replaceConfirmation = url
                                    } else {
                                        Task { await environment.openProject(url) }
                                    }
                                }
                            }
                        } label: {
                            Label("Recent", systemImage: "clock.arrow.circlepath")
                        }
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
                    Divider()
                    Button {
                        Task { await document.copySelected() }
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .disabled(document.selection == nil)
                    .keyboardShortcut("c", modifiers: .command)
                    Button {
                        Task { await document.cutSelected() }
                    } label: {
                        Label("Cut", systemImage: "scissors")
                    }
                    .disabled(document.selection == nil)
                    .keyboardShortcut("x", modifiers: .command)
                    Button {
                        Task {
                            await document.pasteObject(bedCenter: bedCenter)
                        }
                    } label: {
                        Label("Paste", systemImage: "clipboard")
                    }
                    .disabled(document.isBusy)
                    .keyboardShortcut("v", modifiers: .command)
                    Button {
                        duplicateSelection()
                    } label: {
                        Label("Duplicate", systemImage: "plus.square.on.square")
                    }
                    .disabled(document.selection == nil || document.isBusy)
                    Button(role: .destructive) {
                        deleteSelection()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .disabled(document.selection == nil || document.isBusy)
                    Divider()
                    Button {
                        objectsPresented = true
                    } label: {
                        Label("Objects…", systemImage: "list.bullet")
                    }
                    .disabled(document.scene?.objects.isEmpty != false)
                    Divider()
                    Button {
                        aboutPresented = true
                    } label: {
                        Label("About OrcaPad", systemImage: "info.circle")
                    }
                } label: {
                    ChromeToolLabel(symbol: "line.3.horizontal", label: "Menu")
                }
                .disabled(document.isBusy)
                Divider().frame(height: 28)
                PlateActionButton(
                    symbol: "square.grid.3x3", label: "Arrange",
                    disabled: document.scene?.objects.isEmpty != false || document.isMutating
                ) {
                    guard let engine = environment.presets.engineForSlicing else { return }
                    Task { await document.arrangeAll(presets: engine, allowRotations: false) }
                }
                if let selection = document.selection {
                    PlateActionButton(
                        symbol: "square.stack.3d.up.fill", label: "Fill bed",
                        disabled: document.isMutating
                    ) {
                        guard let engine = environment.presets.engineForSlicing else { return }
                        Task {
                            await document.fillBed(
                                objectID: selection.objectID, presets: engine, allowRotations: false
                            )
                        }
                    }
                }
                PlateActionButton(
                    symbol: "location.north.circle", label: "Orient",
                    disabled: document.scene?.objects.isEmpty != false || document.isMutating
                ) {
                    guard let engine = environment.presets.engineForSlicing else { return }
                    Task { await document.orientAll(presets: engine) }
                }
                // Desktop keeps Slice on the main plater toolbar — the whole
                // import/arrange/transform loop lives in this tab, and a
                // tab switch should not be part of every iteration.
                if environment.slicing.isSlicing {
                    Button {
                        environment.slicing.cancel()
                    } label: {
                        HStack(spacing: 6) {
                            ProgressView(
                                value: Double(environment.slicing.progress?.percent ?? 0),
                                total: 100
                            )
                            .frame(width: 56)
                            Image(systemName: "xmark.circle.fill")
                        }
                        .frame(height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cancel slicing")
                } else {
                    Menu {
                        Button {
                            Task {
                                await environment.slicing.run(
                                    document: document, presets: environment.presets)
                            }
                        } label: {
                            Label("Slice plate", systemImage: "scissors")
                        }
                        if document.plates.count > 1 {
                            Button {
                                Task {
                                    await environment.slicing.runAll(
                                        document: document, presets: environment.presets)
                                }
                            } label: {
                                Label("Slice all plates", systemImage: "square.stack.3d.up.fill")
                            }
                        }
                    } label: {
                        ChromeToolLabel(symbol: "scissors", label: "Slice")
                            .foregroundStyle(Color.white)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 10))
                    } primaryAction: {
                        Task {
                            await environment.slicing.run(
                                document: document, presets: environment.presets)
                        }
                    }
                    .disabled(
                        document.scene?.objects.isEmpty != false ||
                            document.isBusy || environment.presets.isSelecting
                    )
                }
                Divider().frame(height: 28)
                ForEach(Array(GizmoMode.allCases.enumerated()), id: \.offset) { _, mode in
                    Button {
                        gizmoMode = mode
                        toolsExpanded = false
                    } label: {
                        ChromeToolLabel(symbol: mode.symbol, label: mode.menuLabel)
                            .foregroundStyle(gizmoMode == mode ? Color.white : Color.primary)
                            .background(
                                gizmoMode == mode ? Color.accentColor : Color.clear,
                                in: RoundedRectangle(cornerRadius: 10)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(document.isBusy)
                }
                Divider().frame(height: 28)
                FilamentChips(
                    slots: environment.presets.filamentSlots,
                    isBusy: environment.presets.isSelecting,
                    onAdd: { Task { await environment.presets.addFilament() } },
                    onRemove: { slot in Task { await environment.presets.removeFilament(slot: slot) } },
                    onSelectPreset: { slot, name in
                        Task { await environment.presets.selectFilamentPreset(slot: slot, name: name) }
                    },
                    onSetColour: { slot, colour in
                        Task { await environment.presets.setFilamentColour(slot: slot, colour: colour) }
                    },
                    onEditFlushVolumes: { flushPresented = true },
                    filamentPresets: environment.presets.visibleEntries(for: .filament)
                )
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 6)
        }
        .frame(height: 58)
        .background(.ultraThinMaterial, in: Capsule())
        .clipShape(Capsule())
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
        // A selected volume deletes the volume, not the object.
        if let volumeID = selection.volumeID {
            Task { await document.deleteVolume(volumeID, objectID: selection.objectID) }
            return
        }
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

    private func handleImport(_ result: Result<[URL], any Error>) {
        if case .volume(let role, let objectID) = importMode,
            case .success(let urls) = result {
            // Desktop "Load..." per volume: every picked file becomes one
            // volume of that role on the object.
            for url in urls {
                Task { await document.addVolume(from: url, role: role, objectID: objectID) }
            }
            return
        }
        if importMode == .project, case .success(let urls) = result {
            guard let url = urls.first else { return }
            if document.scene?.objects.isEmpty == false {
                replaceConfirmation = url
            } else {
                Task { await environment.openProject(url) }
            }
            return
        }
        switch result {
        case .success(let urls):
            // Desktop multi-select import: every picked model file lands on
            // the working plate, sequentially (each import is its own undo
            // step, exactly like picking them one by one).
            Task {
                if !document.isReady {
                    await environment.bootstrap()
                }
                guard document.isReady else { return }
                for url in urls {
                    let bedCenter = document.currentPlateCenter
                        ?? environment.presets.printVolume.map {
                            SIMD2<Double>($0.centerX, $0.centerY)
                        }
                        ?? .zero
                    await document.importModel(from: url, bedCenter: bedCenter)
                }
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
                    title: target.title,
                    preselectKey: target.preselectKey
                )
            }
            .sheet(isPresented: $parameterTablePresented) {
                ParameterTableView()
            }
            .alert("Plate name", isPresented: Binding(
                get: { plateRenameTarget != nil },
                set: { if !$0 { plateRenameTarget = nil } }
            )) {
                TextField("Name", text: $plateRenameText)
                Button("Rename") {
                    if let id = plateRenameTarget {
                        let name = plateRenameText
                        Task { await document.renamePlate(id, to: name) }
                    }
                    plateRenameTarget = nil
                }
                Button("Cancel", role: .cancel) { plateRenameTarget = nil }
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
            if object.overrideCount > 0 {
                settingsRows(objectID: object.id, volumeID: nil)
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
            if document.plates.count > 1 {
                // Desktop plate context menu: send an object to another
                // plate without dragging it across the plate grid.
                Menu {
                    ForEach(document.plates) { plate in
                        Button {
                            Task {
                                await document.moveObjectsToPlate([object.id], plate: plate.id)
                            }
                        } label: {
                            if plate.id == document.currentPlate?.id {
                                Label(plate.name, systemImage: "checkmark")
                            } else {
                                Text("\(plate.name) · \(plate.objectCount)")
                            }
                        }
                    }
                } label: {
                    Label("Move to plate", systemImage: "square.stack.3d.up")
                }
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
                Task {
                    await document.copySettings(objectID: object.id, volumeID: nil)
                }
            } label: {
                Label("Copy Process Settings", systemImage: "doc.on.doc")
            }
            Button {
                Task {
                    await document.pasteSettings(objectID: object.id, volumeID: nil)
                }
            } label: {
                Label("Paste Process Settings", systemImage: "doc.on.clipboard")
            }
            .disabled(!document.canPasteSettings || document.settingsClipboardIsVolume)
            frequentSettingsMenu(object: object, volumeID: nil)
            if document.hasMultiSelection {
                Button {
                    parameterTablePresented = true
                } label: {
                    Label("Edit in Parameter Table", systemImage: "tablecells")
                }
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

    /// Desktop create_freq_settings_popupmenu: the upstream
    /// OBJECT_CATEGORY_SETTINGS / PART_CATEGORY_SETTINGS quick menu.
    private func frequentSettingsMenu(object: SceneObject, volumeID: VolumeID?) -> some View {
        Menu {
            ForEach(FrequentSettings.categories(forVolume: volumeID != nil), id: \.name) { category in
                Menu(category.name) {
                    ForEach(category.keys, id: \.self) { key in
                        Button(FrequentSettings.label(for: key)) {
                            settingsTarget = SettingsTarget(
                                objectID: object.id, volumeID: volumeID,
                                title: volumeID == nil ? object.name
                                    : object.volumes.first { $0.id == volumeID }?.name ?? "Part",
                                preselectKey: key
                            )
                        }
                    }
                }
            }
        } label: {
            Label("Frequent settings…", systemImage: "star")
        }
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
    @ViewBuilder
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
                    Task {
                        await document.copySettings(objectID: objectID, volumeID: volume.id)
                    }
                } label: {
                    Label("Copy Process Settings", systemImage: "doc.on.doc")
                }
                Button {
                    Task {
                        await document.pasteSettings(objectID: objectID, volumeID: volume.id)
                    }
                } label: {
                    Label("Paste Process Settings", systemImage: "doc.on.clipboard")
                }
                .disabled(!document.canPasteSettings || !document.settingsClipboardIsVolume)
                if let object = document.scene?.object(id: objectID) {
                    frequentSettingsMenu(object: object, volumeID: volume.id)
                }
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
        if volume.overrideCount > 0 {
            settingsRows(objectID: objectID, volumeID: volume.id)
        }
    }

    /// Desktop object-list "Settings" child items: one row per override,
    /// tap to edit or remove (reset) in the settings sheet.
    @ViewBuilder
    private func settingsRows(objectID: ObjectID, volumeID: VolumeID?) -> some View {
        OverrideRows(objectID: objectID, volumeID: volumeID) { key in
            settingsTarget = SettingsTarget(
                objectID: objectID, volumeID: volumeID,
                title: document.scene?.object(id: objectID)?.name ?? "Settings",
                preselectKey: key
            )
        }
    }
}

/// Count prompt routing (instances / clones).
private struct CountPrompt {
    enum Kind { case instances, clones }
    let kind: Kind
    let objectID: ObjectID
}

/// One row per setting override (desktop object-list Settings child items).
/// Reloads on every document revision; a failed read shows the error row.
private struct OverrideRows: View {
    let objectID: ObjectID
    let volumeID: VolumeID?
    let onPick: (String) -> Void

    @Environment(AppEnvironment.self) private var environment
    @State private var overrides: [String: String]?
    @State private var failure: String?

    var body: some View {
        Group {
            if let overrides {
                ForEach(overrides.keys.sorted(), id: \.self) { key in
                    Button {
                        onPick(key)
                    } label: {
                        HStack {
                            Image(systemName: "slider.horizontal.3")
                                .font(.caption2)
                                .foregroundStyle(Color.accentColor)
                            Text(key)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(overrides[key] ?? "")
                                .font(.caption2.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            } else if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.red)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("Loading settings…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 32)
            }
        }
        .task(id: environment.document.scene?.revision) {
            if let values = await environment.document.settings(
                objectID: objectID, volumeID: volumeID
            ) {
                overrides = values
                failure = nil
            } else {
                failure = "Could not read the overrides"
            }
        }
    }
}

/// Settings sheet routing: an object (volumeID nil) or one of its volumes.
private struct SettingsTarget: Identifiable {
    let objectID: ObjectID
    let volumeID: VolumeID?
    let title: String
    /// A frequent-settings quick-menu pick: the sheet seeds this override.
    var preselectKey: String?

    var id: String { "\(objectID)-\(volumeID?.description ?? "object")-\(preselectKey ?? "")" }
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

    @MainActor
    var tint: Color {
        let c = Renderer.volumeColor(self)
        return Color(
            red: Double(c.x), green: Double(c.y), blue: Double(c.z), opacity: 1
        )
    }
}

// MARK: - Plate bar (desktop PartPlate selector)

/// Desktop plate selector: chips for the plates in order, tap to select
/// (import target + slice source), long-press for the plate menu (rename,
/// lock, duplicate, move to front, delete). Presentation only.
/// Filament slot chips for the top pill bar (desktop filament list,
/// compact): numbered color circles; tap for the slot menu (preset swap,
/// color, remove, flushing volumes); + adds a slot.
private struct FilamentChips: View {
    let slots: [EnginePresets.FilamentSlot]
    let isBusy: Bool
    let onAdd: () -> Void
    let onRemove: (Int) -> Void
    let onSelectPreset: (Int, String) -> Void
    let onSetColour: (Int, String) -> Void
    let onEditFlushVolumes: () -> Void
    let filamentPresets: [PresetEntry]

    @State private var colourTarget: Int?
    @State private var presetTarget: Int?

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(slots.enumerated()), id: \.offset) { index, slot in
                slotChip(index: index, slot: slot)
                    .disabled(isBusy)
            }
            Button(action: onAdd) {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
                    .frame(width: 40, height: 40)
            }
            .disabled(isBusy || slots.count >= 16)
            .accessibilityLabel("Add filament")
        }
        .sheet(item: Binding(
            get: { presetTarget.map { SlotTarget(slot: $0) } },
            set: { presetTarget = $0?.slot }
        )) { target in
            FilamentSlotPickerSheet(
                slot: target.slot,
                current: slots[target.slot].presetName,
                entries: filamentPresets,
                onSelect: { name in
                    presetTarget = nil
                    onSelectPreset(target.slot, name)
                },
                onEditColour: { colourTarget = target.slot },
                onRemove: slots.count > 1 ? {
                    presetTarget = nil
                    onRemove(target.slot)
                } : nil,
                onFlushVolumes: target.slot == 0 ? onEditFlushVolumes : nil
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(item: Binding(
            get: { colourTarget.map { Target(slot: $0) } },
            set: { colourTarget = $0?.slot }
        )) { target in
            FilamentColourPicker(initial: slots[target.slot].colour) { colour in
                onSetColour(target.slot, colour)
            }
            .presentationDetents([.height(320)])
        }
    }

    /// One slot chip: BIG touch target (44pt); tap opens the fast picker
    /// sheet (the inline Menu with hundreds of presets was slow and tiny).
    private func slotChip(index: Int, slot: EnginePresets.FilamentSlot) -> some View {
        Button {
            presetTarget = index
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(Color(hex: slot.colour) ?? .gray)
                    .frame(width: 20, height: 20)
                    .overlay(Circle().strokeBorder(.secondary.opacity(0.5)))
                Text("\(index + 1)")
                    .font(.callout.weight(.semibold).monospacedDigit())
            }
            .frame(height: 44)
            .padding(.horizontal, 10)
            .background(Color(.secondarySystemBackground), in: Capsule())
            .lineLimit(1)
            .fixedSize()
        }
        .buttonStyle(.plain)
    }

    private struct SlotTarget: Identifiable {
        let slot: Int
        var id: Int { slot }
    }

    private struct Target: Identifiable {
        let slot: Int
        var id: Int { slot }
    }
}

private struct FilamentColourPicker: View {
    let initial: String
    let onApply: (String) -> Void

    @State private var colour = Color.gray
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ColorPicker("Filament colour", selection: $colour, supportsOpacity: false)
                .font(.callout)
                .padding(24)
                .navigationTitle("Slot colour")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Apply") {
                            onApply(Color.hexString(colour))
                            dismiss()
                        }
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
        .onAppear { colour = Color(hex: initial) ?? .gray }
    }
}

/// #rrggbb hex color parsing/formatting for filament swatches.
extension Color {
    init?(hex: String) {
        let value = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard value.count == 6, let rgb = UInt64(value, radix: 16) else { return nil }
        self.init(
            .sRGB,
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }

    static func hexString(_ color: Color) -> String {
        let ui = UIColor(color)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        ui.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return String(
            format: "#%02X%02X%02X",
            Int(red * 255), Int(green * 255), Int(blue * 255)
        )
    }
}

struct FlushingVolumesSheet: View {
    let slots: [EnginePresets.FilamentSlot]
    let editedMatrix: String?
    let editedMultiplier: String?
    let onApply: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var matrix: [[Double]] = []
    @State private var multiplier = 1.0

    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 10) {
                    if matrix.count == slots.count {
                        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                            GridRow {
                                Color.clear.frame(width: 34, height: 34)
                                ForEach(Array(slots.enumerated()), id: \.offset) { _, slot in
                                    swatch(slot.colour)
                                }
                            }
                            ForEach(Array(matrix.indices), id: \.self) { row in
                                GridRow {
                                    swatch(slots[row].colour)
                                    ForEach(Array(matrix[row].indices), id: \.self) { column in
                                        TextField(
                                            "0",
                                            value: $matrix[row][column],
                                            format: .number.precision(.fractionLength(0))
                                        )
                                        .keyboardType(.numberPad)
                                        .multilineTextAlignment(.center)
                                        .frame(width: 56, height: 34)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.caption.monospaced())
                                    }
                                }
                            }
                        }
                    }
                    HStack {
                        Text("Flush multiplier")
                        TextField(
                            "1",
                            value: $multiplier,
                            format: .number.precision(.fractionLength(2))
                        )
                        .keyboardType(.decimalPad)
                        .frame(width: 80)
                        .textFieldStyle(.roundedBorder)
                    }
                    .font(.callout)
                }
                .padding()
            }
            .navigationTitle("Flushing volumes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        let csv = matrix.map { row in
                            row.map { String(format: "%.0f", $0) }.joined(separator: ",")
                        }.joined(separator: ",")
                        onApply(csv, String(format: "%.2f", multiplier))
                        dismiss()
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Reset") {
                        load(defaults: true)
                    }
                }
            }
        }
        .onAppear { load(defaults: false) }
    }

    private func swatch(_ colour: String) -> some View {
        Circle()
            .fill(Color(hex: colour) ?? .gray)
            .frame(width: 22, height: 22)
            .overlay(Circle().strokeBorder(.secondary.opacity(0.5)))
    }

    private func load(defaults: Bool) {
        let count = slots.count
        guard count > 0 else { return }
        let parsed = (defaults ? nil : editedMatrix)?
            .split(separator: ",")
            .compactMap { Double($0) } ?? []
        var grid: [[Double]] = []
        for row in 0..<count {
            var line: [Double] = []
            for column in 0..<count {
                let index = row * count + column
                line.append(index < parsed.count ? parsed[index]
                              : (row == column ? 0 : 280))
            }
            grid.append(line)
        }
        matrix = grid
        multiplier = Double(editedMultiplier ?? "1") ?? 1
    }
}

private struct PlateBar: View {
    let plates: [ScenePlate]
    let currentID: PlateID?
    let isBusy: Bool
    let onSelect: (PlateID) -> Void
    let onAdd: () -> Void
    let onRename: (ScenePlate) -> Void
    let onToggleLock: (ScenePlate) -> Void
    let onDuplicate: (ScenePlate) -> Void
    let onMoveFront: (ScenePlate) -> Void
    let onDelete: (ScenePlate) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(plates) { plate in
                    chip(plate)
                }
                Button(action: onAdd) {
                    Image(systemName: "plus.rectangle.on.rectangle")
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 34, height: 32)
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
                .opacity(isBusy ? 0.4 : 1)
                .accessibilityLabel("Add plate")
            }
            .padding(6)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .frame(height: 44)
    }

    private func chip(_ plate: ScenePlate) -> some View {
        let current = plate.id == currentID
        return Button {
            onSelect(plate.id)
        } label: {
            HStack(spacing: 4) {
                if plate.locked {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                }
                Text("\(plate.index + 1)")
                    .font(.callout.weight(current ? .bold : .regular).monospacedDigit())
                if plate.objectCount > 0 {
                    Text("· \(plate.objectCount)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 34, minHeight: 32)
            .padding(.horizontal, 6)
            .background(
                current ? Color.accentColor.opacity(0.25) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        current ? Color.accentColor : Color.secondary.opacity(0.4),
                        lineWidth: current ? 1.5 : 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .contextMenu {
            Button {
                onRename(plate)
            } label: {
                Label("Rename…", systemImage: "pencil")
            }
            Button {
                onToggleLock(plate)
            } label: {
                Label(
                    plate.locked ? "Unlock" : "Lock",
                    systemImage: plate.locked ? "lock.open" : "lock"
                )
            }
            Button {
                onDuplicate(plate)
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            Button {
                onMoveFront(plate)
            } label: {
                Label("Move to front", systemImage: "arrow.left.to.line")
            }
            Divider()
            Button(role: .destructive) {
                onDelete(plate)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .accessibilityLabel(plate.name)
        .accessibilityHint(current ? "Current plate" : "\(plate.objectCount) object(s)")
    }
}

// MARK: - Gizmo toolbar (left, desktop parity)

// MARK: - Object manipulation panels (desktop parity, one per gizmo mode)

private struct PanelHeader {
    let name: String
    let instanceOrdinal: Int
    let instanceCount: Int
    let size: SIMD3<Float>
    /// Members of a multi-selection (1 = single).
    var selectionCount = 1
    /// The selected volume (part selection), if any — replaces the object
    /// name in the header.
    var volumeName: String?
    var volumeRole: VolumeRole?
}

/// The selected volume presented by the manipulation panel (part selection).
private struct SelectedVolumeInfo {
    let objectID: ObjectID
    let volumeID: VolumeID
    let name: String
    let role: VolumeRole
    let overrideCount: Int
}

private struct VolumeActions {
    let editSettings: () -> Void
    let changeType: (VolumeRole) -> Void
    let delete: () -> Void
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
    /// Object-level extruder (0 = default) + filament slots; the header
    /// shows the Set-extruder menu when more than one filament is loaded
    /// (desktop ObjectList extruder assignment).
    var extruder: Int = 0
    var filamentSlots: [EnginePresets.FilamentSlot] = []
    var onSetExtruder: ((Int) -> Void)? = nil
    let actions: ManipulationActions
    var volume: SelectedVolumeInfo?
    var volumeActions: VolumeActions?

    private var showsExtruderMenu: Bool {
        filamentSlots.count > 1 && onSetExtruder != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Row 1: name (flexible, shrinks never wraps) + extruder chip
            // (compact, fixed — it squeezed to vertical letters before).
            HStack(spacing: 8) {
                if let role = header.volumeRole {
                    Image(systemName: role.symbol)
                        .foregroundStyle(role.tint)
                }
                Text(header.volumeName ?? header.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if showsExtruderMenu { extruderChip }
            }
            // Row 2: meta chips — shrink to fit, never wrap, never squeeze.
            HStack(spacing: 14) {
                Text("instance \(header.instanceOrdinal) of \(header.instanceCount)")
                if header.selectionCount > 1 {
                    Text("+\(header.selectionCount - 1) selected")
                        .foregroundStyle(Color.accentColor)
                }
                Text(String(format: "%.1f × %.1f × %.1f mm",
                            header.size.x, header.size.y, header.size.z))
                    .monospacedDigit()
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
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
            case .select:
                Label(
                    "Drag on the plate to select by rectangle. Long-press an object to add it to the selection.",
                    systemImage: "rectangle.dashed"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if let volume, let volumeActions {
                volumeRow(volume, actions: volumeActions)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .disabled(isBusy)
    }

    /// Selected volume (part selection): role chip + per-volume actions.
    private func volumeRow(
        _ volume: SelectedVolumeInfo, actions: VolumeActions
    ) -> some View {
        HStack(spacing: 10) {
            Text(volume.role.label)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(volume.role.tint.opacity(0.18), in: Capsule())
                .foregroundStyle(volume.role.tint)
            if volume.overrideCount > 0 {
                Label("\(volume.overrideCount)", systemImage: "slider.horizontal.3")
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
            }
            Spacer()
            Button {
                actions.editSettings()
            } label: {
                Label("Settings", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.bordered)
            .font(.caption)
            if volume.role != .part {
                Menu {
                    ForEach(VolumeRole.allCases, id: \.self) { role in
                        Button(role.label) { actions.changeType(role) }
                    }
                } label: {
                    Label("Type", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
                .font(.caption)
            }
            Button(role: .destructive) {
                actions.delete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .font(.caption)
        }
    }

    // Move: X / Y on the bed plane + center (Z is engine-managed: rests on bed).
    /// Compact extruder chip: icon + tool number (the long label wrapped
    /// vertically when squeezed — bounded text stays one line).
    @ViewBuilder
    private var extruderChip: some View {
        Menu {
            Button {
                onSetExtruder?(0)
            } label: {
                Label("Default", systemImage: extruder == 0 ? "checkmark" : "")
            }
            ForEach(Array(filamentSlots.enumerated()), id: \.offset) { index, slot in
                Button {
                    onSetExtruder?(index + 1)
                } label: {
                    if extruder == index + 1 {
                        Label("Slot \(index + 1) · \(slot.presetName)", systemImage: "checkmark")
                    } else {
                        Text("Slot \(index + 1) · \(slot.presetName)")
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "paintbrush.pointed")
                Text(extruder == 0 ? "auto" : "T\(extruder)")
                    .monospacedDigit()
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(.secondarySystemBackground), in: Capsule())
            .lineLimit(1)
            .fixedSize()
        }
        .disabled(isBusy)
    }

    private var movePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom, spacing: 14) {
                NumericField(label: "X position", unit: "mm", value: transform.offsetX, digits: 2) { value in
                    var updated = transform; updated.offsetX = value; actions.setTransform(updated, "Move")
                }
                NumericField(label: "Y position", unit: "mm", value: transform.offsetY, digits: 2) { value in
                    var updated = transform; updated.offsetY = value; actions.setTransform(updated, "Move")
                }
            }
            Button {
                var updated = transform
                updated.offsetX = bedCenter.x
                updated.offsetY = bedCenter.y
                actions.setTransform(updated, "Center")
            } label: {
                Label("Center on bed", systemImage: "scope")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }
}

/// Rotate: world-axis selector with an orientation glyph, ±15° engine steps
/// (wrapping through 360°), a free-angle relative entry (desktop rotate
/// input window), reset, and the engine's Euler readout.
private struct RotatePanel: View {
    let transform: InstanceTransform
    @Binding var axis: EngineAxis
    let actions: ManipulationActions

    static let step = 15.0

    @State private var relativeDegrees = ""
    @FocusState private var relativeFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Euler readout: one comfortable row
            HStack(spacing: 14) {
                ForEach(EngineAxis.allCases, id: \.self) { candidate in
                    Text("\(candidate.label) \(Self.degrees(transform.rotation[Int(candidate.rawValue)]))°")
                        .font(.callout.monospaced())
                        .foregroundStyle(candidate == axis ? candidate.color : Color.secondary)
                }
                Spacer()
            }
            // Axis selector: big, tap-friendly
            HStack(spacing: 8) {
                Text("Axis")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .leading)
                ForEach(EngineAxis.allCases, id: \.self) { candidate in
                    Button {
                        axis = candidate
                    } label: {
                        Text(candidate.label)
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .foregroundStyle(axis == candidate ? Color.white : candidate.color)
                            .background(
                                axis == candidate ? candidate.color : candidate.color.opacity(0.15),
                                in: RoundedRectangle(cornerRadius: 10)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            // Relative angle: entry + quick steps, one aligned row
            HStack(spacing: 8) {
                Text("Angle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .leading)
                TextField("e.g. 12.5", text: $relativeDegrees)
                    .keyboardType(.numbersAndPunctuation)
                    .font(.body.monospaced())
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .multilineTextAlignment(.center)
                    .onSubmit(applyRelative)
                Text("°")
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Button(action: applyRelative) {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.title3)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.bordered)
                Spacer()
                Button { actions.rotate(axis, -Self.step) } label: {
                    Image(systemName: "minus")
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.bordered)
                Text("15°")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Button { actions.rotate(axis, Self.step) } label: {
                    Image(systemName: "plus")
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.bordered)
            }
            Button(role: .destructive) {
                actions.resetRotation()
            } label: {
                Label("Reset rotation", systemImage: "arrow.uturn.backward.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    private func applyRelative() {
        guard let degrees = Double(relativeDegrees.trimmingCharacters(in: .whitespaces)),
              degrees != 0 else { return }
        actions.rotate(axis, degrees)
        relativeDegrees = ""
        relativeFocused = false
    }

    /// Engine Euler angle as a 0-359.9 display value (never "-0.0").
    static func degrees(_ radians: Double) -> String {
        var value = (radians * 180 / .pi).truncatingRemainder(dividingBy: 360)
        if value < 0 { value += 360 }
        if abs(value) < 0.05 || value >= 359.95 { value = 0 }
        return String(format: "%.1f", value)
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
        case .x: return .red
        case .y: return .green
        case .z: return .blue
        }
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Toggle(isOn: $uniform) {
                    Label("Uniform", systemImage: uniform ? "lock.fill" : "lock.open")
                }
                .toggleStyle(.button)
                Spacer()
                Button(role: .destructive) {
                    var updated = transform
                    updated.scaleX = 1; updated.scaleY = 1; updated.scaleZ = 1
                    actions.setTransform(updated, "Reset scale")
                } label: {
                    Label("Reset 100%", systemImage: "arrow.uturn.backward.circle")
                }
                .buttonStyle(.bordered)
            }
            // Scale percentages: one aligned row
            HStack(alignment: .bottom, spacing: 14) {
                Text("Scale")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .leading)
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
            // Absolute size: one aligned row
            HStack(alignment: .bottom, spacing: 14) {
                Text("Size")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .leading)
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
            let ratio = newScale / scale(axis)
            updated.scaleX *= ratio
            updated.scaleY *= ratio
            updated.scaleZ *= ratio
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
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                TextField(label, text: $draft)
                    .onSubmit(submit)
                    .keyboardType(.numbersAndPunctuation)
                    .font(.callout.monospaced())
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(invalid ? Color.red : Color.primary)
                Text(unit)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .fixedSize()
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
            ChromeToolLabel(symbol: symbol, label: label)
        }
        .buttonStyle(.plain)
        .opacity(disabled ? 0.35 : 1)
        .disabled(disabled)
    }
}

/// Collapsible tools half-modal (user spec): COLLAPSED is a compact bar
/// for touch manipulation (live readouts, axis-focus chips for rotate);
/// EXPANDED reveals the full numeric editors. Dragging on the canvas works
/// in both states - the panel never blocks the object.
private struct ToolsPanel<Content: View>: View {
    let mode: GizmoMode
    @Binding var expanded: Bool
    @Binding var rotationAxis: EngineAxis
    let transform: InstanceTransform
    let meshSize: SIMD3<Float>
    /// Advances on EVERY gesture event; observing it here guarantees the
    /// readouts re-render live during drags.
    var revision: UInt64 = 0
    @ViewBuilder let content: () -> Content

    var body: some View {
        let _ = revision
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: mode.symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 34)
                context
                Spacer(minLength: 8)
                Button {
                    withAnimation(.snappy(duration: 0.25)) { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.down.circle.fill" : "chevron.up.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? "Collapse tools" : "Expand tools")
            }
            .frame(height: 44)
            if expanded {
                content()
                    .padding(.top, 4)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    /// Collapsed-state context: live values + focus chips + touch hint.
    @ViewBuilder
    private var context: some View {
        switch mode {
        case .move:
            HStack(spacing: 10) {
                Text("X \(String(format: "%.1f", transform.offsetX)) · Y \(String(format: "%.1f", transform.offsetY))")
                    .font(.callout.monospacedDigit().weight(.medium))
                Text("drag to move")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .rotate:
            HStack(spacing: 8) {
                ForEach(EngineAxis.allCases, id: \.self) { candidate in
                    Button {
                        rotationAxis = candidate
                    } label: {
                        Text(candidate.label)
                            .font(.callout.weight(.semibold))
                            .frame(width: 34, height: 30)
                            .foregroundStyle(rotationAxis == candidate ? Color.white : candidate.color)
                            .background(
                                rotationAxis == candidate ? candidate.color : candidate.color.opacity(0.15),
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                    }
                    .buttonStyle(.plain)
                }
                Text(RotatePanel.degrees(transform.rotation[Int(rotationAxis.rawValue)])) + Text("°")
                Text("tap model to cycle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .scale:
            HStack(spacing: 10) {
                Text("\(String(format: "%.0f", transform.scaleX * 100))%")
                    .font(.callout.monospaced())
                Text("\(String(format: "%.0f×%.0f×%.0f", meshSize.x, meshSize.y, meshSize.z)) mm")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                Text("drag vertically")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .layFlat:
            Text("tap a face of the object")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .select:
            Text("drag to select")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

/// The Plate tab's shared button vocabulary: every icon+label control in the
/// canvas chrome (action bar, gizmo toolbar, menu labels) renders through
/// these tokens so the design language stays identical everywhere.
struct ChromeToolLabel: View {
    let symbol: String
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
            Text(label)
                .font(.system(size: 9))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(minWidth: 52, minHeight: 40)
        .contentShape(Rectangle())
    }
}


/// Fast per-slot filament picker: a searchable, compatibility-filtered
/// categorized List in a sheet (replaces the slow giant inline Menu).
private struct FilamentSlotPickerSheet: View {
    let slot: Int
    let current: String
    let entries: [PresetEntry]
    let onSelect: (String) -> Void
    var onEditColour: () -> Void = {}
    var onRemove: (() -> Void)?
    var onFlushVolumes: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var showIncompatible = false
    @AppStorage("presets.filterCompatible") private var globalFilter = true

    private var visible: [PresetEntry] {
        var list = globalFilter && !showIncompatible
            ? entries.filter(\.isCompatible)
            : entries
        if !search.isEmpty {
            list = list.filter {
                $0.name.localizedCaseInsensitiveContains(search) ||
                    $0.vendor.localizedCaseInsensitiveContains(search)
            }
        }
        return list
    }

    private var groups: [(String, [PresetEntry])] {
        let others = visible.filter { $0.origin != .system }
        let byVendor = Dictionary(grouping: visible.filter { $0.origin == .system }) {
            $0.vendor.isEmpty ? "Other" : $0.vendor
        }
        var result: [(String, [PresetEntry])] = []
        if !others.isEmpty { result.append(("Project / user", others)) }
        result.append(contentsOf: byVendor.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 })
        return result
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search filaments", text: $search)
                            .textFieldStyle(.plain)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    if entries.contains(where: { !$0.isCompatible }) {
                        Toggle("Show incompatible presets", isOn: $showIncompatible)
                            .font(.caption)
                    }
                    Button {
                        dismiss()
                        onEditColour()
                    } label: {
                        Label("Edit slot colour…", systemImage: "paintpalette")
                    }
                    if let onFlushVolumes {
                        Button {
                            dismiss()
                            onFlushVolumes()
                        } label: {
                            Label("Flushing volumes…", systemImage: "square.grid.3x3.middle.filled")
                        }
                    }
                    if let onRemove {
                        Button(role: .destructive) {
                            dismiss()
                            onRemove()
                        } label: {
                            Label("Remove filament", systemImage: "minus.circle")
                        }
                    }
                }
                ForEach(groups, id: \.0) { group in
                    Section(group.0) {
                        ForEach(group.1, id: \.name) { entry in
                            Button {
                                onSelect(entry.name)
                            } label: {
                                HStack {
                                    if entry.name == current {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Color.accentColor)
                                    }
                                    Text(entry.name)
                                        .foregroundStyle(entry.isCompatible ? Color.primary : Color.secondary)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.6)
                                    if !entry.isCompatible {
                                        Image(systemName: "exclamationmark.triangle")
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                    }
                                    Spacer()
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Slot \(slot + 1) filament")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
