// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

import MetalKit
import OrcaBridge
import os
import simd

/// Which manipulation the Plate's one-finger drag performs on the selected
/// instance (desktop gizmo parity). Drags that start away from the selection
/// always orbit the camera.
enum GizmoMode: String, CaseIterable, Sendable {
    case move
    case rotate
    case scale
    /// Desktop Flatten gizmo (subset): tapping the object lays it on the
    /// tapped face.
    case layFlat
    /// Desktop rectangle selection: one-finger drag draws a marquee and
    /// selects every instance whose screen footprint it intersects.
    case select

    /// Menu label + symbol for the Tools menu and the collapsible panel.
    var menuLabel: String {
        switch self {
        case .move: return "Move"
        case .rotate: return "Rotate"
        case .scale: return "Scale"
        case .layFlat: return "Lay flat"
        case .select: return "Select"
        }
    }

    var symbol: String {
        switch self {
        case .move: return "arrow.up.and.down.and.arrow.left.and.right"
        case .rotate: return "arrow.clockwise.circle"
        case .scale: return "arrow.up.left.and.arrow.down.right"
        case .layFlat: return "square.bottomhalf.filled"
        case .select: return "rectangle.dashed"
        }
    }
}

/// One immutable instance draw derived from a revisioned scene snapshot.
private struct InstanceDraw {
    let instanceID: InstanceID
    let model: simd_float4x4
    let selected: Bool
    let mirrored: Bool
    let printable: Bool
    /// Plate assignment (index; -1 = off every plate).
    let plate: Int
    /// Object-level extruder assignment (1-based; 0 = default).
    let extruder: Int
}

/// A part volume's triangle range inside the object's merged mesh (ABI v26):
/// triangle `t` occupies flattened indices [3t, 3t+3).
struct PartRange {
    let volumeID: VolumeID
    let start: UInt32
    let count: UInt32

    /// The volume containing merged-mesh triangle `t`, if any (parts only).
    static func containing(_ t: UInt32, in ranges: [PartRange]) -> PartRange? {
        ranges.first { t >= $0.start && t < $0.start + $0.count }
    }
}

/// A translucent non-part volume (desktop color_from_model_volume) drawn
/// per instance after the opaque parts.
private struct VolumeDraw {
    let volumeID: VolumeID
    let vb: MTLBuffer
    let ib: MTLBuffer
    let indexCount: Int
    let color: SIMD4<Float>
}

/// Owns all Metal state and draws one frame per display-link tick.
/// Scene = bed grid + N objects × M instances (per-instance model matrices).
/// @MainActor: MTKView is main-actor isolated in the SDK; its delegate is
/// invoked on the main thread, so the conformance is `@preconcurrency`.
@MainActor
final class Renderer: NSObject, MTKViewDelegate {
    struct Status {
        var pipelineError: String?
        var fps: Int = 0
    }

    private let logger = Logger(subsystem: "ie.duz.OrcaPad", category: "renderer")
    private let onStatus: (String) -> Void

    let device: MTLDevice
    let camera = OrbitCamera()
    private(set) var status = Status()

    private var commandQueue: MTLCommandQueue!
    private var litPipeline: MTLRenderPipelineState!
    private var litBlendPipeline: MTLRenderPipelineState!
    private var linePipeline: MTLRenderPipelineState!
    private var pcBlendPipeline: MTLRenderPipelineState!
    /// Selection outline (inverted hull, front faces culled).
    private var outlinePipeline: MTLRenderPipelineState!
    private var depthState: MTLDepthStencilState!
    private var translucentDepthState: MTLDepthStencilState!
    private var overlayDepthState: MTLDepthStencilState!

    // Bed grid
    private var gridVB: MTLBuffer!
    private var gridVertexCount: Int = 0
    /// Outlines of the non-current plates (ABI v27): dimmed rectangles in
    /// viewer space, rebuilt on every scene apply (cheap: <= 36 rects).
    private var plateOutlineVertices: [VertexPC] = []
    private var lastFrameTime: Float?
    /// Index of the selected plate (for framing + outline dimming).
    private var currentPlateIndex = 0

    // Scene objects (GPU buffers + CPU picking copies + instance matrices)
    private struct RenderObject {
        let objectID: ObjectID
        let meshRevision: UInt64
        let vb: MTLBuffer
        let ib: MTLBuffer
        let indexCount: Int
        let bboxMin: SIMD3<Float>   // object-local (packed) space
        let bboxMax: SIMD3<Float>
        /// Inverted-hull selection outline width (object-space mm).
        let outlineWidth: Float
        let pickPositions: [SIMD3<Float>]  // packed viewer-space (pre-instance)
        let pickIndices: [UInt32]
        var instances: [InstanceDraw]
        var volumes: [VolumeDraw]
        /// Part triangle ranges into the merged mesh (canvas part picking).
        let partRanges: [PartRange]
        /// Object-space meshes of non-part volumes (canvas part picking).
        let volumeMeshes: [VolumeID: SceneMesh]
        /// The selected volume of THIS object (highlight), if any.
        var selectedVolumeID: VolumeID?
    }
    private var objects: [RenderObject] = []
    private var documentID: DocumentID?
    private var appliedRevision = DocumentRevision(rawValue: 0)
    private var bed: EngineBed = .fallback
    /// Marquee rectangle in view POINTS (rectangle selection mode); drawn as
    /// a screen-space overlay each frame.
    private var marqueeRect: CGRect?

    /// Filament slot colors (multi-filament): instances with an extruder
    /// assignment draw in their slot color (desktop colors objects by
    /// extruder). Empty / single = default object color.
    private var filamentColors: [SIMD4<Float>] = []

    func setFilamentColors(_ colors: [SIMD4<Float>]) {
        filamentColors = colors
    }

    // Flatten-gizmo planes (desktop GLGizmoFlatten): viewer-space convex
    // polygons + their engine-space normals; the highlighted index follows
    // the finger before the tap applies.
    private struct FlattenPlaneDraw {
        let vertices: [SIMD3<Float>]
        let engineNormal: SIMD3<Double>
    }
    private var flattenPlanes: [FlattenPlaneDraw] = []
    private var flattenHighlightIndex: Int?

    func setFlattenPlanes(_ planes: [EnginePlater.FlattenPlane]?) {
        flattenPlanes = (planes ?? []).map { plane in
            FlattenPlaneDraw(
                vertices: plane.vertices.map { vertex in
                    let viewer = CoordinateMapper.engineToViewer * SIMD4<Float>(vertex.x, vertex.y, vertex.z, 1)
                    return SIMD3(viewer.x, viewer.y, viewer.z)
                },
                engineNormal: plane.normal
            )
        }
        flattenHighlightIndex = nil
    }

    func setFlattenHighlight(_ index: Int?) {
        flattenHighlightIndex = index
    }

    /// Ray vs one flatten plane (fan triangulation, convex polygons).
    private func rayCastFlattenPlane(
        _ ray: (origin: SIMD3<Float>, dir: SIMD3<Float>), plane: FlattenPlaneDraw
    ) -> Float? {
        guard plane.vertices.count >= 3 else { return nil }
        var best: Float?
        for triangle in 1..<(plane.vertices.count - 1) {
            let a = plane.vertices[0], b = plane.vertices[triangle], c = plane.vertices[triangle + 1]
            let edge1 = b - a, edge2 = c - a
            let p = simd_cross(ray.dir, edge2)
            let determinant = simd_dot(edge1, p)
            guard abs(determinant) > 1e-9 else { continue }
            let inverse = 1 / determinant
            let t = ray.origin - a
            let u = inverse * simd_dot(t, p)
            guard u >= 0, u <= 1 else { continue }
            let q = simd_cross(t, edge1)
            let v = inverse * simd_dot(ray.dir, q)
            guard v >= 0, u + v <= 1 else { continue }
            let distance = inverse * simd_dot(edge2, q)
            if distance > 1e-4 { best = min(best ?? .infinity, distance) }
        }
        return best
    }

    /// Desktop Flatten-gizmo picking: the plane under the touch wins (the
    /// whole coplanar hull region, not a single mesh facet).
    func pickFlattenPlane(at point: CGPoint, in view: MTKView)
        -> (engineNormal: SIMD3<Double>, index: Int)? {
        let ray = screenRay(at: point, in: view)
        var best: (index: Int, t: Float)?
        for (index, plane) in flattenPlanes.enumerated() {
            guard let t = rayCastFlattenPlane(ray, plane: plane) else { continue }
            if best == nil || t < best!.t { best = (index, t) }
        }
        guard let best else { return nil }
        return (flattenPlanes[best.index].engineNormal, best.index)
    }

