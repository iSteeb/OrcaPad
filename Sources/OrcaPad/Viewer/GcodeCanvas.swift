import MetalKit
import OrcaBridge
import SwiftUI

/// SwiftUI wrapper around the gcode toolpath MTKView. Build-key changes
/// (file, color mode, filters, bed) rebuild GPU buffers; draw-range changes
/// (layer range, in-layer progress) only move index windows.
@MainActor
struct GcodeCanvas: UIViewRepresentable {
    let onStatus: (String) -> Void
    let store: GcodePreviewStore
    let buildKey: ToolpathBuildKey
    let drawRange: ToolpathDrawRange
    let toolPosition: SIMD3<Float>?
    /// Bump to re-frame the camera on the whole toolpath.
    let frameRequest: Int

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.depthStencilPixelFormat = .depth32Float
        view.sampleCount = 4
        view.clearColor = MTLClearColor(red: 0.075, green: 0.078, blue: 0.093, alpha: 1)
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 60
        context.coordinator.attach(view: view, onStatus: onStatus)
        apply(to: context.coordinator)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        apply(to: context.coordinator)
    }

    private func apply(to coordinator: Coordinator) {
        guard let renderer = coordinator.renderer else { return }
        renderer.configure(key: buildKey, store: store)
        renderer.setDrawRange(drawRange, toolPosition: toolPosition)
        if coordinator.appliedFrameRequest != frameRequest {
            coordinator.appliedFrameRequest = frameRequest
            coordinator.frame(
                boundsMin: store.boundsMin,
                boundsMax: store.boundsMax,
                bed: buildKey.bed
            )
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var renderer: ToolpathRenderer?
        var appliedFrameRequest: Int?
        private var lastBounds: (SIMD3<Float>, SIMD3<Float>, EngineBed)?

        func attach(view: MTKView, onStatus: @escaping (String) -> Void) {
            renderer = ToolpathRenderer(view: view, onStatus: onStatus)

            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(onDoubleTap(_:)))
            doubleTap.numberOfTapsRequired = 2
            view.addGestureRecognizer(doubleTap)

            let orbit = UIPanGestureRecognizer(target: self, action: #selector(onOrbit(_:)))
            orbit.minimumNumberOfTouches = 1
            orbit.maximumNumberOfTouches = 1
            view.addGestureRecognizer(orbit)

            let pan = UIPanGestureRecognizer(target: self, action: #selector(onPan(_:)))
            pan.minimumNumberOfTouches = 2
            pan.maximumNumberOfTouches = 2
            view.addGestureRecognizer(pan)

            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(onPinch(_:)))
            view.addGestureRecognizer(pinch)
        }

        /// Frames the camera on the toolpath bounds in the bed-centered
        /// viewer frame (engine z-up → viewer y-up).
        func frame(boundsMin: SIMD3<Float>, boundsMax: SIMD3<Float>, bed: EngineBed) {
            lastBounds = (boundsMin, boundsMax, bed)
            guard let camera = renderer?.camera else { return }
            let center = (boundsMin + boundsMax) * 0.5
            let size = boundsMax - boundsMin
            let maxDim = max(size.x, max(size.y, size.z))
            guard maxDim.isFinite, maxDim > 0 else { return }
            let viewerCenter = CoordinateMapper.viewerPoint(fromEngine: center, bedCenter: bed.center)
            camera.target = SIMD3(viewerCenter.x, max(viewerCenter.y * 0.9, 0), viewerCenter.z)
            camera.distance = min(max(maxDim * 2.6, 60), 1400)
            camera.pitch = 0.55
            camera.yaw = -0.65
        }

        @objc private func onDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let lastBounds else { return }
            frame(boundsMin: lastBounds.0, boundsMax: lastBounds.1, bed: lastBounds.2)
        }

        @objc private func onOrbit(_ gesture: UIPanGestureRecognizer) {
            guard let renderer else { return }
            let translation = gesture.translation(in: gesture.view)
            renderer.camera.orbit(dx: Float(translation.x), dy: Float(translation.y))
            gesture.setTranslation(.zero, in: gesture.view)
        }

        @objc private func onPan(_ gesture: UIPanGestureRecognizer) {
            guard let renderer else { return }
            let translation = gesture.translation(in: gesture.view)
            renderer.camera.pan(dx: Float(translation.x), dy: Float(translation.y))
            gesture.setTranslation(.zero, in: gesture.view)
        }

        @objc private func onPinch(_ gesture: UIPinchGestureRecognizer) {
            renderer?.camera.zoom(by: Float(gesture.scale))
            gesture.scale = 1
        }
    }
}
