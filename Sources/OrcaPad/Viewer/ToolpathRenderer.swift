// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

import MetalKit
import OrcaBridge
import os
import simd

/// Toolpath palettes keyed by the ENGINE's own ExtrusionRole values (see
/// orca_bridge.h — never the libvgcode ordering) plus a desktop-style
/// gradient for scalar color modes.
enum ToolpathPalette {
    static let travel = SIMD4<Float>(0.40, 0.44, 0.52, 1)
    /// Wipe moves: faintly warmer than travel so both stay secondary.
    static let wipe = SIMD4<Float>(0.50, 0.46, 0.34, 1)

    static func color(role: UInt8) -> SIMD4<Float> {
        switch role {
        case 1: return SIMD4(1.00, 0.90, 0.30, 1) // inner wall
        case 2: return SIMD4(1.00, 0.49, 0.22, 1) // outer wall
        case 3: return SIMD4(0.12, 0.12, 1.00, 1) // overhang wall
        case 4: return SIMD4(0.69, 0.19, 0.16, 1) // sparse infill
        case 5: return SIMD4(0.59, 0.33, 0.80, 1) // internal solid infill
        case 6: return SIMD4(0.70, 0.22, 0.22, 1) // top surface
        case 7: return SIMD4(0.40, 0.36, 0.78, 1) // bottom surface
        case 8: return SIMD4(1.00, 0.55, 0.41, 1) // ironing
        case 9: return SIMD4(0.30, 0.50, 0.73, 1) // bridge
        case 10: return SIMD4(0.30, 0.50, 0.73, 1) // internal bridge
        case 11: return SIMD4(1.00, 1.00, 1.00, 1) // gap infill
        case 12: return SIMD4(0.00, 0.53, 0.43, 1) // skirt
        case 13: return SIMD4(0.00, 0.53, 0.43, 1) // brim
        case 14: return SIMD4(0.00, 1.00, 0.00, 1) // support
        case 15: return SIMD4(0.12, 0.38, 0.12, 1) // support interface
        case 16: return SIMD4(0.00, 0.25, 0.00, 1) // support transition
        case 17: return SIMD4(0.70, 0.89, 0.67, 1) // prime tower
        case 18: return SIMD4(0.37, 0.82, 0.58, 1) // custom
        case 19: return SIMD4(0.50, 0.50, 0.50, 1) // multiple
        default: return SIMD4(0.70, 0.70, 0.70, 1)
        }
    }

    /// Blue → cyan → green → yellow → red over t ∈ [0, 1].
    static func gradient(_ t: Float) -> SIMD4<Float> {
        let stops: [SIMD3<Float>] = [
            SIMD3(0.04, 0.17, 0.48), SIMD3(0.07, 0.56, 0.78),
            SIMD3(0.09, 0.71, 0.32), SIMD3(0.89, 0.83, 0.10),
            SIMD3(0.89, 0.18, 0.10),
        ]
        let clamped = min(max(t.isFinite ? t : 0, 0), 1)
        let scaled = clamped * Float(stops.count - 1)
        let index = min(Int(scaled), stops.count - 2)
        let fraction = scaled - Float(index)
        let mixed = stops[index] + (stops[index + 1] - stops[index]) * fraction
        return SIMD4(mixed, 1)
    }
}

/// Everything that requires rebuilding GPU buffers. Slider movement changes
/// only `ToolpathDrawRange` and never rebuilds.
struct ToolpathBuildKey: Equatable {
    let loadedPath: String?
    let colorMode: ToolpathColorMode
    let hiddenRoles: Set<UInt8>
    let showTravel: Bool
    let showSeams: Bool
    let showRetractions: Bool
    /// Desktop visibility options: wipe moves (lines) and tool-change
    /// markers (points).
    let showWipes: Bool
    let showToolChanges: Bool
    let bed: EngineBed
}

struct ToolpathDrawRange: Equatable {
    let lowerLayer: Int
    let upperLayer: Int
    let topLayerProgress: Int
}

/// Draws the parsed gcode toolpath through the shared runtime-MSL flat
/// pipeline: extrusions as width-true "tent" ribbons (two-tone profile for
/// depth), travels as lines. Buffers are built once per build key; per-layer
/// prefix offsets let layer/move scrubbing draw index ranges directly.
@MainActor
final class ToolpathRenderer: NSObject, MTKViewDelegate {
    /// Above this many visible extrusion segments, extrusions fall back to
    /// lines to bound GPU memory on phones (reported via status).
    static let ribbonBudget = 450_000

