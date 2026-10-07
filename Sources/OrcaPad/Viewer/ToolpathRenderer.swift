import MetalKit
import OrcaBridge
import os
import simd

/// OrcaSlicer-viewer-style feature palette keyed by the ENGINE's own
/// ExtrusionRole values (see orca_bridge.h — never the libvgcode ordering).
enum ToolpathPalette {
    static func color(role: UInt8, isTravel: Bool) -> SIMD4<Float> {
        if isTravel {
            return SIMD4(0.42, 0.45, 0.50, 0.28)
        }
        switch role {
        case 1: return SIMD4(0.85, 0.20, 0.14, 1) // perimeter
        case 2: return SIMD4(0.95, 0.36, 0.10, 1) // external perimeter
        case 3: return SIMD4(0.90, 0.52, 0.13, 1) // overhang perimeter
        case 4: return SIMD4(0.24, 0.42, 0.87, 1) // internal infill
        case 5: return SIMD4(0.29, 0.62, 0.24, 1) // solid infill
        case 6: return SIMD4(0.95, 0.80, 0.12, 1) // top solid infill
        case 7: return SIMD4(0.40, 0.78, 0.74, 1) // bottom surface
        case 8: return SIMD4(0.35, 0.35, 0.35, 1) // ironing
        case 9: return SIMD4(0.91, 0.62, 0.16, 1) // bridge infill
        case 10: return SIMD4(0.72, 0.62, 0.31, 1) // internal bridge
        case 11: return SIMD4(0.94, 0.37, 0.83, 1) // gap fill
        case 12: return SIMD4(0.51, 0.28, 0.79, 1) // skirt
        case 13: return SIMD4(0.36, 0.24, 0.67, 1) // brim
        case 14: return SIMD4(0.60, 0.60, 0.60, 1) // support material
        case 15: return SIMD4(0.78, 0.78, 0.78, 1) // support interface
        case 16: return SIMD4(0.66, 0.66, 0.85, 1) // support transition
        case 17: return SIMD4(0.40, 0.62, 0.87, 1) // wipe tower
        case 18: return SIMD4(0.67, 0.67, 1.00, 1) // custom
        case 19: return SIMD4(0.25, 0.55, 0.85, 1) // mixed
        default: return SIMD4(0.7, 0.7, 0.7, 1)
        }
    }
}

/// Draws the parsed gcode toolpath as feature-colored lines through the
/// shared runtime-MSL line pipeline. Derived GPU state only — the C++
/// document and the toolpath data remain untouched.
@MainActor
final class ToolpathRenderer: NSObject, MTKViewDelegate {
    private let logger = Logger(subsystem: "ie.duz.OrcaPad", category: "gcode")
    private let onStatus: (String) -> Void

    let device: MTLDevice
    let camera = OrbitCamera()
    private var commandQueue: MTLCommandQueue!
    private var linePipeline: MTLRenderPipelineState!
    private var depthState: MTLDepthStencilState!

    private var lineVB: MTLBuffer?
    private var lineCount = 0
    private var bedVB: MTLBuffer!
    private var bedLineCount = 0
    private var lineUniforms = LineUniforms(mvp: .init(diagonal: .one))
    private var appliedSignature: ToolpathSignature?

    private struct ToolpathSignature: Equatable {
        let loadedPath: String?
        let visibleSegmentCount: Int
        let bed: EngineBed
    }

    init?(view: MTKView,
          segments: [ToolpathSegment],
          loadedPath: String?,
          visibleSegmentCount: Int,
          bed: EngineBed,
          onStatus: @escaping (String) -> Void) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice() else {
            onStatus("ERROR: no Metal device")
            return nil
        }
        self.device = device
        self.onStatus = onStatus
        super.init()

        guard let queue = device.makeCommandQueue() else {
            onStatus("ERROR: command queue creation failed")
            return nil
        }
        commandQueue = queue
        do {
            let library = try device.makeLibrary(
                source: Shaders.msl,
                options: nil
            )
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "gcode-lines"
            descriptor.vertexFunction = try function(library, "vertexFlat")
            descriptor.fragmentFunction = try function(library, "fragmentFlat")
            descriptor.vertexDescriptor = Renderer.pcVertexDescriptor()
            descriptor.rasterSampleCount = view.sampleCount
            descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
            descriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat
            linePipeline = try device.makeRenderPipelineState(descriptor: descriptor)

            let depthDescriptor = MTLDepthStencilDescriptor()
            depthDescriptor.depthCompareFunction = .less
            depthDescriptor.isDepthWriteEnabled = true
            guard let depth = device.makeDepthStencilState(descriptor: depthDescriptor) else {
                onStatus("ERROR: depth stencil creation failed")
                return nil
            }
            depthState = depth
        } catch {
            onStatus("ERROR: \(String(describing: error))")
            return nil
        }

