import SwiftUI
import UniformTypeIdentifiers
import Engine
import simd

/// Root scene: the plater. 3D canvas full-bleed, lightweight overlays on top.
///
/// State model: `objects` (array-indexed == engine object ids; deletes on
/// both sides shift identically) with per-instance transforms. Structural
/// changes (import/delete) rebuild mesh uploads; transforms/selection only
/// refresh instance matrices (cheap path).
struct PlaterView: View {
    @State private var rendererStatus = "Metal: starting…"
    @State private var engineStatus = "engine: ready (import an STL)"
    @State private var importPresented = false
    @State private var objectsPresented = false
    @State private var plater: EnginePlater?
    @State private var objects: [PlaterObjectState] = []
    @State private var selection: (objectID: Int, instanceID: Int)?
    @State private var slicing = false

    // Renderer sync (tokens gate application; see MetalCanvas.updateUIView)
    @State private var meshToken = UUID()
    @State private var instanceToken = UUID()
    @State private var frameToken = UUID()
    @State private var meshUploads: [SceneObjectUpload]? = nil

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
                if let sel = selection, sel.objectID >= 0,
                   let obj = objectState(sel.objectID), !obj.instances.isEmpty {
                    selectionHUD(for: sel, object: obj)
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
        .onAppear {
            if plater == nil {
                switch EnginePlater.create() {
                case .failure(let err):
                    engineStatus = "plater init FAILED: \(err.message)"
                case .success(let p):
                    plater = p
                }
            }
        }
    }

    private var canvas: MetalCanvas {
        var instanceSets: [Int: [InstanceDraw]] = [:]
        for obj in objects {
            instanceSets[obj.objectID] = obj.instances.enumerated().map { i, st in
                InstanceDraw(
                    instanceID: i,
                    model: PlaterView.modelMatrix(st),
                    selected: selection?.objectID == obj.objectID && selection?.instanceID == i)
            }
        }
        return MetalCanvas(
            onStatus: { rendererStatus = $0 },
            scene: SceneSync(
                meshes: meshUploads,
                meshesToken: meshToken,
                instances: instanceSets,
                instancesToken: instanceToken,
                frameToken: frameToken),
            onSelect: { oid, iid in
                selection = (oid >= 0 && iid >= 0) ? (oid, iid) : nil
                instanceToken = UUID()
            },
            onMoveSelected: { delta in moveSelected(by: delta) },
            onMoveEnded: { commitSelectedTransform() })
    }

    // MARK: - Engine-space transform → viewer model matrix

    static func modelMatrix(_ t: EnginePlater.Transform) -> simd_float4x4 {
        // engine world = anchor + R·s·q (q = packed, recentred mesh);
        // viewer mapping (x,y,z)e → (x,z,-y)v, and Rz(θ)e ≅ Ry(θ)v.
        Math.translate(SIMD3<Float>(Float(t.anchorX), Float(t.anchorZ), -Float(t.anchorY)))
            * Math.rotateY(Float(t.rotationZ))
            * Math.scale(Float(t.scale))
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
        guard let plater else { return }
        guard let tmp = ImportSupport.copyIntoSandbox(url) else {
            engineStatus = "import: copy into sandbox failed"
            return
        }
        let name = url.lastPathComponent
        engineStatus = "\(name): loading…"
        Task { @MainActor in
            let outcome = await Task.detached(priority: .userInitiated) {
                // Blocking engine work off-main: STL read+repair, packing,
                // flat-shading expansion.
                switch plater.addSTL(path: tmp.path) {
                case .failure(let err):
                    return ImportSupport.Outcome(status: err.message, object: nil)
                case .success(let objectID):
                    var transform = EnginePlater.Transform()
                    var built: ObjectMeshData?
                    let tRes = plater.getTransform(objectID: objectID, instanceID: 0)
                    if case .success(let t) = tRes { transform = t }
                    let mRes = plater.withMeshView(objectID: objectID) { view -> ObjectMeshData in
                        let expanded = Geometry.expandFlat(
                            positions: view.positions,
                            positionCount: Int(view.position_count),
                            indices: view.indices,
                            indexCount: Int(view.index_count))
                        return ObjectMeshData(
                            verts: expanded.verts,
                            idx: expanded.idx,
                            bboxMin: SIMD3<Float>(view.bbox_min.0, view.bbox_min.1, view.bbox_min.2),
                            bboxMax: SIMD3<Float>(view.bbox_max.0, view.bbox_max.1, view.bbox_max.2))
                    }
                    if case .success(let mesh) = mRes { built = mesh }
                    guard let mesh = built else {
                        return ImportSupport.Outcome(
                            status: "import FAILED: mesh packing", object: nil)
                    }
                    let dims = mesh.bboxMax - mesh.bboxMin
                    let line = "\(name) · \(mesh.idx.count / 3) tris · " +
                        String(format: "%.0f×%.0f×%.0f mm", dims.x, dims.y, dims.z)
                    return ImportSupport.Outcome(
                        status: line,
                        object: PlaterObjectState(
                            objectID: objectID, name: name,
                            mesh: mesh, instances: [transform]))
                }
            }.value

            switch outcome.object {
            case .some(let state):
                objects.append(state)
                rebuildMeshUploads()
                meshToken = UUID()
                instanceToken = UUID()
                frameToken = UUID()
                engineStatus = outcome.status
            case .none:
                engineStatus = outcome.status
            }
        }
    }

