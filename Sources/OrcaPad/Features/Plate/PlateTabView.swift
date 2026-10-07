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
    @State private var objectsPresented = false
    @State private var gizmoMode: GizmoMode = .move

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
                   let transform = document.selectedDisplayTransform,
                   let size = document.selectedSize {
                    ObjectManipulationPanel(
                        name: object.name,
                        instanceOrdinal: (object.instances.firstIndex { $0.id == selection.instanceID } ?? 0) + 1,
                        instanceCount: object.instances.count,
                        transform: transform,
                        size: size,
                        bedCenter: SIMD2(Double(bed.center.x), Double(bed.center.y)),
                        isBusy: document.isBusy,
                        onCommit: { newTransform in
                            Task { await document.setSelectedTransform(newTransform) }
                        }
                    )
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
            }
        }
        .fileImporter(
            isPresented: $importPresented,
            allowedContentTypes: ImportTypes.stl,
            onCompletion: handleImport
        )
        .sheet(isPresented: $objectsPresented) { objectsList }
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
                    previewTransform: document.previewTransform,
                    presentationRevision: document.presentationRevision,
                    frameRequest: document.frameRequest,
                    gizmoMode: gizmoMode
                ),
                manipulation: CanvasManipulation(
                    onSelect: { document.select(objectID: $0, instanceID: $1) },
                    onMove: { document.moveSelected(by: $0) },
                    onBegin: { document.beginManipulation() },
                    onRotate: { document.previewRotation(deltaRadians: $0) },
                    onScale: { document.previewScale(factor: $0) },
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
            PlateActionButton(symbol: "plus", label: "Import", disabled: document.isBusy) {
                importPresented = true
            }
            PlateActionButton(
                symbol: "list.bullet",
                label: "Objects",
                disabled: document.scene?.objects.isEmpty != false || document.isMutating
            ) {
                objectsPresented = true
            }
            PlateActionButton(symbol: "square.grid.3x3", label: "Arrange", disabled: true) {
                // Engine arrange (Arrange.cpp + libnest2d) — not yet in the closure.
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

    private func handleImport(_ result: Result<URL, any Error>) {
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
                    Text("No objects — import an STL")
                        .foregroundStyle(.secondary)
                } else {
                    List {
                        ForEach(objects) { object in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(object.name).lineLimit(1)
                                    Text("\(object.instances.count) instance(s)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
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
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                document.select(
                                    objectID: object.id,
                                    instanceID: object.instances.first?.id
                                )
                                objectsPresented = false
                            }
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
            }
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
            Divider().frame(width: 32)
            action("plus.square.on.square", label: "Copy", action: onDuplicate)
            action("trash", label: "Delete", action: onDelete)
            Divider().frame(width: 32)
            future("square.bottomhalf.filled", label: "Lay flat")
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

// MARK: - Object manipulation panel (desktop parity, numeric entry)

private struct ObjectManipulationPanel: View {
    let name: String
    let instanceOrdinal: Int
    let instanceCount: Int
    let transform: InstanceTransform
    let size: SIMD3<Float>
    let bedCenter: SIMD2<Double>
    let isBusy: Bool
    let onCommit: (InstanceTransform) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("instance \(instanceOrdinal)/\(instanceCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.1f × %.1f × %.1f mm", size.x, size.y, size.z))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                NumericField(label: "X", unit: "mm", value: transform.offsetX, digits: 2) { value in
                    var updated = transform; updated.offsetX = value; onCommit(updated)
                }
                NumericField(label: "Y", unit: "mm", value: transform.offsetY, digits: 2) { value in
                    var updated = transform; updated.offsetY = value; onCommit(updated)
                }
                NumericField(label: "Rot Z", unit: "°", value: transform.rotationZ * 180 / .pi, digits: 1) { value in
                    var updated = transform; updated.rotationZ = value * .pi / 180; onCommit(updated)
                }
                NumericField(label: "Scale", unit: "%", value: transform.scale * 100, digits: 1, minimum: 1, maximum: 10_000) { value in
                    var updated = transform; updated.scale = value / 100; onCommit(updated)
                }
            }
            HStack(spacing: 8) {
                quick("−90°") {
                    var updated = transform; updated.rotationZ -= .pi / 2; onCommit(updated)
                }
                quick("+90°") {
                    var updated = transform; updated.rotationZ += .pi / 2; onCommit(updated)
                }
                quick("Reset rotation") {
                    var updated = transform; updated.rotationZ = 0; onCommit(updated)
                }
                quick("100%") {
                    var updated = transform; updated.scale = 1; onCommit(updated)
                }
                quick("Center on bed") {
                    var updated = transform
                    updated.offsetX = bedCenter.x
                    updated.offsetY = bedCenter.y
                    onCommit(updated)
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .disabled(isBusy)
    }

    private func quick(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.caption)
            .buttonStyle(.bordered)
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
    static let stl: [UTType] = {
        guard let type = UTType(filenameExtension: "stl") else {
            preconditionFailure("iOS did not provide an STL content type")
        }
        return [type]
    }()
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