    private static let objectColor = SIMD4<Float>(0.96, 0.52, 0.11, 1)
    private static let selectedColor = SIMD4<Float>(0.16, 0.80, 0.95, 1)
    /// Selection-outline shell (brighter than the selection tint so it
    /// reads against both the object and the dark background).
    private static let outlineColor = SIMD4<Float>(0.42, 0.93, 1.0, 1)
    /// Desktop draws non-printable instances greyed out.
    private static let unprintableColor = SIMD4<Float>(0.42, 0.42, 0.44, 1)
    /// Selected volume/part highlight (desktop GLVolume selection tint).
    static let selectedVolumeColor = SIMD4<Float>(0.35, 0.95, 0.55, 0.55)

    /// Desktop GLVolume colors for non-part volumes (3DScene.cpp).
    static func volumeColor(_ role: VolumeRole) -> SIMD4<Float> {
        switch role {
        case .part: return SIMD4(0.96, 0.52, 0.11, 1)
        case .modifier: return SIMD4(1.0, 1.0, 0.0, 0.6)
        case .negative: return SIMD4(0.3, 0.3, 0.3, 0.4)
        case .supportBlocker: return SIMD4(1.0, 0.3, 0.3, 0.4)
        case .supportEnforcer: return SIMD4(0.3, 0.3, 1.0, 0.4)
        }
    }

    // Frame uniforms
    private var cubeUniforms = CubeUniforms(
        mvp: .init(diagonal: .one),
        model: .init(diagonal: .one),
        color: SIMD4<Float>(0.96, 0.52, 0.11, 1),
        lightDir: SIMD3<Float>(0.35, -0.85, 0.40),
        normalSign: 1
    )
    private var lineUniforms = LineUniforms(mvp: .init(diagonal: .one))
    private var outlineUniforms = OutlineUniforms(
        mvp: .init(diagonal: .one),
        model: .init(diagonal: .one),
        color: SIMD4<Float>(0.42, 0.93, 1.0, 1),
        width: 0.3
    )

    // FPS tracking
    private var frameTimes: [CFTimeInterval] = []
    private var lastStatusPublish = CACurrentMediaTime()

    init?(view: MTKView, onStatus: @escaping (String) -> Void) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice() else {
            onStatus("ERROR: no Metal device")
            return nil
        }
        self.device = device
        self.onStatus = onStatus
        super.init()

        guard let queue = device.makeCommandQueue() else {
            fail("command queue creation failed")
            return nil
        }
        commandQueue = queue