    // MARK: - Instance ops

    private func addInstance(to objectID: Int) {
        guard let plater else { return }
        switch plater.addInstance(objectID: objectID) {
        case .failure(let err):
            engineStatus = "add instance FAILED: \(err.message)"
        case .success(let iid):
            if case .success(let t) = plater.getTransform(objectID: objectID, instanceID: iid),
               let i = objects.firstIndex(where: { $0.objectID == objectID }) {
                objects[i].instances.append(t)
            }
            instanceToken = UUID()
        }
    }

    private func deleteInstance(_ iid: Int, of objectID: Int) {
        guard let plater else { return }
        switch plater.deleteInstance(objectID: objectID, instanceID: iid) {
        case .failure(let err):
            engineStatus = "delete instance FAILED: \(err.message)"
        case .success:
            if let i = objects.firstIndex(where: { $0.objectID == objectID }) {
                objects[i].instances.remove(at: iid)
                if selection?.objectID == objectID { selection = nil }
                instanceToken = UUID()
            }
        }
    }

    private func deleteObject(_ objectID: Int) {
        guard let plater else { return }
        switch plater.deleteObject(objectID) {
        case .failure(let err):
            engineStatus = "delete object FAILED: \(err.message)"
        case .success:
            // Engine ids are indices and renumber on delete — our array is
            // index-aligned, so removing the element keeps both in sync.
            if let i = objects.firstIndex(where: { $0.objectID == objectID }) {
                objects.remove(at: i)
                for j in objects.indices { objects[j].objectID = j }
            }
            selection = nil
            rebuildMeshUploads()
            meshToken = UUID()
            instanceToken = UUID()
        }
    }

    // MARK: - Move / rotate (selected instance)

    private func moveSelected(by delta: SIMD2<Float>) {
        guard let sel = selection,
              let oi = objects.firstIndex(where: { $0.objectID == sel.objectID }),
              objects[oi].instances.indices.contains(sel.instanceID) else { return }
        // Pure bed translation: offset and anchor both shift by the delta.
        objects[oi].instances[sel.instanceID].offsetX += Double(delta.x)
        objects[oi].instances[sel.instanceID].offsetY += Double(delta.y)
        objects[oi].instances[sel.instanceID].anchorX += Double(delta.x)
        objects[oi].instances[sel.instanceID].anchorY += Double(delta.y)
        instanceToken = UUID()
    }

    private func commitSelectedTransform() {
        commitTransform(recomputeAnchor: false)
    }

    private func rotateSelected(by degrees: Double) {
        guard let sel = selection,
              let oi = objects.firstIndex(where: { $0.objectID == sel.objectID }),
              objects[oi].instances.indices.contains(sel.instanceID) else { return }
        objects[oi].instances[sel.instanceID].rotationZ += degrees * .pi / 180
        commitTransform(recomputeAnchor: true)
    }

    /// Pushes the selected instance's transform to the engine, then re-reads
    /// the authoritative state (the anchor shifts when rotation ≠ 0).
    private func commitTransform(recomputeAnchor: Bool) {
        guard let plater, let sel = selection,
              let oi = objects.firstIndex(where: { $0.objectID == sel.objectID }),
              objects[oi].instances.indices.contains(sel.instanceID) else { return }
        let t = objects[oi].instances[sel.instanceID]
        if case .failure(let err) = plater.setTransform(
            objectID: sel.objectID, instanceID: sel.instanceID, t) {
            engineStatus = "transform FAILED: \(err.message)"
            return
        }
        if recomputeAnchor,
           case .success(let authoritative) = plater.getTransform(
               objectID: sel.objectID, instanceID: sel.instanceID) {
            objects[oi].instances[sel.instanceID] = authoritative
        }
        instanceToken = UUID()
    }

    // MARK: - Mesh upload rebuild (structural changes only)

    private func rebuildMeshUploads() {
        meshUploads = objects.compactMap { st in
            guard let mesh = st.mesh else { return nil }
            return SceneObjectUpload(
                objectID: st.objectID,
                verts: mesh.verts,
                idx: mesh.idx,
                bboxMin: mesh.bboxMin,
                bboxMax: mesh.bboxMax)
        }
    }