    private let logger = Logger(subsystem: "ie.duz.OrcaPad", category: "gcode")
    private let onStatus: (String) -> Void

    let device: MTLDevice
    let camera = OrbitCamera()
    private var commandQueue: MTLCommandQueue!
    private var flatPipeline: MTLRenderPipelineState!
    private var depthState: MTLDepthStencilState!

    private var bedVB: MTLBuffer?
    private var bedVertexCount = 0

    // Extrusions: ribbons (indexed, 12 indices/segment) or lines (2 verts).
    private var extrusionVB: MTLBuffer?
    private var extrusionIB: MTLBuffer?
    private var extrusionsAsRibbons = true
    private var extrusionPrefix: [UInt32] = [0]
    // Travels: lines, 2 vertices/segment.
    private var travelVB: MTLBuffer?
    private var travelPrefix: [UInt32] = [0]
    // Marker moves (seams/retracts): 6-vertex crosses.
    private var markerVB: MTLBuffer?
    private var markerPrefix: [UInt32] = [0]

    private var layerFirstSegment: [Int] = []
    private var appliedKey: ToolpathBuildKey?
    private var drawRange = ToolpathDrawRange(lowerLayer: 0, upperLayer: 0, topLayerProgress: 0)
    private var toolPosition: SIMD3<Float>?

    init?(view: MTKView, onStatus: @escaping (String) -> Void) {
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
            let library = try device.makeLibrary(source: Shaders.msl, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "gcode-flat"
            guard let vertex = library.makeFunction(name: "vertexFlat"),
                  let fragment = library.makeFunction(name: "fragmentFlat") else {
                onStatus("ERROR: Metal: missing flat shader functions")
                return nil
            }
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.vertexDescriptor = Renderer.pcVertexDescriptor()
            descriptor.rasterSampleCount = view.sampleCount
            descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
            descriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat
            flatPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            onStatus("ERROR: \(String(describing: error))")
            return nil
        }
        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        guard let depth = device.makeDepthStencilState(descriptor: depthDescriptor) else {
            onStatus("ERROR: depth stencil creation failed")
            return nil
        }
        depthState = depth
        view.delegate = self
        logger.notice("toolpath renderer online")
    }

    // MARK: Build (expensive; only on build-key changes)

