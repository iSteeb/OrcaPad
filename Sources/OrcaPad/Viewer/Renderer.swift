import MetalKit
import os
import simd

/// Owns all Metal state and draws one frame per display-link tick.
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

    // Scene buffers
    private var cubeVB: MTLBuffer!
    private var cubeIB: MTLBuffer!
    private var cubeIndexCount: Int = 0
    private var gridVB: MTLBuffer!
    private var gridVertexCount: Int = 0

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
        buildScene()
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
    }

    private func function(_ library: MTLLibrary, _ name: String) throws -> MTLFunction {
        guard let fn = library.makeFunction(name: name) else {
            throw MetalError.missing("function \(name)")
        }
        return fn
    }

    private enum MetalError: Error, CustomStringConvertible {
        case missing(String)
        var description: String {
            switch self {
            case .missing(let what): return "Metal: missing \(what)"
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

    private static func pcVertexDescriptor() -> MTLVertexDescriptor {
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

    private func buildScene() {
        let (cubeVerts, cubeIdx) = Geometry.unitCube()
        cubeIndexCount = cubeIdx.count
        cubeVB = device.makeBuffer(
            bytes: cubeVerts, length: MemoryLayout<VertexPNC>.stride * cubeVerts.count,
            options: .storageModeShared)
        cubeIB = device.makeBuffer(
            bytes: cubeIdx, length: MemoryLayout<UInt32>.stride * cubeIdx.count,
            options: .storageModeShared)

        let grid = Geometry.bedGrid()
        gridVertexCount = grid.count
        gridVB = device.makeBuffer(
            bytes: grid, length: MemoryLayout<VertexPC>.stride * grid.count,
            options: .storageModeShared)
    }

    // MARK: MTKViewDelegate (invoked on the main thread)

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

        // Cube (calibration stand-in object)
        let model = Math.translate(SIMD3<Float>(0, 10, 0)) * Math.scale(20)
        cubeUniforms.mvp = viewProj * model
        cubeUniforms.model = model
        encoder.pushDebugGroup("object")
        encoder.setRenderPipelineState(litPipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)
        encoder.setVertexBuffer(cubeVB, offset: 0, index: 0)
        var cu = cubeUniforms
        encoder.setVertexBytes(&cu, length: MemoryLayout<CubeUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&cu, length: MemoryLayout<CubeUniforms>.stride, index: 1)
        encoder.drawIndexedPrimitives(
            type: .triangle, indexCount: cubeIndexCount, indexType: .uint32,
            indexBuffer: cubeIB, indexBufferOffset: 0, instanceCount: 1)
        encoder.popDebugGroup()

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
