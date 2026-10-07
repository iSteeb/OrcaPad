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
}

/// One immutable instance draw derived from a revisioned scene snapshot.
private struct InstanceDraw {
    let instanceID: InstanceID
    let model: simd_float4x4
    let selected: Bool
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
    private var linePipeline: MTLRenderPipelineState!
    private var depthState: MTLDepthStencilState!
    private var overlayDepthState: MTLDepthStencilState!

    // Bed grid
    private var gridVB: MTLBuffer!
    private var gridVertexCount: Int = 0

    // Scene objects (GPU buffers + CPU picking copies + instance matrices)
    private struct RenderObject {
        let objectID: ObjectID
        let meshRevision: UInt64
        let vb: MTLBuffer
        let ib: MTLBuffer
        let indexCount: Int
        let bboxMin: SIMD3<Float>   // object-local (packed) space
        let bboxMax: SIMD3<Float>
        let pickPositions: [SIMD3<Float>]  // packed viewer-space (pre-instance)
        let pickIndices: [UInt32]
        var instances: [InstanceDraw]
    }
    private var objects: [RenderObject] = []
    private var documentID: DocumentID?
    private var appliedRevision = DocumentRevision(rawValue: 0)
    private var bed: EngineBed = .fallback

    private static let objectColor = SIMD4<Float>(0.96, 0.52, 0.11, 1)
    private static let selectedColor = SIMD4<Float>(0.16, 0.80, 0.95, 1)

    // Frame uniforms
    private var cubeUniforms = CubeUniforms(
        mvp: .init(diagonal: .one),
        model: .init(diagonal: .one),
        color: SIMD4<Float>(0.96, 0.52, 0.11, 1),
        lightDir: SIMD3<Float>(0.35, -0.85, 0.40),
        pad: 0
    )
    private var lineUniforms = LineUniforms(mvp: .init(diagonal: .one))

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
        linePipeline = try device.makeRenderPipelineState(descriptor: lineDesc)