    private func objectState(_ objectID: Int) -> PlaterObjectState? {
        objects.first { $0.objectID == objectID }
    }

    // MARK: - Slice flow

    private func sliceTapped() {
        guard let plater, !objects.isEmpty, !slicing else { return }
        slicing = true
        let name = objects.first.map { $0.name } ?? "plater"
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let gcodeDir = docs.appendingPathComponent("G-code", isDirectory: true)
        try? FileManager.default.createDirectory(at: gcodeDir, withIntermediateDirectories: true)
        let gcodePath = gcodeDir
            .appendingPathComponent((name as NSString).deletingPathExtension + ".gcode").path

        Task { @MainActor in
            let count = objects.reduce(0) { $0 + $1.instances.count }
            engineStatus = "\(count) instance(s): slicing…"
            let result = await Task.detached(priority: .userInitiated) {
                plater.sliceToGcode(gcodePath: gcodePath) { pct, msg in
                    Task { @MainActor in
                        engineStatus = "\(count) instance(s): \(pct)% \(msg)"
                    }
                }
            }.value
            slicing = false
            switch result {
            case .failure(let err):
                engineStatus = "slice FAILED: \(err.message)"
            case .success(let outcome):
                let mins = Int(outcome.timeEstimateSeconds / 60)
                let kb = outcome.gcodeBytes / 1024
                engineStatus = "\(count) instance(s): G-code ready\n\(kb) KB · ~\(mins) min print · Files → On My iPhone → OrcaPad"
            }
        }
    }

    // MARK: - Selection HUD

    @ViewBuilder
    private func selectionHUD(for sel: (objectID: Int, instanceID: Int),
                              object: PlaterObjectState) -> some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text(object.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text("instance \(sel.instanceID + 1)/\(object.instances.count) · drag to move")
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
                addInstance(to: sel.objectID)
            }
            HUDButton(symbol: "trash", label: "Del inst") {
                if object.instances.count > 1 {
                    deleteInstance(sel.instanceID, of: sel.objectID)
                } else {
                    deleteObject(sel.objectID)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Objects sheet

    private var objectsList: some View {
        NavigationStack {
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
                                Button { addInstance(to: obj.objectID) } label: {
                                    Image(systemName: "plus.rectangle.on.rectangle")
                                }
                                .buttonStyle(.borderless)
                                Button { deleteObject(obj.objectID) } label: {
                                    Image(systemName: "trash")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.borderless)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selection = (obj.objectID, 0)
                                instanceToken = UUID()
                                objectsPresented = false
                            }
                        }
                        .onDelete { indexSet in
                            for i in indexSet { deleteObject(objects[i].objectID) }
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
            ToolbarButton(symbol: "plus", label: "Import") { importPresented = true }
            ToolbarButton(symbol: "list.bullet", label: "Objects",
                          disabled: objects.isEmpty) { objectsPresented = true }
            ToolbarButton(symbol: "arrow.2.circlepath", label: "Arrange",
                          disabled: true) {
                // Phase 2: engine arrange (Arrange.cpp + libnest2d)
            }
            ToolbarButton(symbol: "scissors",
                          label: slicing ? "Slicing" : "Slice",
                          disabled: objects.isEmpty || slicing) {
                sliceTapped()
            }
            ToolbarButton(symbol: "gearshape", label: "Settings",
                          disabled: true) {
                // Phase 3: generated settings UI
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

// MARK: - State types

/// Object mesh for the renderer (reference type — these are multi-MB;
// immutable ⇒ safe to cross concurrency domains).
final class ObjectMeshData: Sendable {
    let verts: [VertexPNC]
    let idx: [UInt32]
    let bboxMin: SIMD3<Float>
    let bboxMax: SIMD3<Float>
    init(verts: [VertexPNC], idx: [UInt32],
         bboxMin: SIMD3<Float>, bboxMax: SIMD3<Float>) {
        self.verts = verts
        self.idx = idx
        self.bboxMin = bboxMin
        self.bboxMax = bboxMax
    }
}

struct PlaterObjectState: Identifiable, Sendable {
    let id = UUID()
    var objectID: Int
    let name: String
    let mesh: ObjectMeshData?
    var instances: [EnginePlater.Transform]
}

// MARK: - Import support (pure statics — no view capture, Sendable-safe)

private enum ImportSupport {
    static let stlTypes: [UTType] = [UTType(filenameExtension: "stl") ?? .data]

    struct Outcome: Sendable {
        let status: String
        let object: PlaterObjectState?
    }

    /// Security-scoped read + copy into the app sandbox (Swift owns paths).
    static func copyIntoSandbox(_ url: URL) -> URL? {
        let gotScope = url.startAccessingSecurityScopedResource()
        defer { if gotScope { url.stopAccessingSecurityScopedResource() } }
        do {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("import.stl")
            try? FileManager.default.removeItem(at: tmp)
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