    func configure(key: ToolpathBuildKey, store: GcodePreviewStore) {
        guard key != appliedKey else { return }
        appliedKey = key

        let grid = Geometry.bedGrid(for: key.bed)
        bedVertexCount = grid.count
        bedVB = grid.isEmpty ? nil : device.makeBuffer(
            bytes: grid,
            length: MemoryLayout<VertexPC>.stride * grid.count,
            options: .storageModeShared
        )

        guard let toolpath = store.toolpath else {
            extrusionVB = nil; extrusionIB = nil; travelVB = nil; markerVB = nil
            extrusionPrefix = [0]; travelPrefix = [0]; markerPrefix = [0]; layerFirstSegment = []
            return
        }

        let segments = toolpath.segments
        layerFirstSegment = toolpath.layers.map(\.firstSegment)
        let center = key.bed.center

        var extrusionCount = 0
        for segment in segments
        where segment.isExtrusion && !key.hiddenRoles.contains(segment.role) {
            extrusionCount += 1
        }
        extrusionsAsRibbons = extrusionCount <= Self.ribbonBudget
        if !extrusionsAsRibbons {
            onStatus("preview: \(extrusionCount) extrusions exceed the ribbon budget — drawing lines")
        }

        var extrusionVertices: [VertexPC] = []
        var extrusionIndices: [UInt32] = []
        var travelVertices: [VertexPC] = []
        var markerVertices: [VertexPC] = []
        extrusionVertices.reserveCapacity(extrusionCount * (extrusionsAsRibbons ? 6 : 2))
        if extrusionsAsRibbons { extrusionIndices.reserveCapacity(extrusionCount * 12) }
        var extrusionPrefix = [UInt32](repeating: 0, count: segments.count + 1)
        var travelPrefix = [UInt32](repeating: 0, count: segments.count + 1)
        var markerPrefix = [UInt32](repeating: 0, count: segments.count + 1)
        var extruded: UInt32 = 0
        var travelled: UInt32 = 0
        var markers: UInt32 = 0

        func viewer(_ point: SIMD3<Float>) -> SIMD3<Float> {
            CoordinateMapper.viewerPoint(fromEngine: point, bedCenter: center)
        }

        for (index, segment) in segments.enumerated() {
            if segment.isExtrusion {
                if !key.hiddenRoles.contains(segment.role) {
                    let color = Self.color(segment, mode: key.colorMode, store: store)
                    if extrusionsAsRibbons {
                        if Self.appendRibbon(
                            segment, color: color, viewer: viewer,
                            vertices: &extrusionVertices, indices: &extrusionIndices
                        ) {
                            extruded += 1
                        }
                    } else {
                        extrusionVertices.append(VertexPC(position: viewer(segment.start), color: color))
                        extrusionVertices.append(VertexPC(position: viewer(segment.end), color: color))
                        extruded += 1
                    }
                }
            } else if segment.isPoint {
                // ABI v14 marker moves: world-space cross at the point
                // (desktop seam/retraction visibility options).
                let visible: Bool
                switch segment.moveType {
                case .seam: visible = key.showSeams
                case .retract, .unretract: visible = key.showRetractions
                case .toolChange: visible = key.showToolChanges
                default: visible = false
                }
                if visible {
                    let p = viewer(segment.start)
                    let color = Self.markerColor(segment.moveType)
                    let s: Float = 0.5
                    markerVertices.append(contentsOf: [
                        VertexPC(position: p + SIMD3(-s, 0, 0), color: color),
                        VertexPC(position: p + SIMD3(s, 0, 0), color: color),
                        VertexPC(position: p + SIMD3(0, 0, -s), color: color),
                        VertexPC(position: p + SIMD3(0, 0, s), color: color),
                        VertexPC(position: p + SIMD3(0, -s, 0), color: color),
                        VertexPC(position: p + SIMD3(0, s, 0), color: color),
                    ])
                    markers += 1
                }
            } else if segment.moveType == .wipe {
                // Desktop "Wipe" visibility option: wipe moves are short
                // LINE segments (not markers) with their own toggle.
                if key.showWipes {
                    travelVertices.append(VertexPC(position: viewer(segment.start), color: ToolpathPalette.wipe))
                    travelVertices.append(VertexPC(position: viewer(segment.end), color: ToolpathPalette.wipe))
                    travelled += 1
                }
            } else if key.showTravel {
                travelVertices.append(VertexPC(position: viewer(segment.start), color: ToolpathPalette.travel))
                travelVertices.append(VertexPC(position: viewer(segment.end), color: ToolpathPalette.travel))
                travelled += 1
            }
            extrusionPrefix[index + 1] = extruded
            travelPrefix[index + 1] = travelled
            markerPrefix[index + 1] = markers
        }

        self.extrusionPrefix = extrusionPrefix
        self.travelPrefix = travelPrefix
        self.markerPrefix = markerPrefix
        extrusionVB = Self.buffer(device, extrusionVertices)
        extrusionIB = extrusionsAsRibbons ? Self.buffer(device, extrusionIndices) : nil
        travelVB = Self.buffer(device, travelVertices)
        markerVB = Self.buffer(device, markerVertices)
        logger.notice("toolpath built: \(extruded) extrusions, \(travelled) travels, \(markers) markers")
    }