        let depthDesc = MTLDepthStencilDescriptor()
        depthDesc.depthCompareFunction = .less
        depthDesc.isDepthWriteEnabled = true
        guard let ds = device.makeDepthStencilState(descriptor: depthDesc) else {
            throw MetalError.missing("depth stencil state")
        }
        depthState = ds

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
        previewTransform: InstanceTransform?
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
                let usesPreview = sceneObject.id == selectedObjectID &&
                    instance.id == selectedInstanceID
                return InstanceDraw(
                    instanceID: instance.id,
                    model: CoordinateMapper.modelMatrix(
                        transform: usesPreview
                            ? previewTransform ?? instance.transform
                            : instance.transform,
                        enginePivot: sceneObject.mesh.pivot,
                        bedCenter: bed.center
                    ),
                    selected: sceneObject.id == selectedObjectID &&
                        instance.id == selectedInstanceID
                )
            }

            if let existing = objects.first(where: {
                $0.objectID == sceneObject.id &&
                    $0.meshRevision == sceneObject.mesh.revision
            }) {
                var reused = existing
                reused.instances = instances
                rebuilt.append(reused)
                continue
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
            rebuilt.append(RenderObject(
                objectID: sceneObject.id,
                meshRevision: sceneObject.mesh.revision,
                vb: vertexBuffer,
                ib: indexBuffer,
                indexCount: geometry.idx.count,
                bboxMin: bounds.minimum,
                bboxMax: bounds.maximum,
                pickPositions: positions,
                pickIndices: geometry.idx,
                instances: instances
            ))
        }

        objects = rebuilt
        documentID = scene.documentID
        appliedRevision = scene.revision
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
    func frameScene() {
        var bbMin = SIMD3<Float>(repeating: .infinity)
        var bbMax = SIMD3<Float>(repeating: -.infinity)
        var any = false
        for obj in objects {
            for inst in obj.instances {
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
                    any = true
                }
            }
        }
        guard any else { return }
        let size = bbMax - bbMin
        let maxDim = max(size.x, max(size.y, size.z))
        camera.target = (bbMin + bbMax) * 0.5 * SIMD3(1, 0.9, 1)
        camera.distance = min(max(maxDim * 2.6, 110), 1400)
        camera.pitch = 0.42
        camera.yaw = -0.65
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
        let ray = screenRay(at: point, in: view)
        var best: (objectID: ObjectID, instanceID: InstanceID, t: Float)?
        for obj in objects {
            for inst in obj.instances {
                guard let tHit = rayCastObject(ray, object: obj, model: inst.model) else { continue }
                if best == nil || tHit < best!.t {
                    best = (obj.objectID, inst.instanceID, tHit)
                }
            }
        }
        guard let b = best else { return nil }
        return (b.objectID, b.instanceID)
    }

    /// Ray vs one instance: world-space AABB pre-test, then exact test in
    /// object space (ray transformed by the inverse model matrix).
    private func rayCastObject(_ ray: (origin: SIMD3<Float>, dir: SIMD3<Float>),
                               object: RenderObject, model: simd_float4x4) -> Float? {
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

        let p = object.pickPositions
        let idx = object.pickIndices
        var bestT: Float? = nil
        var t = 0, i0 = 0, i1 = 0, i2 = 0
        let triCount = idx.count / 3
        let e = Float.ulpOfOne
        while t < triCount {
            i0 = Int(idx[t * 3]); i1 = Int(idx[t * 3 + 1]); i2 = Int(idx[t * 3 + 2])
            let a = p[i0], b = p[i1], c = p[i2]
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
                        if dist > 0.01 && (bestT == nil || dist < bestT!) {
                            bestT = dist
                        }
                    }
                }
            }
            t += 1
        }
        return bestT
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

    // MARK: Gizmos (selected instance manipulation feedback)

    private(set) var gizmoMode: GizmoMode = .move

    func setGizmoMode(_ mode: GizmoMode) { gizmoMode = mode }

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
        gizmo { _, instance in instance.selected }
    }

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
            let halfDiagonal = 0.5 * simd_length(SIMD2(extent.x, extent.z)) * scale
            let flat = SIMD3(column0.x, 0, column0.z)
            let direction = simd_length(flat) > 1e-6 ? simd_normalize(flat) : SIMD3(1, 0, 0)
            return SelectedGizmo(
                center: SIMD3(origin.x, 0.15, origin.z),
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
        case .move:
            // Engine +X → viewer +X (red); engine +Y → viewer -Z (green).
            let red = SIMD4<Float>(0.95, 0.30, 0.25, 1)
            let green = SIMD4<Float>(0.35, 0.85, 0.35, 1)
            for (axis, color) in [(SIMD3<Float>(1, 0, 0), red), (SIMD3<Float>(0, 0, -1), green)] {
                let tip = gizmo.center + axis * gizmo.radius
                let tail = gizmo.center - axis * gizmo.radius
                let side = SIMD3(-axis.z, 0, axis.x) * 3
                vertices += [
                    VertexPC(position: tail, color: color), VertexPC(position: tip, color: color),
                    VertexPC(position: tip, color: color), VertexPC(position: tip - axis * 5 + side, color: color),
                    VertexPC(position: tip, color: color), VertexPC(position: tip - axis * 5 - side, color: color),
                ]
            }
        case .rotate:
            let segments = 48
            for index in 0..<segments {
                let a0 = Float(index) / Float(segments) * 2 * .pi
                let a1 = Float(index + 1) / Float(segments) * 2 * .pi
                vertices.append(VertexPC(position: gizmo.center + SIMD3(cos(a0), 0, sin(a0)) * gizmo.radius, color: accent))
                vertices.append(VertexPC(position: gizmo.center + SIMD3(cos(a1), 0, sin(a1)) * gizmo.radius, color: accent))
            }
            let white = SIMD4<Float>(1, 1, 1, 1)
            vertices.append(VertexPC(position: gizmo.center, color: white))
            vertices.append(VertexPC(position: gizmo.center + gizmo.rotationDirection * gizmo.radius, color: white))
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

        // Objects × instances — uploaded vertices are viewer-space, recentred
        // (identity model base); each instance applies its own transform.
        encoder.pushDebugGroup("objects")
        encoder.setRenderPipelineState(litPipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)
        for obj in objects {
            guard obj.indexCount > 0, !obj.instances.isEmpty else { continue }
            encoder.setVertexBuffer(obj.vb, offset: 0, index: 0)
            for inst in obj.instances {
                let model = inst.model
                cubeUniforms.mvp = viewProj * model
                cubeUniforms.model = model
                cubeUniforms.color = inst.selected ? Renderer.selectedColor : Renderer.objectColor
                var cu = cubeUniforms
                encoder.setVertexBytes(&cu, length: MemoryLayout<CubeUniforms>.stride, index: 1)
                encoder.setFragmentBytes(&cu, length: MemoryLayout<CubeUniforms>.stride, index: 1)
                encoder.drawIndexedPrimitives(
                    type: .triangle, indexCount: obj.indexCount, indexType: .uint32,
                    indexBuffer: obj.ib, indexBufferOffset: 0, instanceCount: 1)
            }
        }
        encoder.popDebugGroup()

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
    var pad: Float
}

struct LineUniforms {
    var mvp: simd_float4x4
}
