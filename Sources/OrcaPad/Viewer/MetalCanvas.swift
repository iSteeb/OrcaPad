import MetalKit
import SwiftUI

/// SwiftUI wrapper around MTKView + gesture recognizers.
@MainActor
struct MetalCanvas: UIViewRepresentable {
    /// Receives human-readable renderer status (called on the main thread).
    let onStatus: (String) -> Void

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
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        // Nothing to update yet; renderer owns continuous drawing.
    }

    // MARK: Coordinator — gestures → camera

    @MainActor
    final class Coordinator: NSObject {
        var renderer: Renderer?

        func attach(view: MTKView, onStatus: @escaping (String) -> Void) {
            renderer = Renderer(view: view, onStatus: onStatus)

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

        @objc private func onOrbit(_ g: UIPanGestureRecognizer) {
            let t = g.translation(in: g.view)
            renderer?.camera.orbit(dx: Float(t.x), dy: Float(t.y))
            g.setTranslation(.zero, in: g.view)
        }

        @objc private func onPan(_ g: UIPanGestureRecognizer) {
            let t = g.translation(in: g.view)
            renderer?.camera.pan(dx: Float(t.x), dy: Float(t.y))
            g.setTranslation(.zero, in: g.view)
        }

        @objc private func onPinch(_ g: UIPinchGestureRecognizer) {
            renderer?.camera.zoom(by: Float(g.scale))
            g.scale = 1
        }
    }
}