    private static func buffer<Element>(_ device: MTLDevice, _ elements: [Element]) -> MTLBuffer? {
        guard !elements.isEmpty else { return nil }
        return elements.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return nil }
            return device.makeBuffer(bytes: base, length: bytes.count, options: .storageModeShared)
        }
    }

    /// Desktop marker colors: seams orange, retracts red/green.
    private static func markerColor(_ type: ToolpathSegment.MoveType) -> SIMD4<Float> {
        switch type {
        case .seam: return SIMD4(1.0, 0.55, 0.0, 1)
        case .retract: return SIMD4(0.95, 0.25, 0.25, 1)
        case .unretract: return SIMD4(0.3, 0.85, 0.3, 1)
        case .toolChange: return SIMD4(0.65, 0.45, 1.0, 1)
        default: return SIMD4(0.4, 0.6, 1.0, 1)
        }
    }

    private static func color(
        _ segment: ToolpathSegment,
        mode: ToolpathColorMode,
        store: GcodePreviewStore
    ) -> SIMD4<Float> {
        func normalized(_ value: Float, _ range: ClosedRange<Float>) -> Float {
            (value - range.lowerBound) / max(range.upperBound - range.lowerBound, 0.0001)
        }
        func normalizedLog(_ value: Float, _ range: ClosedRange<Float>) -> Float {
            // desktop LayerTimeLogarithmic: log scale (ms domain, clamped)
            let lo = log2(max(range.lowerBound, 0.001) * 1000)
            let hi = log2(max(range.upperBound, 0.001) * 1000)
            let v = log2(max(value, 0.001) * 1000)
            return (v - lo) / max(hi - lo, 0.0001)
        }
        switch mode {
        case .feature: return ToolpathPalette.color(role: segment.role)
        case .speed: return ToolpathPalette.gradient(normalized(segment.feedrate, store.feedrateRange))
        case .layerHeight: return ToolpathPalette.gradient(normalized(segment.height, store.heightRange))
        case .lineWidth: return ToolpathPalette.gradient(normalized(segment.width, store.widthRange))
        case .fanSpeed: return ToolpathPalette.gradient(normalized(segment.fanSpeed, store.fanRange))
        case .temperature: return ToolpathPalette.gradient(normalized(segment.temperature, store.temperatureRange))
        case .volumetricRate: return ToolpathPalette.gradient(normalized(segment.volumetricRate, store.volumetricRange))
        case .actualVolumetricRate: return ToolpathPalette.gradient(normalized(segment.actualVolumetricRate, store.actualVolumetricRange))
        case .actualSpeed: return ToolpathPalette.gradient(normalized(segment.actualFeedrate, store.actualSpeedRange))
        case .layerTime: return ToolpathPalette.gradient(normalized(segment.layerDuration, store.layerTimeRange))
        case .layerTimeLog: return ToolpathPalette.gradient(normalizedLog(segment.layerDuration, store.layerTimeRange))
        case .pressureAdvance: return ToolpathPalette.gradient(normalized(segment.pressureAdvance, store.pressureAdvanceRange))
        case .acceleration: return ToolpathPalette.gradient(normalized(segment.acceleration, store.accelerationRange))
        case .jerk: return ToolpathPalette.gradient(normalized(segment.jerk, store.jerkRange))
        case .tool: return ToolpathPalette.gradient(normalized(Float(segment.extruder), store.toolRange))
        }
    }

    /// Tent profile: two low edges (half layer height down) and a raised
    /// ridge give width-true extrusions a cheap tube-like shading. Returns
    /// false for zero-length segments (no direction).
    private static func appendRibbon(
        _ segment: ToolpathSegment,
        color: SIMD4<Float>,
        viewer: (SIMD3<Float>) -> SIMD3<Float>,
        vertices: inout [VertexPC],
        indices: inout [UInt32]
    ) -> Bool {
        let delta = SIMD2(segment.end.x - segment.start.x, segment.end.y - segment.start.y)
        let length = simd_length(delta)
        guard length > 1e-5 else { return false }
        let direction = delta / length
        let halfWidth = max(segment.width, 0.05) * 0.5
        let drop = max(segment.height, 0.02) * 0.5
        let side = SIMD3(-direction.y * halfWidth, direction.x * halfWidth, 0)
        let lowered = SIMD3<Float>(0, 0, -drop)
        let edge = SIMD4(color.x * 0.55, color.y * 0.55, color.z * 0.55, 1)

        let base = UInt32(vertices.count)
        vertices.append(VertexPC(position: viewer(segment.start - side + lowered), color: edge))
        vertices.append(VertexPC(position: viewer(segment.start), color: color))
        vertices.append(VertexPC(position: viewer(segment.start + side + lowered), color: edge))
        vertices.append(VertexPC(position: viewer(segment.end - side + lowered), color: edge))
        vertices.append(VertexPC(position: viewer(segment.end), color: color))
        vertices.append(VertexPC(position: viewer(segment.end + side + lowered), color: edge))
        indices.append(contentsOf: [
            base, base + 3, base + 4, base, base + 4, base + 1,
            base + 1, base + 4, base + 5, base + 1, base + 5, base + 2,
        ])
        return true
    }

    // MARK: Draw range (cheap; every slider change)

    func setDrawRange(_ range: ToolpathDrawRange, toolPosition: SIMD3<Float>?) {
        drawRange = range
        if let toolPosition, let bed = appliedKey?.bed {
            self.toolPosition = CoordinateMapper.viewerPoint(
                fromEngine: toolPosition,
                bedCenter: bed.center
            )
        } else {
            self.toolPosition = nil
        }
    }

    private func segmentWindow() -> Range<Int>? {
        guard !layerFirstSegment.isEmpty,
              drawRange.lowerLayer < layerFirstSegment.count,
              drawRange.upperLayer < layerFirstSegment.count,
              drawRange.lowerLayer <= drawRange.upperLayer else { return nil }
        let start = layerFirstSegment[drawRange.lowerLayer]
        let end = layerFirstSegment[drawRange.upperLayer] + drawRange.topLayerProgress
        let clampedEnd = min(end, extrusionPrefix.count - 1)
        guard clampedEnd > start else { return nil }
        return start..<clampedEnd
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass)
        else { return }

        let aspect = Float(view.drawableSize.width / max(view.drawableSize.height, 1))
        var uniforms = LineUniforms(mvp: camera.projection(aspect: aspect) * camera.viewMatrix)
        encoder.setRenderPipelineState(flatPipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<LineUniforms>.stride, index: 1)

        if let bedVB, bedVertexCount > 0 {
            encoder.setVertexBuffer(bedVB, offset: 0, index: 0)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: bedVertexCount)
        }

        if let window = segmentWindow() {
            let firstExtrusion = Int(extrusionPrefix[window.lowerBound])
            let extrusionCount = Int(extrusionPrefix[window.upperBound]) - firstExtrusion
            if extrusionCount > 0, let extrusionVB {
                encoder.setVertexBuffer(extrusionVB, offset: 0, index: 0)
                if extrusionsAsRibbons, let extrusionIB {
                    encoder.drawIndexedPrimitives(
                        type: .triangle,
                        indexCount: extrusionCount * 12,
                        indexType: .uint32,
                        indexBuffer: extrusionIB,
                        indexBufferOffset: firstExtrusion * 12 * MemoryLayout<UInt32>.stride
                    )
                } else {
                    encoder.drawPrimitives(
                        type: .line,
                        vertexStart: firstExtrusion * 2,
                        vertexCount: extrusionCount * 2
                    )
                }
            }
            let firstTravel = Int(travelPrefix[window.lowerBound])
            let travelCount = Int(travelPrefix[window.upperBound]) - firstTravel
            if travelCount > 0, let travelVB {
                encoder.setVertexBuffer(travelVB, offset: 0, index: 0)
                encoder.drawPrimitives(
                    type: .line,
                    vertexStart: firstTravel * 2,
                    vertexCount: travelCount * 2
                )
            }
            let firstMarker = Int(markerPrefix[window.lowerBound])
            let markerCount = Int(markerPrefix[window.upperBound]) - firstMarker
            if markerCount > 0, let markerVB {
                encoder.setVertexBuffer(markerVB, offset: 0, index: 0)
                encoder.drawPrimitives(
                    type: .line,
                    vertexStart: firstMarker * 6,
                    vertexCount: markerCount * 6
                )
            }
        }

        if let toolPosition {
            let white = SIMD4<Float>(1, 1, 1, 1)
            let size: Float = 2.5
            var marker: [VertexPC] = [
                VertexPC(position: toolPosition + SIMD3(-size, 0, 0), color: white),
                VertexPC(position: toolPosition + SIMD3(size, 0, 0), color: white),
                VertexPC(position: toolPosition, color: white),
                VertexPC(position: toolPosition + SIMD3(0, size * 2, 0), color: white),
                VertexPC(position: toolPosition + SIMD3(0, 0, -size), color: white),
                VertexPC(position: toolPosition + SIMD3(0, 0, size), color: white),
            ]
            encoder.setVertexBytes(&marker, length: MemoryLayout<VertexPC>.stride * marker.count, index: 0)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: marker.count)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
