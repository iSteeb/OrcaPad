import MetalKit
import SwiftUI

/// Scene sync payload from PlaterView. Tokens change when the corresponding
/// payload changes; the coordinator applies diffs on updateUIView.
struct SceneSync {
    /// nil = no structural change since the last applied meshesToken.
    var meshes: [SceneObjectUpload]?
    var meshesToken: UUID
    var instances: [Int: [InstanceDraw]]
    var instancesToken: UUID
    /// Bump to re-frame the camera on the whole scene.
    var frameToken: UUID
}

/// SwiftUI wrapper around MTKView + gesture recognizers.
///
/// Gesture model (v1):
/// - tap: select instance (nearest ray hit); tap empty space deselects
/// - one-finger drag on the SELECTED instance: move it on the bed plane
/// - one-finger drag elsewhere: orbit
/// - two-finger drag: pan; pinch: zoom
@MainActor
struct MetalCanvas: UIViewRepresentable {
    /// Receives human-readable renderer status (called on the main thread).
    let onStatus: (String) -> Void
    /// Full scene state; token changes trigger renderer sync.
    var scene: SceneSync
    /// objectID, instanceID of the tapped instance (-1, -1) = deselect.
    let onSelect: (Int, Int) -> Void
    /// Engine-space bed-plane delta (mm) while dragging the selected instance.
    let onMoveSelected: (SIMD2<Float>) -> Void
    /// Drag finished — commit the accumulated move to the engine.
    let onMoveEnded: () -> Void

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
        context.coordinator.attach(
            view: view, onStatus: onStatus,
            onSelect: onSelect, onMoveSelected: onMoveSelected, onMoveEnded: onMoveEnded)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        let c = context.coordinator
        if scene.meshesToken != c.lastMeshesToken {
            c.lastMeshesToken = scene.meshesToken
            if let meshes = scene.meshes {
                c.renderer?.setObjectMeshes(meshes)
            }
        }
        if scene.instancesToken != c.lastInstancesToken {
            c.lastInstancesToken = scene.instancesToken
            for (objectID, list) in scene.instances {
                c.renderer?.setInstances(objectID: objectID, list)
            }
        }
        if scene.frameToken != c.lastFrameToken {
            c.lastFrameToken = scene.frameToken
            c.renderer?.frameScene()
        }
    }

    // MARK: Coordinator — gestures + renderer lifetime

    @MainActor
    final class Coordinator: NSObject {
        var renderer: Renderer?
        var lastMeshesToken: UUID?
        var lastInstancesToken: UUID?
        var lastFrameToken: UUID?

        private var onSelect: ((Int, Int) -> Void)?
        private var onMoveSelected: ((SIMD2<Float>) -> Void)?
        private var onMoveEnded: (() -> Void)?
        private var moveState: (bedOrigin: SIMD3<Float>, active: Bool)?

        func attach(view: MTKView,
                    onStatus: @escaping (String) -> Void,
                    onSelect: @escaping (Int, Int) -> Void,
                    onMoveSelected: @escaping (SIMD2<Float>) -> Void,
                    onMoveEnded: @escaping () -> Void) {
            renderer = Renderer(view: view, onStatus: onStatus)
            self.onSelect = onSelect
            self.onMoveSelected = onMoveSelected
            self.onMoveEnded = onMoveEnded

            let tap = UITapGestureRecognizer(target: self, action: #selector(onTap(_:)))
            view.addGestureRecognizer(tap)

            let orbit = UIPanGestureRecognizer(target: self, action: #selector(onOrbitOrMove(_:)))
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

        @objc private func onTap(_ g: UITapGestureRecognizer) {
            guard let view = g.view as? MTKView, let r = renderer else { return }
            let loc = g.location(in: view)
            if let hit = r.pickInstance(at: loc, in: view) {
                onSelect?(hit.objectID, hit.instanceID)
            } else {
                onSelect?(-1, -1)
            }
        }

        @objc private func onOrbitOrMove(_ g: UIPanGestureRecognizer) {
            guard let view = g.view as? MTKView, let r = renderer else { return }
            let loc = g.location(in: view)
            switch g.state {
            case .began:
                // Move only when the drag starts ON the selected instance;
                // everything else orbits.
                if let hit = r.pickInstance(at: loc, in: view),
                   let bed = r.bedPlaneHit(at: loc, in: view),
                   isSelected(hit) {
                    moveState = (bed, true)
                } else {
                    moveState = nil
                }
            case .changed:
                if moveState != nil, let bed = r.bedPlaneHit(at: loc, in: view),
                   let origin = moveState?.bedOrigin {
                    let d = bed - origin
                    // viewer (x, z) → engine (x, y): y_engine = -z_viewer
                    onMoveSelected?(SIMD2(d.x, -d.z))
                    moveState = (bed, true)
                } else {
                    let t = g.translation(in: g.view)
                    r.camera.orbit(dx: Float(t.x), dy: Float(t.y))
                    g.setTranslation(.zero, in: g.view)
                }
            case .ended, .cancelled:
                if moveState != nil {
                    moveState = nil
                    onMoveEnded?()
                }
            default:
                break
            }
        }

        private func isSelected(_ hit: (objectID: Int, instanceID: Int)) -> Bool {
            // The renderer already knows which instances carry the selected
            // flag (delivered via setInstances).
            renderer.map { r in
                r.selectedInstanceIDs.contains { $0.objectID == hit.objectID && $0.instanceID == hit.instanceID }
            } ?? false
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
