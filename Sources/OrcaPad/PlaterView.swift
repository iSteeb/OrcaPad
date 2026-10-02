import SwiftUI
import UniformTypeIdentifiers
import Engine

/// Root scene: the plater. 3D canvas full-bleed, lightweight overlays on top.
struct PlaterView: View {
    @State private var rendererStatus = "Metal: starting…"
    @State private var engineStatus = "engine: ready (import an STL)"
    @State private var importPresented = false
    @State private var pendingUpload: MeshUpload?

    var body: some View {
        ZStack(alignment: .topLeading) {
            MetalCanvas(onStatus: { rendererStatus = $0 }, upload: pendingUpload)
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
                    .lineLimit(4)
            }
            .padding(10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding(12)
        }
        .overlay(alignment: .bottom) { platerToolbar }
        .preferredColorScheme(.dark)
        .fileImporter(isPresented: $importPresented,
                      allowedContentTypes: ImportSupport.stlTypes,
                      onCompletion: handleImport)
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
        Task { @MainActor in
            guard let tmp = ImportSupport.copyIntoSandbox(url) else {
                engineStatus = "import: copy into sandbox failed"
                return
            }
            let outcome = await Task.detached(priority: .userInitiated) {
                ImportSupport.process(tmp: tmp, name: url.lastPathComponent)
            }.value
            engineStatus = outcome.status
            pendingUpload = outcome.upload
        }
    }
}

// MARK: - Import support (pure statics — no view capture, Sendable-safe)

private enum ImportSupport {
    static let stlTypes: [UTType] = [UTType(filenameExtension: "stl") ?? .data]

    struct Outcome: Sendable {
        let status: String
        let upload: MeshUpload?
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

    /// Engine load → viewer mesh → real slicing report. Blocking; run off-main
    /// (sequential TBB shims make slicing serial for now).
    static func process(tmp: URL, name: String) -> Outcome {
        switch EngineMesh.load(path: tmp.path) {
        case .failure(let err):
            return Outcome(status: err.message, upload: nil)
        case .success(let mesh):
            let vpos = mesh.view.positions
            let vcount = Int(mesh.view.position_count)
            let vidx = mesh.view.indices
            let icount = Int(mesh.view.index_count)
            let expanded = Geometry.expandFlat(
                positions: vpos, positionCount: vcount, indices: vidx, indexCount: icount)
            let verts = expanded.verts
            let idx = expanded.idx
            guard !verts.isEmpty else {
                return Outcome(status: "engine: mesh expanded empty", upload: nil)
            }
            let dims = mesh.dimensionsMM
            let upload = MeshUpload(
                verts: verts, idx: idx,
                bboxMin: SIMD3<Float>(mesh.view.bbox_min.0, mesh.view.bbox_min.1, mesh.view.bbox_min.2),
                bboxMax: SIMD3<Float>(mesh.view.bbox_max.0, mesh.view.bbox_max.1, mesh.view.bbox_max.2))
            var line = "\(name) · \(mesh.triangleCount) tris · " +
                String(format: "%.0f×%.0f×%.0f mm", dims.x, dims.y, dims.z)
            if let sr = mesh.sliceReport(levels: 8) {
                line += "\nslice: \(sr.levels) lvl · mid \(sr.midIslands) isl · \(Int(sr.midAreaMM2)) mm²"
            }
            return Outcome(status: line, upload: upload)
        }
    }
}

// MARK: - Toolbar

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

private extension PlaterView {
    var platerToolbar: some View {
        HStack(spacing: 22) {
            ToolbarButton(symbol: "plus", label: "Import") { importPresented = true }
            ToolbarButton(symbol: "arrow.2.circlepath", label: "Arrange") {
                // Phase 2: libslic3r arrange
            }
            ToolbarButton(symbol: "scissors", label: "Slice", disabled: true) {
                // Phase 3: background slice job
            }
            ToolbarButton(symbol: "gearshape", label: "Settings") {
                // Phase 3: generated settings UI
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.bottom, 14)
    }
}