        do {
            try buildPipelines(view: view)
        } catch {
            fail(String(describing: error))
            return nil
        }
        buildScene(for: bed)
        view.delegate = self
        publishStatus()
        logger.notice("renderer online")
    }

    private func fail(_ message: String) {
        status.pipelineError = message
        logger.error("renderer fatal: \(message, privacy: .public)")
        publishStatus()
    }

    // MARK: Pipeline setup

    private func buildPipelines(view: MTKView) throws {
        let library = try device.makeLibrary(source: Shaders.msl, options: nil)

        let litDesc = MTLRenderPipelineDescriptor()
        litDesc.label = "lit"
        litDesc.vertexFunction = try function(library, "vertexMain")
        litDesc.fragmentFunction = try function(library, "fragmentLit")
        litDesc.vertexDescriptor = Renderer.pncVertexDescriptor()
        litDesc.rasterSampleCount = view.sampleCount
        litDesc.colorAttachments[0].pixelFormat = view.colorPixelFormat
        litDesc.depthAttachmentPixelFormat = view.depthStencilPixelFormat

        let lineDesc = MTLRenderPipelineDescriptor()
        lineDesc.label = "lines"
        lineDesc.vertexFunction = try function(library, "vertexFlat")
        lineDesc.fragmentFunction = try function(library, "fragmentFlat")
        lineDesc.vertexDescriptor = Renderer.pcVertexDescriptor()
        lineDesc.rasterSampleCount = view.sampleCount
        lineDesc.colorAttachments[0].pixelFormat = view.colorPixelFormat
        lineDesc.depthAttachmentPixelFormat = view.depthStencilPixelFormat

        litPipeline = try device.makeRenderPipelineState(descriptor: litDesc)

        // Same lit pipeline with blending: desktop draws modifiers /
        // negative volumes / support blockers / enforcers translucently on
        // top of the solid parts (color_from_model_volume).
        let blendDesc = litDesc.copy() as! MTLRenderPipelineDescriptor
        blendDesc.colorAttachments[0].isBlendingEnabled = true
        blendDesc.colorAttachments[0].rgbBlendOperation = .add
        blendDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        blendDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        blendDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        blendDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        litBlendPipeline = try device.makeRenderPipelineState(descriptor: blendDesc)

        linePipeline = try device.makeRenderPipelineState(descriptor: lineDesc)

        // Selection outline: the lit vertex layout, expanded along normals
        // and front-face culled (inverted hull) — see Shaders.vertexOutline.
        let outlineDesc = MTLRenderPipelineDescriptor()
        outlineDesc.label = "outline"
        outlineDesc.vertexFunction = try function(library, "vertexOutline")
        outlineDesc.fragmentFunction = try function(library, "fragmentFlat")
        outlineDesc.vertexDescriptor = Renderer.pncVertexDescriptor()
        outlineDesc.rasterSampleCount = view.sampleCount
        outlineDesc.colorAttachments[0].pixelFormat = view.colorPixelFormat
        outlineDesc.depthAttachmentPixelFormat = view.depthStencilPixelFormat
        outlinePipeline = try device.makeRenderPipelineState(descriptor: outlineDesc)

        // Flat-color triangles with blending (Flatten-gizmo planes and other
        // translucent overlays): same vertexFlat/fragmentFlat pair, blended.
        let pcBlendDesc = lineDesc.copy() as! MTLRenderPipelineDescriptor
        pcBlendDesc.label = "flat-blend"
        pcBlendDesc.colorAttachments[0].isBlendingEnabled = true
        pcBlendDesc.colorAttachments[0].rgbBlendOperation = .add
        pcBlendDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pcBlendDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pcBlendDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        pcBlendDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pcBlendPipeline = try device.makeRenderPipelineState(descriptor: pcBlendDesc)

        let depthDesc = MTLDepthStencilDescriptor()
        depthDesc.depthCompareFunction = .less
        depthDesc.isDepthWriteEnabled = true
        guard let ds = device.makeDepthStencilState(descriptor: depthDesc) else {
            throw MetalError.missing("depth stencil state")
        }
        depthState = ds

        let translucentDesc = MTLDepthStencilDescriptor()
        translucentDesc.depthCompareFunction = .less
        translucentDesc.isDepthWriteEnabled = false
        guard let translucent = device.makeDepthStencilState(descriptor: translucentDesc) else {
            throw MetalError.missing("translucent depth stencil state")
        }
        translucentDepthState = translucent

        let overlayDesc = MTLDepthStencilDescriptor()
        overlayDesc.depthCompareFunction = .always
        overlayDesc.isDepthWriteEnabled = false
        guard let overlay = device.makeDepthStencilState(descriptor: overlayDesc) else {
            throw MetalError.missing("overlay depth stencil state")
        }
        overlayDepthState = overlay
    }

    private func function(_ library: MTLLibrary, _ name: String) throws -> MTLFunction {
        guard let fn = library.makeFunction(name: name) else {
            throw MetalError.missing("function \(name)")
        }
        return fn
    }

    private enum MetalError: Error, CustomStringConvertible {
        case missing(String)
        case invalidScene(String)

        var description: String {
            switch self {
            case .missing(let what): return "Metal: missing \(what)"
            case .invalidScene(let detail): return "Metal: invalid scene — \(detail)"
            }
        }
    }

    private static func pncVertexDescriptor() -> MTLVertexDescriptor {
        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float3
        vd.attributes[0].offset = 0
        vd.attributes[0].bufferIndex = 0
        vd.attributes[1].format = .float3
        vd.attributes[1].offset = MemoryLayout<SIMD3<Float>>.stride
        vd.attributes[1].bufferIndex = 0
        vd.layouts[0].stride = MemoryLayout<VertexPNC>.stride
        return vd
    }

    static func pcVertexDescriptor() -> MTLVertexDescriptor {
        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float3
        vd.attributes[0].offset = 0
        vd.attributes[0].bufferIndex = 0
        vd.attributes[1].format = .float4
        vd.attributes[1].offset = MemoryLayout<SIMD3<Float>>.stride
        vd.attributes[1].bufferIndex = 0
        vd.layouts[0].stride = MemoryLayout<VertexPC>.stride
        return vd
    }

    // MARK: Scene setup

    private func buildScene(for bed: EngineBed) {
        let grid = Geometry.bedGrid(for: bed)
        gridVertexCount = grid.count
        gridVB = device.makeBuffer(
            bytes: grid, length: MemoryLayout<VertexPC>.stride * grid.count,
            options: .storageModeShared)
        guard gridVB != nil else {
            fail("bed grid buffer allocation failed")
            return
        }
    }

    // MARK: Scene sync (called from the SwiftUI layer on the main actor)

    /// Atomically replaces the derived render scene from one coherent engine
    /// snapshot. GPU mesh buffers are reused by stable object ID + mesh
    /// revision; transforms and selection remain cheap derived state.
    func applyScene(
        _ scene: SceneSnapshot,
        bed: EngineBed,
        selectedObjectID: ObjectID?,
        selectedInstanceID: InstanceID?,
        highlightedInstanceIDs: Set<InstanceID>,
        previewMatrices: [InstanceID: simd_float4x4],
        selectedVolumeID: VolumeID? = nil
    ) throws {
        if bed != self.bed {
            buildScene(for: bed)
            self.bed = bed
        }
        if let currentDocumentID = documentID,
           currentDocumentID == scene.documentID,
           scene.revision < appliedRevision {
            throw MetalError.invalidScene(
                "snapshot revision regressed from \(appliedRevision.rawValue) to \(scene.revision.rawValue)"
            )
        }

        var rebuilt: [RenderObject] = []
        rebuilt.reserveCapacity(scene.objects.count)
        for sceneObject in scene.objects {
            let instances = sceneObject.instances.map { instance in
                return InstanceDraw(
                    instanceID: instance.id,
                    model: CoordinateMapper.modelMatrix(
                        engineMatrix: previewMatrices[instance.id]
                            ?? EngineMatrix.float(instance.matrix),
                        enginePivot: sceneObject.mesh.pivot,
                        bedCenter: bed.center
                    ),
                    selected: (sceneObject.id == selectedObjectID &&
                        instance.id == selectedInstanceID) ||
                        highlightedInstanceIDs.contains(instance.id),
                    mirrored: instance.mirrored,
                    printable: instance.printable,
                    plate: instance.plate,
                    extruder: sceneObject.extruder
                )
            }

            if let existing = objects.first(where: {
                $0.objectID == sceneObject.id &&
                    $0.meshRevision == sceneObject.mesh.revision
            }) {
                var reused = existing
                reused.instances = instances
                reused.selectedVolumeID =
                    sceneObject.id == selectedObjectID ? selectedVolumeID : nil
                rebuilt.append(reused)
                continue
            }

            // Translucent non-part volumes share the object mesh revision,
            // so they are rebuilt with it (desktop modifier rendering).
            var volumeDraws: [VolumeDraw] = []
            for volume in sceneObject.nonPartVolumes {
                guard let volumeMesh = volume.mesh else {
                    throw MetalError.invalidScene(
                        "volume \(volume.id) of object \(sceneObject.id) has no mesh"
                    )
                }
                let geometry = Geometry.expandFlat(mesh: volumeMesh)
                guard !geometry.verts.isEmpty else {
                    throw MetalError.invalidScene(
                        "volume \(volume.id) of object \(sceneObject.id) has empty geometry"
                    )
                }
                guard let vertexBuffer = device.makeBuffer(
                    bytes: geometry.verts,
                    length: MemoryLayout<VertexPNC>.stride * geometry.verts.count,
                    options: .storageModeShared
                ), let indexBuffer = device.makeBuffer(
                    bytes: geometry.idx,
                    length: MemoryLayout<UInt32>.stride * geometry.idx.count,
                    options: .storageModeShared
                ) else {
                    throw MetalError.missing("mesh buffers for volume \(volume.id)")
                }
                volumeDraws.append(VolumeDraw(
                    volumeID: volume.id,
                    vb: vertexBuffer,
                    ib: indexBuffer,
                    indexCount: geometry.idx.count,
                    color: Renderer.volumeColor(volume.role)
                ))
            }

            let geometry = Geometry.expandFlat(mesh: sceneObject.mesh)
            guard !geometry.verts.isEmpty, !geometry.idx.isEmpty else {
                throw MetalError.invalidScene(
                    "object \(sceneObject.id) has empty render geometry"
                )
            }
            guard let vertexBuffer = device.makeBuffer(
                bytes: geometry.verts,
                length: MemoryLayout<VertexPNC>.stride * geometry.verts.count,
                options: .storageModeShared
            ), let indexBuffer = device.makeBuffer(
                bytes: geometry.idx,
                length: MemoryLayout<UInt32>.stride * geometry.idx.count,
                options: .storageModeShared
            ) else {
                throw MetalError.missing(
                    "mesh buffers for object \(sceneObject.id)"
                )
            }

            let positions = geometry.verts.map(\.position)
            let bounds = positions.reduce(
                into: (
                    minimum: SIMD3<Float>(repeating: .infinity),
                    maximum: SIMD3<Float>(repeating: -.infinity)
                )
            ) { bounds, position in
                bounds.minimum = simd_min(bounds.minimum, position)
                bounds.maximum = simd_max(bounds.maximum, position)
            }
            // Selection-outline shell width: a small fraction of the
            // object's extent, clamped (desktop draws a crisp selection
            // silhouette; the inverted hull approximates it).
            let extent = simd_distance(bounds.minimum, bounds.maximum)
            let outlineWidth = max(0.12, min(extent * 0.006, 2.0))
            rebuilt.append(RenderObject(
                objectID: sceneObject.id,
                meshRevision: sceneObject.mesh.revision,
                vb: vertexBuffer,
                ib: indexBuffer,
                indexCount: geometry.idx.count,
                bboxMin: bounds.minimum,
                bboxMax: bounds.maximum,
                outlineWidth: outlineWidth,
                pickPositions: positions,
                pickIndices: geometry.idx,
                instances: instances,
                volumes: volumeDraws,
                partRanges: sceneObject.volumes
                    .filter { $0.role == .part && $0.mergedTriangleCount > 0 }
                    .map { PartRange(
                        volumeID: $0.id,
                        start: $0.mergedTriangleStart,
                        count: $0.mergedTriangleCount
                    ) },
                volumeMeshes: Dictionary(
                    uniqueKeysWithValues: sceneObject.nonPartVolumes
                        .compactMap { volume in
                            volume.mesh.map { (volume.id, $0) }
                        }
                ),
                selectedVolumeID:
                    sceneObject.id == selectedObjectID ? selectedVolumeID : nil
            ))
        }

        objects = rebuilt
        documentID = scene.documentID
        appliedRevision = scene.revision
        primaryObjectID = selectedObjectID
        primaryInstanceID = selectedInstanceID
        // Multi-plate visibility: the other plates render as dimmed
        // outlined beds beside the current (gridded) plate.
        currentPlateIndex = scene.currentPlate
        plateOutlineVertices = []
        // Inactive plates are DIMMED MINI-BEDS: a border plus a sparse
        // grid (every 50 mm), clearly their own bed — never confused with
        // the current plate's border, never invisible.
        let border = SIMD4<Float>(0.42, 0.46, 0.55, 1)
        let line = SIMD4<Float>(0.24, 0.26, 0.32, 1)
        for plate in scene.plates where plate.index != scene.currentPlate {
            let a = CoordinateMapper.viewerPoint(
                fromEngine: SIMD3(plate.origin.x, plate.origin.y, 0),
                bedCenter: bed.center
            )
            let b = CoordinateMapper.viewerPoint(
                fromEngine: SIMD3(plate.origin.x + plate.size.x,
                                  plate.origin.y + plate.size.y, 0),
                bedCenter: bed.center
            )
            let lo = SIMD3(min(a.x, b.x), 0.15, min(a.z, b.z))
            let hi = SIMD3(max(a.x, b.x), 0.15, max(a.z, b.z))
            let p00 = SIMD3(lo.x, lo.y, lo.z)
            let p10 = SIMD3(hi.x, lo.y, lo.z)
            let p11 = SIMD3(hi.x, lo.y, hi.z)
            let p01 = SIMD3(lo.x, lo.y, hi.z)
            for edge in [(p00, p10), (p10, p11), (p11, p01), (p01, p00)] {
                plateOutlineVertices.append(VertexPC(position: edge.0, color: border))
                plateOutlineVertices.append(VertexPC(position: edge.1, color: border))
            }
            // sparse grid: lines every 50 mm (in plate-local coordinates)
            let step: Float = 50
            let width = hi.x - lo.x, depth = hi.z - lo.z
            var x = lo.x + step
            while x < hi.x - 1 {
                plateOutlineVertices.append(VertexPC(position: SIMD3(x, lo.y, lo.z), color: line))
                plateOutlineVertices.append(VertexPC(position: SIMD3(x, lo.y, hi.z), color: line))
                x += step
            }
            var z = lo.z + step
            while z < hi.z - 1 {
                plateOutlineVertices.append(VertexPC(position: SIMD3(lo.x, lo.y, z), color: line))
                plateOutlineVertices.append(VertexPC(position: SIMD3(hi.x, lo.y, z), color: line))
                z += step
            }
            _ = width; _ = depth
        }
        selectedInstanceIDs = rebuilt.flatMap { object in
            object.instances.filter(\.selected).map {
                (objectID: object.objectID, instanceID: $0.instanceID)
            }
        }
        logger.notice(
            "scene revision \(scene.revision.rawValue): \(rebuilt.count) object(s)"
        )
    }

    /// Instances currently flagged selected (for the move-gesture hit test).
    private(set) var selectedInstanceIDs: [
        (objectID: ObjectID, instanceID: InstanceID)
    ] = []

    /// Frames the camera on the combined scene bbox (call after import).
    /// Desktop view reset: fit the focused BED (current plate) on screen —
    /// not a tight zoom on the objects.
    /// Desktop view reset: fit the focused BED (current plate) on screen —
    /// not a tight zoom on the objects. Animated by OrbitCamera.tick.
    func frameBed() {
        guard bed.maxX > bed.minX, bed.maxY > bed.minY else { return }
        let center = bed.center
        func corner(_ x: Float, _ y: Float) -> SIMD3<Float> {
            CoordinateMapper.viewerPoint(fromEngine: SIMD3(x, y, 0), bedCenter: center)
        }
        let corners = [corner(bed.minX, bed.minY), corner(bed.maxX, bed.minY),
                       corner(bed.maxX, bed.maxY), corner(bed.minX, bed.maxY)]
        var bbMin = SIMD3<Float>(repeating: .infinity)
        var bbMax = SIMD3<Float>(repeating: -.infinity)
        for point in corners {
            bbMin = simd_min(bbMin, point)
            bbMax = simd_max(bbMax, point)
        }
        let maxDim = max(bbMax.x - bbMin.x, bbMax.y - bbMin.y, bbMax.z - bbMin.z)
        camera.animate(
            target: SIMD3((bbMin.x + bbMax.x) * 0.5, 0, (bbMin.z + bbMax.z) * 0.5),
            distance: min(max(maxDim * 1.6, 110), 1400),
            yaw: -0.65,
            pitch: 0.42
        )
    }

    func frameScene() {
        // Desktop framing: the FULL PLATE is the floor (never a tight
        // content zoom — that jarred the camera on every action); content
        // outside the bed is unioned in so nothing vanishes.
        var bbMin = SIMD3<Float>(repeating: .infinity)
        var bbMax = SIMD3<Float>(repeating: -.infinity)
        if bed.maxX > bed.minX, bed.maxY > bed.minY {
            let center = bed.center
            func corner(_ x: Float, _ y: Float) -> SIMD3<Float> {
                CoordinateMapper.viewerPoint(fromEngine: SIMD3(x, y, 0), bedCenter: center)
            }
            for point in [corner(bed.minX, bed.minY), corner(bed.maxX, bed.minY),
                          corner(bed.maxX, bed.maxY), corner(bed.minX, bed.maxY)] {
                bbMin = simd_min(bbMin, point)
                bbMax = simd_max(bbMax, point)
            }
        }
        for obj in objects {
            for inst in obj.instances where inst.plate == currentPlateIndex {
                let m = inst.model
                for c in [obj.bboxMin,
                          SIMD3(obj.bboxMax.x, obj.bboxMin.y, obj.bboxMin.z),
                          SIMD3(obj.bboxMin.x, obj.bboxMax.y, obj.bboxMin.z),
                          SIMD3(obj.bboxMin.x, obj.bboxMin.y, obj.bboxMax.z),
                          SIMD3(obj.bboxMax.x, obj.bboxMax.y, obj.bboxMin.z),
                          SIMD3(obj.bboxMax.x, obj.bboxMin.y, obj.bboxMax.z),
                          SIMD3(obj.bboxMin.x, obj.bboxMax.y, obj.bboxMax.z),
                          obj.bboxMax] {
                    let w = SIMD3((m * SIMD4(c.x, c.y, c.z, 1)).x,
                                 (m * SIMD4(c.x, c.y, c.z, 1)).y,
                                 (m * SIMD4(c.x, c.y, c.z, 1)).z)
                    bbMin = simd_min(bbMin, w)
                    bbMax = simd_max(bbMax, w)
                }
            }
        }
        guard bbMin.x <= bbMax.x else { return }
        let size = bbMax - bbMin
        let maxDim = max(size.x, max(size.y, size.z))
        camera.animate(
            target: (bbMin + bbMax) * 0.5 * SIMD3(1, 0.6, 1),
            distance: min(max(maxDim * 1.7, 110), 1400),
            yaw: -0.65,
            pitch: 0.42
        )
    }

    // MARK: Thumbnails (offscreen, desktop G-code/3MF plate thumbnails)

    enum ThumbnailError: LocalizedError {
        case emptyScene
        case resource(String)

        var errorDescription: String? {
            switch self {
            case .emptyScene: return "thumbnail: scene has no objects"
            case .resource(let what): return "thumbnail: could not create \(what)"
            }
        }
    }

    /// Renders the objects (no bed, no gizmo, transparent background) from
    /// the default iso view, tightly framed, into a `size`×`size` image.
    /// Returns top-down RGBA8 rows. Uses this renderer's own pipelines, so
    /// the offscreen formats are exactly the canvas formats (BGRA8, depth32,
    /// 4× MSAA). Main-thread confined like everything in the renderer.
    func renderThumbnail(size: Int, colorFormat: MTLPixelFormat) throws -> [UInt8] {
        var bbMin = SIMD3<Float>(repeating: .infinity)
        var bbMax = SIMD3<Float>(repeating: -.infinity)
        for obj in objects {
            for inst in obj.instances {
                for x in [obj.bboxMin.x, obj.bboxMax.x] {
                    for y in [obj.bboxMin.y, obj.bboxMax.y] {
                        for z in [obj.bboxMin.z, obj.bboxMax.z] {
                            let w = inst.model * SIMD4(x, y, z, 1)
                            bbMin = simd_min(bbMin, SIMD3(w.x, w.y, w.z))
                            bbMax = simd_max(bbMax, SIMD3(w.x, w.y, w.z))
                        }
                    }
                }
            }
        }
        guard bbMin.x.isFinite else { throw ThumbnailError.emptyScene }

        let thumbCamera = OrbitCamera()
        let extent = bbMax - bbMin
        thumbCamera.target = (bbMin + bbMax) * 0.5
        thumbCamera.distance = max(simd_length(extent) * 1.35, 20)
        thumbCamera.yaw = -0.65
        thumbCamera.pitch = 0.62
        let viewProj = thumbCamera.projection(aspect: 1) * thumbCamera.viewMatrix

        func texture(_ format: MTLPixelFormat, samples: Int, usage: MTLTextureUsage,
                     storage: MTLStorageMode) throws -> MTLTexture {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: size, height: size, mipmapped: false)
            desc.textureType = samples > 1 ? .type2DMultisample : .type2D
            desc.sampleCount = samples
            desc.usage = usage
            desc.storageMode = storage
            guard let tex = device.makeTexture(descriptor: desc) else {
                throw ThumbnailError.resource("\(format) texture")
            }
            return tex
        }
        let msaa = try texture(colorFormat, samples: 4, usage: .renderTarget, storage: .private)
        let resolve = try texture(colorFormat, samples: 1, usage: [.renderTarget, .shaderRead], storage: .shared)
        let depth = try texture(.depth32Float, samples: 4, usage: .renderTarget, storage: .private)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = msaa
        pass.colorAttachments[0].resolveTexture = resolve
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .multisampleResolve
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 1

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw ThumbnailError.resource("command encoder")
        }
        encoder.setRenderPipelineState(litPipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)
        for obj in objects where obj.indexCount > 0 {
            encoder.setVertexBuffer(obj.vb, offset: 0, index: 0)
            for inst in obj.instances {
                var uniforms = cubeUniforms
                uniforms.mvp = viewProj * inst.model
                uniforms.model = inst.model
                uniforms.color = Renderer.objectColor
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<CubeUniforms>.stride, index: 1)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CubeUniforms>.stride, index: 1)
                encoder.drawIndexedPrimitives(
                    type: .triangle, indexCount: obj.indexCount, indexType: .uint32,
                    indexBuffer: obj.ib, indexBufferOffset: 0)
            }
        }
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error {
            throw ThumbnailError.resource("render (\(error.localizedDescription))")
        }

        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        pixels.withUnsafeMutableBytes { bytes in
            resolve.getBytes(
                bytes.baseAddress!, bytesPerRow: size * 4,
                from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        }
        if colorFormat == .bgra8Unorm || colorFormat == .bgra8Unorm_srgb {
            for i in stride(from: 0, to: pixels.count, by: 4) {
                pixels.swapAt(i, i + 2) // BGRA → RGBA
            }
        }
        return pixels
    }

    // MARK: Picking / hit-testing (main thread, called from gestures)

    /// Screen point → world-space ray. `point` is in UIKit coordinates of
    /// the MTKView's coordinate space.
    func screenRay(at point: CGPoint, in view: MTKView) -> (origin: SIMD3<Float>, dir: SIMD3<Float>) {
        // Gesture locations are UIKit POINTS; normalize by the view's bounds,
        // never by drawableSize (PIXELS) — on 3x displays that cast every
        // pick/drag ray toward a third of the touch coordinates.
        let size = view.bounds.size
        let ndcX = Float(point.x / max(size.width, 1)) * 2 - 1
        let ndcY = 1 - Float(point.y / max(size.height, 1)) * 2
        let aspect = Float(size.width / max(size.height, 1))
        let invVP = (camera.projection(aspect: aspect) * camera.viewMatrix).inverse
        let pn4 = invVP * SIMD4(ndcX, ndcY, -1, 1)
        let pf4 = invVP * SIMD4(ndcX, ndcY, 1, 1)
        let pn = SIMD3(pn4.x, pn4.y, pn4.z) / pn4.w
        let pf = SIMD3(pf4.x, pf4.y, pf4.z) / pf4.w
        return (pn, simd_normalize(pf - pn))
    }

    /// Ray ∩ bed plane (y = 0). Nil when the ray runs parallel/away.
    func bedPlaneHit(at point: CGPoint, in view: MTKView) -> SIMD3<Float>? {
        let ray = screenRay(at: point, in: view)
        guard abs(ray.dir.y) > 1e-6 else { return nil }
        let t = -ray.origin.y / ray.dir.y
        guard t > 0 else { return nil }
        return ray.origin + ray.dir * t
    }

    /// Full pick: nearest instance under the screen point.
    /// AABB pre-test per instance, then exact ray-triangle (Möller–Trumbore).
    func pickInstance(
        at point: CGPoint,
        in view: MTKView
    ) -> (objectID: ObjectID, instanceID: InstanceID)? {
        pick(at: point, in: view).map { ($0.pick.objectID, $0.pick.instanceID) }
    }

    /// Full pick: nearest instance under the screen point plus the ENGINE-frame
    /// (z-up) world-space normal of the hit facet (for lay-flat).
    struct FacePick {
        let objectID: ObjectID
        let instanceID: InstanceID
        let engineNormal: SIMD3<Double>
    }

    func pickFace(at point: CGPoint, in view: MTKView) -> FacePick? {
        pick(at: point, in: view)?.pick
    }

    /// Desktop part selection (tap on a selected object): refines the nearest
    /// hit to the tapped VOLUME — parts through their merged-mesh triangle
    /// range, other roles by ray-casting their own object-space mesh.
    struct VolumePick {
        let objectID: ObjectID
        let instanceID: InstanceID
        let volumeID: VolumeID
    }

    func pickVolume(at point: CGPoint, in view: MTKView) -> VolumePick? {
        let ray = screenRay(at: point, in: view)
        var best: (pick: VolumePick, t: Float)?
        for obj in objects {
            for inst in obj.instances {
                if let hit = rayCastObject(ray, object: obj, model: inst.model),
                   let range = PartRange.containing(hit.triangle, in: obj.partRanges),
                   best == nil || hit.t < best!.t {
                    best = (VolumePick(
                        objectID: obj.objectID,
                        instanceID: inst.instanceID,
                        volumeID: range.volumeID
                    ), hit.t)
                }
                for (volumeID, mesh) in obj.volumeMeshes {
                    let model = volumeModel(mesh: mesh, instance: inst.model)
                    guard let t = rayCastMesh(ray, mesh: mesh, model: model),
                        best == nil || t < best!.t else { continue }
                    best = (VolumePick(
                        objectID: obj.objectID,
                        instanceID: inst.instanceID,
                        volumeID: volumeID
                    ), t)
                }
            }
        }
        return best?.pick
    }

    /// Engine object-space mesh → viewer world for one instance (mesh
    /// vertices are `L(p - pivot)`-compatible: engineToViewer then un-shift
    /// by the pivot matches the packed object mesh).
    private func volumeModel(mesh: SceneMesh, instance: simd_float4x4) -> simd_float4x4 {
        instance * CoordinateMapper.engineToViewer
            * EngineMatrix.translation(-mesh.pivot)
    }

    private func pick(
        at point: CGPoint,
        in view: MTKView
    ) -> (pick: FacePick, t: Float)? {
        let ray = screenRay(at: point, in: view)
        var best: (pick: FacePick, t: Float)?
        for obj in objects {
            for inst in obj.instances {
                guard let hit = rayCastObject(ray, object: obj, model: inst.model) else { continue }
                if best == nil || hit.t < best!.t {
                    // object-space normal → viewer world → engine z-up
                    let columns = inst.model.columns
                    let world = hit.normal.x * SIMD3(columns.0.x, columns.0.y, columns.0.z)
                        + hit.normal.y * SIMD3(columns.1.x, columns.1.y, columns.1.z)
                        + hit.normal.z * SIMD3(columns.2.x, columns.2.y, columns.2.z)
                    let engine = CoordinateMapper.viewerToEngine * SIMD4<Float>(world, 0)
                    best = (FacePick(
                        objectID: obj.objectID,
                        instanceID: inst.instanceID,
                        engineNormal: simd_normalize(SIMD3<Double>(
                            Double(engine.x), Double(engine.y), Double(engine.z)
                        ))
                    ), hit.t)
                }
            }
        }
        return best
    }

    /// Ray vs one instance: world-space AABB pre-test, then exact test in
    /// object space (ray transformed by the inverse model matrix).
    /// Returns (distance, object-space face normal, merged-mesh triangle).
    private func rayCastObject(_ ray: (origin: SIMD3<Float>, dir: SIMD3<Float>),
                               object: RenderObject, model: simd_float4x4)
        -> (t: Float, normal: SIMD3<Float>, triangle: UInt32)? {
        // AABB in world space (transform 8 corners of the packed bbox).
        var bbMin = SIMD3<Float>(repeating: .infinity)
        var bbMax = SIMD3<Float>(repeating: -.infinity)
        for sx in [object.bboxMin.x, object.bboxMax.x] {
            for sy in [object.bboxMin.y, object.bboxMax.y] {
                for sz in [object.bboxMin.z, object.bboxMax.z] {
                    let w = SIMD3((model * SIMD4(sx, sy, sz, 1)).x,
                                 (model * SIMD4(sx, sy, sz, 1)).y,
                                 (model * SIMD4(sx, sy, sz, 1)).z)
                    bbMin = simd_min(bbMin, w)
                    bbMax = simd_max(bbMax, w)
                }
            }
        }
        // Slab test.
        let inv = 1 / simd_normalize(ray.dir)
        let t0 = (bbMin - ray.origin) * inv
        let t1 = (bbMax - ray.origin) * inv
        let tmin = simd_max(simd_max(simd_min(t0, t1).x, simd_min(t0, t1).y), simd_min(t0, t1).z)
        let tmax = simd_min(simd_min(simd_max(t0, t1).x, simd_max(t0, t1).y), simd_max(t0, t1).z)
        guard tmax >= max(tmin, 0) else { return nil }

        // Exact: transform ray into object space.
        let invModel = model.inverse
        let ro4 = invModel * SIMD4(ray.origin.x, ray.origin.y, ray.origin.z, 1)
        let near4 = invModel * SIMD4((ray.origin + ray.dir).x, (ray.origin + ray.dir).y, (ray.origin + ray.dir).z, 1)
        let ro = SIMD3(ro4.x, ro4.y, ro4.z) / ro4.w
        let rd = simd_normalize(SIMD3(near4.x, near4.y, near4.z) / near4.w - ro)

        var best: (t: Float, normal: SIMD3<Float>, triangle: UInt32)?
        rayCastTriangles(ro: ro, rd: rd, positions: object.pickPositions,
                         indices: object.pickIndices) { t, normal, triangle in
            if best == nil || t < best!.t {
                best = (t, normal, triangle)
            }
        }
        return best
    }

    /// Ray vs one raw object-space mesh behind a full model matrix.
    /// Returns the hit distance (object space) or nil.
    private func rayCastMesh(_ ray: (origin: SIMD3<Float>, dir: SIMD3<Float>),
                             mesh: SceneMesh, model: simd_float4x4) -> Float? {
        let invModel = model.inverse
        let ro4 = invModel * SIMD4(ray.origin.x, ray.origin.y, ray.origin.z, 1)
        let near4 = invModel * SIMD4((ray.origin + ray.dir).x, (ray.origin + ray.dir).y,
                                     (ray.origin + ray.dir).z, 1)
        let ro = SIMD3(ro4.x, ro4.y, ro4.z) / ro4.w
        let rd = simd_normalize(SIMD3(near4.x, near4.y, near4.z) / near4.w - ro)
        var bestT: Float?
        rayCastTriangles(ro: ro, rd: rd, positions: mesh.positions,
                         indices: mesh.indices) { t, _, _ in
            if bestT == nil || t < bestT! {
                bestT = t
            }
        }
        return bestT
    }

    /// Möller–Trumbore over an indexed triangle soup in the ray's own space;
    /// `onHit` receives (distance, face normal, triangle index).
    private func rayCastTriangles(
        ro: SIMD3<Float>, rd: SIMD3<Float>,
        positions: [SIMD3<Float>], indices: [UInt32],
        onHit: (Float, SIMD3<Float>, UInt32) -> Void
    ) {
        let triCount = indices.count / 3
        let e = Float.ulpOfOne
        for t in 0..<triCount {
            let i0 = Int(indices[t * 3]), i1 = Int(indices[t * 3 + 1]), i2 = Int(indices[t * 3 + 2])
            let a = positions[i0], b = positions[i1], c = positions[i2]
            let ab = b - a, ac = c - a
            let pvec = simd_cross(rd, ac)
            let det = simd_dot(ab, pvec)
            if abs(det) > e {
                let invDet = 1 / det
                let tvec = ro - a
                let u = simd_dot(tvec, pvec) * invDet
                if u >= 0 && u <= 1 {
                    let qvec = simd_cross(tvec, ab)
                    let v = simd_dot(rd, qvec) * invDet
                    if v >= 0 && u + v <= 1 {
                        let dist = simd_dot(ac, qvec) * invDet
                        if dist > 0.01 {
                            onHit(dist, simd_normalize(simd_cross(b - a, c - a)), UInt32(t))
                        }
                    }
                }
            }
        }
    }

    // MARK: MTKViewDelegate (invoked on the main thread)

    /// Viewer-space point → UIKit point in the view (nil behind the camera).
    func projectToScreen(_ point: SIMD3<Float>, in view: MTKView) -> CGPoint? {
        let size = view.bounds.size
        let aspect = Float(size.width / max(size.height, 1))
        let clip = camera.projection(aspect: aspect) * camera.viewMatrix
            * SIMD4(point.x, point.y, point.z, 1)
        guard clip.w > 1e-5 else { return nil }
        let ndc = SIMD2(clip.x, clip.y) / clip.w
        return CGPoint(
            x: CGFloat((ndc.x + 1) * 0.5) * size.width,
            y: CGFloat((1 - ndc.y) * 0.5) * size.height
        )
    }

    // MARK: Rectangle (marquee) selection — desktop "Select objects by rectangle"

    /// Live marquee feedback while the drag runs (view POINTS; nil clears).
    func setMarquee(_ rect: CGRect?) {
        marqueeRect = rect
    }

    /// Every instance whose projected bounding box overlaps `rect` (view
    /// points). Corners behind the camera are skipped; an instance with no
    /// visible corner is not selectable this way.
    func instancesIntersecting(rect: CGRect, in view: MTKView)
        -> [(objectID: ObjectID, instanceID: InstanceID)] {
        var hits: [(objectID: ObjectID, instanceID: InstanceID)] = []
        for obj in objects {
            outer: for inst in obj.instances {
                var minX = CGFloat.greatestFiniteMagnitude
                var minY = CGFloat.greatestFiniteMagnitude
                var maxX = -CGFloat.greatestFiniteMagnitude
                var maxY = -CGFloat.greatestFiniteMagnitude
                var visible = false
                for sx in [obj.bboxMin.x, obj.bboxMax.x] {
                    for sy in [obj.bboxMin.y, obj.bboxMax.y] {
                        for sz in [obj.bboxMin.z, obj.bboxMax.z] {
                            let world = SIMD3(
                                (inst.model * SIMD4(sx, sy, sz, 1)).x,
                                (inst.model * SIMD4(sx, sy, sz, 1)).y,
                                (inst.model * SIMD4(sx, sy, sz, 1)).z
                            )
                            guard let p = projectToScreen(world, in: view) else { continue }
                            visible = true
                            minX = min(minX, p.x); maxX = max(maxX, p.x)
                            minY = min(minY, p.y); maxY = max(maxY, p.y)
                        }
                    }
                }
                guard visible else { continue outer }
                let box = CGRect(
                    x: minX, y: minY,
                    width: maxX - minX, height: maxY - minY
                )
                if box.intersects(rect) {
                    hits.append((objectID: obj.objectID, instanceID: inst.instanceID))
                }
            }
        }
        return hits
    }

    // MARK: Gizmos (selected instance manipulation feedback)

    private(set) var gizmoMode: GizmoMode = .move
    private(set) var rotationAxis: EngineAxis = .z

    func setGizmo(mode: GizmoMode, rotationAxis: EngineAxis) {
        gizmoMode = mode
        self.rotationAxis = rotationAxis
    }

    /// Geometry of the selected instance's gizmo in viewer space: center on
    /// the bed plane, ring radius, current rotation direction, and model.
    struct SelectedGizmo {
        let center: SIMD3<Float>
        let radius: Float
        let rotationDirection: SIMD3<Float>
        let model: simd_float4x4
        let localMin: SIMD3<Float>
        let localMax: SIMD3<Float>
    }

    func selectedGizmo() -> SelectedGizmo? {
        if let primaryObjectID, let primaryInstanceID {
            return gizmo(objectID: primaryObjectID, instanceID: primaryInstanceID)
        }
        return gizmo { _, instance in instance.selected }
    }

    /// The primary selection (gizmo owner) of the applied scene.
    private var primaryObjectID: ObjectID?
    private var primaryInstanceID: InstanceID?

    /// Gizmo geometry for a specific instance (used when a drag selects and
    /// manipulates in one gesture, before the scene re-applies selection).
    func gizmo(objectID: ObjectID, instanceID: InstanceID) -> SelectedGizmo? {
        gizmo { object, instance in
            object.objectID == objectID && instance.instanceID == instanceID
        }
    }

    private func gizmo(
        matching predicate: (RenderObject, InstanceDraw) -> Bool
    ) -> SelectedGizmo? {
        for object in objects {
            guard let instance = object.instances.first(where: { predicate(object, $0) }) else { continue }
            let model = instance.model
            let column0 = SIMD3(model.columns.0.x, model.columns.0.y, model.columns.0.z)
            let scale = simd_length(column0)
            let origin = model * SIMD4<Float>(0, 0, 0, 1)
            let extent = object.bboxMax - object.bboxMin
            let halfDiagonal = 0.5 * simd_length(extent) * scale
            let flat = SIMD3(column0.x, 0, column0.z)
            let direction = simd_length(flat) > 1e-6 ? simd_normalize(flat) : SIMD3(1, 0, 0)
            return SelectedGizmo(
                center: SIMD3(origin.x, origin.y, origin.z),
                radius: halfDiagonal + 4,
                rotationDirection: direction,
                model: model,
                localMin: object.bboxMin,
                localMax: object.bboxMax
            )
        }
        return nil
    }

    private func gizmoVertices(_ gizmo: SelectedGizmo) -> [VertexPC] {
        var vertices: [VertexPC] = []
        let accent = SIMD4<Float>(0.16, 0.80, 0.95, 1)
        switch gizmoMode {
        case .layFlat, .select:
            // no on-canvas gizmo: lay flat taps a facet; select draws the
            // marquee rectangle instead
            break
        case .move:
            // Engine +X → viewer +X (red); engine +Y → viewer -Z (green),
            // drawn on the bed plane under the object.
            let red = SIMD4<Float>(0.95, 0.30, 0.25, 1)
            let green = SIMD4<Float>(0.35, 0.85, 0.35, 1)
            let bedCenter = SIMD3(gizmo.center.x, 0.15, gizmo.center.z)
            for (axis, color) in [(SIMD3<Float>(1, 0, 0), red), (SIMD3<Float>(0, 0, -1), green)] {
                let tip = bedCenter + axis * gizmo.radius
                let tail = bedCenter - axis * gizmo.radius
                let side = SIMD3(-axis.z, 0, axis.x) * 3
                vertices += [
                    VertexPC(position: tail, color: color), VertexPC(position: tip, color: color),
                    VertexPC(position: tip, color: color), VertexPC(position: tip - axis * 5 + side, color: color),
                    VertexPC(position: tip, color: color), VertexPC(position: tip - axis * 5 - side, color: color),
                ]
            }
        case .rotate:
            // Ring in the plane perpendicular to the selected world axis,
            // colored like desktop (X red, Y green, Z blue).
            let axis = CoordinateMapper.viewerAxis(rotationAxis)
            let (u, v): (SIMD3<Float>, SIMD3<Float>) = {
                switch rotationAxis {
                case .x: return (SIMD3(0, 1, 0), SIMD3(0, 0, 1))
                case .y: return (SIMD3(1, 0, 0), SIMD3(0, 1, 0))
                case .z: return (SIMD3(1, 0, 0), SIMD3(0, 0, 1))
                }
            }()
            let color: SIMD4<Float> = {
                switch rotationAxis {
                case .x: return SIMD4(0.95, 0.30, 0.25, 1)
                case .y: return SIMD4(0.35, 0.85, 0.35, 1)
                case .z: return SIMD4(0.30, 0.55, 1.00, 1)
                }
            }()
            let segments = 48
            for index in 0..<segments {
                let a0 = Float(index) / Float(segments) * 2 * .pi
                let a1 = Float(index + 1) / Float(segments) * 2 * .pi
                vertices.append(VertexPC(position: gizmo.center + (u * cos(a0) + v * sin(a0)) * gizmo.radius, color: color))
                vertices.append(VertexPC(position: gizmo.center + (u * cos(a1) + v * sin(a1)) * gizmo.radius, color: color))
            }
            // Axis line through the center so the rotation axis is explicit.
            vertices.append(VertexPC(position: gizmo.center - axis * gizmo.radius * 0.6, color: color))
            vertices.append(VertexPC(position: gizmo.center + axis * gizmo.radius * 0.6, color: color))
            if rotationAxis == .z {
                let white = SIMD4<Float>(1, 1, 1, 1)
                vertices.append(VertexPC(position: gizmo.center, color: white))
                vertices.append(VertexPC(position: gizmo.center + gizmo.rotationDirection * gizmo.radius, color: white))
            }
        case .scale:
            let lo = gizmo.localMin, hi = gizmo.localMax
            let corners: [SIMD3<Float>] = [
                SIMD3(lo.x, lo.y, lo.z), SIMD3(hi.x, lo.y, lo.z), SIMD3(hi.x, lo.y, hi.z), SIMD3(lo.x, lo.y, hi.z),
                SIMD3(lo.x, hi.y, lo.z), SIMD3(hi.x, hi.y, lo.z), SIMD3(hi.x, hi.y, hi.z), SIMD3(lo.x, hi.y, hi.z),
            ].map { corner in
                let world = gizmo.model * SIMD4(corner.x, corner.y, corner.z, 1)
                return SIMD3(world.x, world.y, world.z)
            }
            let edges = [(0, 1), (1, 2), (2, 3), (3, 0), (4, 5), (5, 6), (6, 7), (7, 4), (0, 4), (1, 5), (2, 6), (3, 7)]
            for (a, b) in edges {
                vertices.append(VertexPC(position: corners[a], color: accent))
                vertices.append(VertexPC(position: corners[b], color: accent))
            }
        }
        return vertices
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Aspect is derived per-frame from view.drawableSize; nothing to do.
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass)
        else {
            logger.fault("frame skipped: missing drawable/pass/buffer")
            return
        }

        let frameTime = Float(CACurrentMediaTime())
        if let last = lastFrameTime {
            camera.tick(deltaTime: min(max(frameTime - last, 0), 0.1))
        }
        lastFrameTime = frameTime

        let aspect = Float(view.drawableSize.width / max(view.drawableSize.height, 1))
        let viewProj = camera.projection(aspect: aspect) * camera.viewMatrix

        // Grid (bed)
        lineUniforms.mvp = viewProj
        encoder.pushDebugGroup("bed")
        encoder.setRenderPipelineState(linePipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setVertexBuffer(gridVB, offset: 0, index: 0)
        var lu = lineUniforms
        encoder.setVertexBytes(&lu, length: MemoryLayout<LineUniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: gridVertexCount)
        encoder.popDebugGroup()

        // Inactive plate outlines (ABI v27): dimmed rectangles beside the
        // rendered bed, drawn on top of the grid but under the objects.
        if !plateOutlineVertices.isEmpty {
            encoder.pushDebugGroup("plates")
            encoder.setRenderPipelineState(linePipeline)
            encoder.setDepthStencilState(overlayDepthState)
            var plateUniforms = LineUniforms(mvp: viewProj)
            encoder.setVertexBytes(
                &plateUniforms,
                length: MemoryLayout<LineUniforms>.stride, index: 1
            )
            var outlines = plateOutlineVertices
            encoder.setVertexBytes(
                &outlines,
                length: MemoryLayout<VertexPC>.stride * outlines.count,
                index: 0
            )
            encoder.drawPrimitives(
                type: .line, vertexStart: 0,
                vertexCount: outlines.count
            )
            encoder.popDebugGroup()
        }

        // Objects × instances — uploaded vertices are viewer-space, recentred
        // (identity model base); each instance applies its own transform.
        // Before them: the selection outline shell (inverted hull — the
        // object's own front faces occlude the expanded back faces, leaving
        // a silhouette halo; depth-written so it participates in occlusion).
        if objects.contains(where: { $0.instances.contains(where: \.selected) }) {
            encoder.pushDebugGroup("selection-outline")
            encoder.setRenderPipelineState(outlinePipeline)
            encoder.setDepthStencilState(depthState)
            for obj in objects where obj.indexCount > 0 {
                encoder.setVertexBuffer(obj.vb, offset: 0, index: 0)
                for inst in obj.instances where inst.selected {
                    // A mirrored (left-handed) matrix flips winding: cull the
                    // other face set so the shell stays a halo.
                    encoder.setCullMode(inst.mirrored ? .back : .front)
                    outlineUniforms.mvp = viewProj * inst.model
                    outlineUniforms.model = inst.model
                    outlineUniforms.color = Renderer.outlineColor
                    outlineUniforms.width = obj.outlineWidth
                    var ou = outlineUniforms
                    encoder.setVertexBytes(
                        &ou, length: MemoryLayout<OutlineUniforms>.stride, index: 1)
                    encoder.setFragmentBytes(
                        &ou, length: MemoryLayout<OutlineUniforms>.stride, index: 1)
                    encoder.drawIndexedPrimitives(
                        type: .triangle, indexCount: obj.indexCount, indexType: .uint32,
                        indexBuffer: obj.ib, indexBufferOffset: 0)
                }
            }
            encoder.setCullMode(.none)
            encoder.popDebugGroup()
        }
        encoder.pushDebugGroup("objects")
        encoder.setRenderPipelineState(litPipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)
        for obj in objects {
            guard obj.indexCount > 0, !obj.instances.isEmpty else { continue }
            encoder.setVertexBuffer(obj.vb, offset: 0, index: 0)
            // Other plates render DIMMED (multi-plate visibility); the
            // current plate draws normally. Off-plate opacity handled by
            // the color choice below.
            for inst in obj.instances {
                let model = inst.model
                cubeUniforms.mvp = viewProj * model
                cubeUniforms.model = model
                var color = inst.selected ? Renderer.selectedColor
                    : (inst.printable ? Renderer.objectColor : Renderer.unprintableColor)
                if !inst.selected, inst.printable,
                   inst.extruder >= 1, inst.extruder <= filamentColors.count {
                    color = filamentColors[inst.extruder - 1]
                }
                if inst.plate != currentPlateIndex {
                    // inactive plate: clearly visible but faded (alpha blend
                    // would need the blend pipeline; darken toward bg)
                    color = SIMD4<Float>(color.x * 0.45 + 0.03, color.y * 0.45 + 0.03,
                                         color.z * 0.45 + 0.03, color.w)
                }
                cubeUniforms.color = color
                cubeUniforms.normalSign = inst.mirrored ? -1 : 1
                var cu = cubeUniforms
                encoder.setVertexBytes(&cu, length: MemoryLayout<CubeUniforms>.stride, index: 1)
                encoder.setFragmentBytes(&cu, length: MemoryLayout<CubeUniforms>.stride, index: 1)
                encoder.drawIndexedPrimitives(
                    type: .triangle, indexCount: obj.indexCount, indexType: .uint32,
                    indexBuffer: obj.ib, indexBufferOffset: 0, instanceCount: 1)
            }
        }
        encoder.popDebugGroup()

        // Translucent volumes (modifiers / negatives / blockers / enforcers)
        // over the opaque parts: depth-tested, not depth-writing. A selected
        // volume is tinted instead of its role color.
        encoder.pushDebugGroup("volumes")
        encoder.setRenderPipelineState(litBlendPipeline)
        encoder.setDepthStencilState(translucentDepthState)
        encoder.setCullMode(.none)
        for obj in objects {
            for draw in obj.volumes where draw.indexCount > 0 {
                encoder.setVertexBuffer(draw.vb, offset: 0, index: 0)
                for inst in obj.instances {
                    cubeUniforms.mvp = viewProj * inst.model
                    cubeUniforms.model = inst.model
                    cubeUniforms.color = obj.selectedVolumeID == draw.volumeID
                        ? Renderer.selectedVolumeColor : draw.color
                    cubeUniforms.normalSign = inst.mirrored ? -1 : 1
                    var cu = cubeUniforms
                    encoder.setVertexBytes(&cu, length: MemoryLayout<CubeUniforms>.stride, index: 1)
                    encoder.setFragmentBytes(&cu, length: MemoryLayout<CubeUniforms>.stride, index: 1)
                    encoder.drawIndexedPrimitives(
                        type: .triangle, indexCount: draw.indexCount, indexType: .uint32,
                        indexBuffer: draw.ib, indexBufferOffset: 0)
                }
            }
        }
        encoder.popDebugGroup()

        // Selected PART highlight (ABI v26 part ranges): the part's
        // merged-mesh sub-range re-drawn translucent over the opaque object.
        encoder.pushDebugGroup("selected part")
        encoder.setRenderPipelineState(litBlendPipeline)
        encoder.setDepthStencilState(translucentDepthState)
        encoder.setCullMode(.none)
        for obj in objects {
            guard let volumeID = obj.selectedVolumeID,
                  let range = obj.partRanges.first(where: { $0.volumeID == volumeID }),
                  range.count > 0 else { continue }
            encoder.setVertexBuffer(obj.vb, offset: 0, index: 0)
            for inst in obj.instances where inst.selected {
                cubeUniforms.mvp = viewProj * inst.model
                cubeUniforms.model = inst.model
                cubeUniforms.color = Renderer.selectedVolumeColor
                cubeUniforms.normalSign = inst.mirrored ? -1 : 1
                var cu = cubeUniforms
                encoder.setVertexBytes(&cu, length: MemoryLayout<CubeUniforms>.stride, index: 1)
                encoder.setFragmentBytes(&cu, length: MemoryLayout<CubeUniforms>.stride, index: 1)
                encoder.drawIndexedPrimitives(
                    type: .triangle,
                    indexCount: Int(range.count) * 3,
                    indexType: .uint32,
                    indexBuffer: obj.ib,
                    indexBufferOffset: Int(range.start) * 3 * MemoryLayout<UInt32>.stride)
            }
        }
        encoder.popDebugGroup()

        // Flatten planes (desktop GLGizmoFlatten): translucent fills under
        // the line overlays; desktop colors FLATTEN / FLATTEN_HOVER.
        if gizmoMode == .layFlat, !flattenPlanes.isEmpty {
            encoder.pushDebugGroup("flatten-planes")
            var fill: [VertexPC] = []
            var outline: [VertexPC] = []
            for (index, plane) in flattenPlanes.enumerated() {
                let highlighted = index == flattenHighlightIndex
                let color = highlighted
                    ? SIMD4<Float>(1.0, 0.4, 0.4, 0.75)   // hover: clearly visible on touch
                    : SIMD4<Float>(0.96, 0.93, 0.93, 0.5)
                guard plane.vertices.count >= 3 else { continue }
                for triangle in 1..<(plane.vertices.count - 1) {
                    fill.append(VertexPC(position: plane.vertices[0], color: color))
                    fill.append(VertexPC(position: plane.vertices[triangle], color: color))
                    fill.append(VertexPC(position: plane.vertices[triangle + 1], color: color))
                }
                for vertex in plane.vertices {
                    outline.append(VertexPC(position: vertex, color: color))
                }
                outline.append(VertexPC(position: plane.vertices[0], color: color))
            }
            if !fill.isEmpty {
                encoder.setRenderPipelineState(pcBlendPipeline)
                encoder.setDepthStencilState(translucentDepthState)
                var gizmoUniforms = LineUniforms(mvp: viewProj)
                encoder.setVertexBytes(&gizmoUniforms, length: MemoryLayout<LineUniforms>.stride, index: 1)
                encoder.setVertexBytes(&fill, length: MemoryLayout<VertexPC>.stride * fill.count, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: fill.count)
            }
            if outline.count >= 2 {
                encoder.setRenderPipelineState(linePipeline)
                encoder.setDepthStencilState(overlayDepthState)
                var gizmoUniforms = LineUniforms(mvp: viewProj)
                encoder.setVertexBytes(&gizmoUniforms, length: MemoryLayout<LineUniforms>.stride, index: 1)
                encoder.setVertexBytes(&outline, length: MemoryLayout<VertexPC>.stride * outline.count, index: 0)
                encoder.drawPrimitives(type: .lineStrip, vertexStart: 0, vertexCount: outline.count)
            }
            encoder.popDebugGroup()
        }

        // Gizmo overlay: always on top so it stays readable inside meshes.
        if let gizmo = selectedGizmo() {
            var vertices = gizmoVertices(gizmo)
            if !vertices.isEmpty {
                encoder.pushDebugGroup("gizmo")
                encoder.setRenderPipelineState(linePipeline)
                encoder.setDepthStencilState(overlayDepthState)
                var gizmoUniforms = LineUniforms(mvp: viewProj)
                encoder.setVertexBytes(&gizmoUniforms, length: MemoryLayout<LineUniforms>.stride, index: 1)
                encoder.setVertexBytes(
                    &vertices,
                    length: MemoryLayout<VertexPC>.stride * vertices.count,
                    index: 0
                )
                encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: vertices.count)
                encoder.popDebugGroup()
            }
        }

        // Marquee (rectangle selection): a screen-space rectangle drawn with
        // an identity transform — view points map 1:1 onto NDC here.
        if let rect = marqueeRect, abs(rect.width) > 1, abs(rect.height) > 1,
           view.bounds.size.width > 0, view.bounds.size.height > 0 {
            let size = view.bounds.size
            func corner(_ x: CGFloat, _ y: CGFloat) -> SIMD3<Float> {
                SIMD3(
                    Float(x / size.width * 2 - 1),
                    Float(1 - 2 * y / size.height),
                    0.05 // just inside the near plane
                )
            }
            let color = Renderer.selectedVolumeColor
            let c0 = corner(rect.minX, rect.minY)
            let c1 = corner(rect.maxX, rect.minY)
            let c2 = corner(rect.maxX, rect.maxY)
            let c3 = corner(rect.minX, rect.maxY)
            var vertices = [
                VertexPC(position: c0, color: color),
                VertexPC(position: c1, color: color),
                VertexPC(position: c1, color: color),
                VertexPC(position: c2, color: color),
                VertexPC(position: c2, color: color),
                VertexPC(position: c3, color: color),
                VertexPC(position: c3, color: color),
                VertexPC(position: c0, color: color)
            ]
            encoder.pushDebugGroup("marquee")
            encoder.setRenderPipelineState(linePipeline)
            encoder.setDepthStencilState(overlayDepthState)
            var identity = LineUniforms(mvp: matrix_identity_float4x4)
            encoder.setVertexBytes(&identity, length: MemoryLayout<LineUniforms>.stride, index: 1)
            encoder.setVertexBytes(
                &vertices,
                length: MemoryLayout<VertexPC>.stride * vertices.count,
                index: 0
            )
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: vertices.count)
            encoder.popDebugGroup()
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()

        trackFPS()
    }

    // MARK: Status publishing

    private func trackFPS() {
        let now = CACurrentMediaTime()
        frameTimes.append(now)
        frameTimes.removeAll { $0 < now - 1.0 }
        if now - lastStatusPublish > 1.0 {
            status.fps = frameTimes.count
            publishStatus()
            lastStatusPublish = now
        }
    }

    private func publishStatus() {
        if let err = status.pipelineError {
            onStatus("Metal: ERROR — \(err)")
        } else {
            onStatus("Metal: OK · \(status.fps) fps · MSL runtime-compiled")
        }
    }
}

// MARK: - Uniform structs (must match MSL structs in Shaders.swift)

struct CubeUniforms {
    var mvp: simd_float4x4
    var model: simd_float4x4
    var color: SIMD4<Float>
    var lightDir: SIMD3<Float>
    var normalSign: Float
}

struct LineUniforms {
    var mvp: simd_float4x4
}

/// Field order MUST stay identical to `OutlineUniforms` in Shaders.swift
/// (runtime-compiled MSL; see LESSONS).
struct OutlineUniforms {
    var mvp: simd_float4x4
    var model: simd_float4x4
    var color: SIMD4<Float>
    var width: Float
}
