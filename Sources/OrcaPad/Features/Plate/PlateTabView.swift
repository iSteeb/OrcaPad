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
    @State private var rotationAxis: EngineAxis = .z

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
                            size: document.selectedSize ?? .zero
                        ),
                        transform: transform,
                        meshSize: object.mesh.bounds.size,
                        bedCenter: SIMD2(Double(bed.center.x), Double(bed.center.y)),
                        rotationAxis: $rotationAxis,
                        isBusy: document.isBusy,
                        actions: ManipulationActions(
                            setTransform: { newTransform in
                                Task { await document.setSelectedTransform(newTransform) }
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
                    previewMatrix: document.previewMatrix,
                    presentationRevision: document.presentationRevision,
                    frameRequest: document.frameRequest,
                    gizmoMode: gizmoMode,
                    rotationAxis: rotationAxis
                ),
                manipulation: CanvasManipulation(
                    onSelect: { document.select(objectID: $0, instanceID: $1) },
                    onMove: { document.moveSelected(by: $0) },
                    onBegin: { document.beginManipulation() },
                    onRotate: { document.previewRotation(axis: rotationAxis, deltaRadians: $0) },
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

// MARK: - Object manipulation panels (desktop parity, one per gizmo mode)

private struct PanelHeader {
    let name: String
    let instanceOrdinal: Int
    let instanceCount: Int
    let size: SIMD3<Float>
}

private struct ManipulationActions {
    let setTransform: (InstanceTransform) -> Void
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
                Spacer()
                Text(String(format: "%.1f × %.1f × %.1f mm", header.size.x, header.size.y, header.size.z))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            switch mode {
            case .move: movePanel
            case .rotate: RotatePanel(transform: transform, axis: $rotationAxis, actions: actions)
            case .scale: ScalePanel(transform: transform, meshSize: meshSize, actions: actions)
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
                var updated = transform; updated.offsetX = value; actions.setTransform(updated)
            }
            NumericField(label: "Y", unit: "mm", value: transform.offsetY, digits: 2) { value in
                var updated = transform; updated.offsetY = value; actions.setTransform(updated)
            }
            Button {
                var updated = transform
                updated.offsetX = bedCenter.x
                updated.offsetY = bedCenter.y
                actions.setTransform(updated)
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
                    actions.setTransform(updated)
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
        actions.setTransform(updated)
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
