import MetalKit
import OrcaBridge
import SwiftUI

/// SwiftUI wrapper around the gcode toolpath MTKView: orbit/zoom/pan
/// gestures plus camera framing on first appearance.
@MainActor
struct GcodeCanvas: UIViewRepresentable {
    let onStatus: (String) -> Void
    let segments: [ToolpathSegment]
    let loadedPath: String?
    let visibleSegmentCount: Int
    let bed: EngineBed
    let boundsMin: SIMD3<Float>
    let boundsMax: SIMD3<Float>

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.depthStencilPixelFormat = .depth32Float
        view.sampleCount = 4
        view.clearColor = MTLClearColor(
            red: 0.075,
            green: 0.078,
            blue: 0.093,
            alpha: 1
        )
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 60
        context.coordinator.attach(
            view: view,
            segments: segments,
            loadedPath: loadedPath,
            visibleSegmentCount: visibleSegmentCount,
            bed: bed,
            boundsMin: boundsMin,
            boundsMax: boundsMax,
            onStatus: onStatus
        )
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.renderer?.rebuild(
            segments: segments,
            loadedPath: loadedPath,
            visibleSegmentCount: visibleSegmentCount,
            bed: bed
        )
    }

    @MainActor
    final class Coordinator: NSObject {
        var renderer: ToolpathRenderer?
        var boundsMin: SIMD3<Float> = .zero
        var boundsMax: SIMD3<Float> = .zero

        func attach(
            view: MTKView,
            segments: [ToolpathSegment],
            loadedPath: String?,
            visibleSegmentCount: Int,
            bed: EngineBed,
            boundsMin: SIMD3<Float>,
            boundsMax: SIMD3<Float>,
            onStatus: @escaping (String) -> Void
        ) {
            renderer = ToolpathRenderer(
                view: view,
                segments: segments,
                loadedPath: loadedPath,
                visibleSegmentCount: visibleSegmentCount,
                bed: bed,
                onStatus: onStatus
            )

            let tap = UITapGestureRecognizer(
                target: self,
                action: #selector(onDoubleTap(_:))
            )
            tap.numberOfTapsRequired = 2
            view.addGestureRecognizer(tap)

            let orbit = UIPanGestureRecognizer(
                target: self,
                action: #selector(onOrbit(_:))
            )
            orbit.minimumNumberOfTouches = 1
            orbit.maximumNumberOfTouches = 1
            view.addGestureRecognizer(orbit)

            let pan = UIPanGestureRecognizer(
                target: self,
                action: #selector(onPan(_:))
            )
            pan.minimumNumberOfTouches = 2
            pan.maximumNumberOfTouches = 2
            view.addGestureRecognizer(pan)

            let pinch = UIPinchGestureRecognizer(
                target: self,
                action: #selector(onPinch(_:))
            )
            view.addGestureRecognizer(pinch)

            self.boundsMin = boundsMin
            self.boundsMax = boundsMax
            frameCamera(
                boundsMin: boundsMin,
                boundsMax: boundsMax
            )
        }

        private func frameCamera(
            boundsMin: SIMD3<Float>,
            boundsMax: SIMD3<Float>
        ) {
            guard let renderer else { return }
            let camera = renderer.camera
            let center = (boundsMin + boundsMax) * 0.5
            let size = boundsMax - boundsMin
            let maxDim = max(size.x, max(size.y, size.z))
            guard maxDim.isFinite, maxDim > 0 else { return }
            camera.target = center * SIMD3<Float>(1, 0.9, 1)
            camera.distance = min(max(maxDim * 2.6, 110), 1400)
            camera.pitch = 0.42
            camera.yaw = -0.65
        }

        @objc private func onDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.view is MTKView else { return }
            frameCamera(boundsMin: boundsMin, boundsMax: boundsMax)
        }

        @objc private func onOrbit(_ gesture: UIPanGestureRecognizer) {
            guard let renderer else { return }
            let translation = gesture.translation(in: gesture.view)
            renderer.camera.orbit(
                dx: Float(translation.x),
                dy: Float(translation.y)
            )
            gesture.setTranslation(.zero, in: gesture.view)
        }

        @objc private func onPan(_ gesture: UIPanGestureRecognizer) {
            guard let renderer else { return }
            let translation = gesture.translation(in: gesture.view)
            renderer.camera.pan(
                dx: Float(translation.x),
                dy: Float(translation.y)
            )
            gesture.setTranslation(.zero, in: gesture.view)
        }

        @objc private func onPinch(_ gesture: UIPinchGestureRecognizer) {
            guard let renderer else { return }
            renderer.camera.zoom(by: Float(gesture.scale))
            gesture.scale = 1
        }
    }
}