        let grid = Geometry.bedGrid(for: bed)
        bedLineCount = grid.count
        bedVB = device.makeBuffer(
            bytes: grid,
            length: MemoryLayout<VertexPC>.stride * grid.count,
            options: .storageModeShared
        )
        rebuild(
            segments: segments,
            loadedPath: loadedPath,
            visibleSegmentCount: visibleSegmentCount,
            bed: bed
        )
        view.delegate = self
        logger.notice("toolpath renderer online")
    }

    private func function(_ library: MTLLibrary, _ name: String) throws -> MTLFunction {
        guard let fn = library.makeFunction(name: name) else {
            throw RuntimeError("Metal: missing function \(name)")
        }
        return fn
    }

    private struct RuntimeError: Error, CustomStringConvertible {
        let message: String
        init(_ message: String) { self.message = message }
        var description: String { message }
    }

    /// Rebuilds the line vertex buffer when the toolpath identity, the
    /// visible prefix, or the bed changes. Positions are mapped into the
    /// bed-centered viewer frame. `segments` passes by copy-on-write.
    func rebuild(segments: [ToolpathSegment],
                 loadedPath: String?,
                 visibleSegmentCount: Int,
                 bed: EngineBed) {
        let signature = ToolpathSignature(
            loadedPath: loadedPath,
            visibleSegmentCount: visibleSegmentCount,
            bed: bed
        )
        guard signature != appliedSignature else { return }
        appliedSignature = signature

        var vertices: [VertexPC] = []
        let count = min(visibleSegmentCount, segments.count)
        if count > 0 {
            vertices.reserveCapacity(count * 2)
            let center = bed.center
            for index in 0..<count {
                let segment = segments[index]
                let color = ToolpathPalette.color(
                    role: segment.role,
                    isTravel: !segment.isExtrusion
                )
                vertices.append(VertexPC(
                    position: CoordinateMapper.viewerPoint(
                        fromEngine: segment.start,
                        bedCenter: center
                    ),
                    color: color
                ))
                vertices.append(VertexPC(
                    position: CoordinateMapper.viewerPoint(
                        fromEngine: segment.end,
                        bedCenter: center
                    ),
                    color: color
                ))
            }
        }
        lineCount = vertices.count
        lineVB = vertices.isEmpty
            ? nil
            : device.makeBuffer(
                bytes: vertices,
                length: MemoryLayout<VertexPC>.stride * vertices.count,
                options: .storageModeShared
            )
        logger.notice("toolpath lines rebuilt: \(self.lineCount / 2) segments")
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass)
        else { return }

        let aspect = Float(
            view.drawableSize.width / max(view.drawableSize.height, 1)
        )
        let viewProj = camera.projection(aspect: aspect) * camera.viewMatrix

        encoder.pushDebugGroup("gcode")
        encoder.setRenderPipelineState(linePipeline)
        encoder.setDepthStencilState(depthState)

        if bedLineCount > 0, let bedVB {
            lineUniforms.mvp = viewProj
            var uniform = lineUniforms
            encoder.setVertexBuffer(bedVB, offset: 0, index: 0)
            encoder.setVertexBytes(
                &uniform,
                length: MemoryLayout<LineUniforms>.stride,
                index: 1
            )
            encoder.drawPrimitives(
                type: .line,
                vertexStart: 0,
                vertexCount: bedLineCount
            )
        }

        if lineCount > 0, let lineVB {
            lineUniforms.mvp = viewProj
            var uniform = lineUniforms
            encoder.setVertexBuffer(lineVB, offset: 0, index: 0)
            encoder.setVertexBytes(
                &uniform,
                length: MemoryLayout<LineUniforms>.stride,
                index: 1
            )
            encoder.drawPrimitives(
                type: .line,
                vertexStart: 0,
                vertexCount: lineCount
            )
        }

        encoder.popDebugGroup()
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
