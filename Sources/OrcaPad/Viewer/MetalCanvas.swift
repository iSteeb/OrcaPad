import MetalKit
import OrcaBridge
import SwiftUI

/// Complete renderer input derived from one authoritative document snapshot.
/// presentationRevision advances for transient client-side gesture previews;
/// frameRequest advances only for explicit camera framing requests.
struct SceneSync {
    var snapshot: SceneSnapshot
    var bed: EngineBed
    var selectedObjectID: ObjectID?
    var selectedInstanceID: InstanceID?
    /// Live gesture preview of the selected instance (engine-frame matrix).
    var previewMatrix: simd_float4x4?
    var presentationRevision: UInt64
    var frameRequest: UInt64
    var gizmoMode: GizmoMode
    var rotationAxis: EngineAxis
}

/// Manipulation callbacks from the canvas gestures (engine-space units).
struct CanvasManipulation {
    let onSelect: (ObjectID?, InstanceID?) -> Void
    /// Incremental bed-plane translation in engine millimetres.
    let onMove: (SIMD2<Float>) -> Void
    let onBegin: () -> Void
    /// Total rotation since gesture start about the selected world axis,
    /// radians (right-handed).
    let onRotate: (Double) -> Void
    /// Total uniform scale factor since gesture start.
    let onScale: (Double) -> Void
    let onEnd: () -> Void
}

/// SwiftUI wrapper around MTKView + gesture recognizers.
///
/// Gesture model (desktop gizmo parity, touch-first):
/// - tap: select instance (nearest ray hit); tap empty space deselects
/// - one-finger drag starting on an instance (or the rotate/scale gizmo
///   ring of the selection): manipulate per gizmo mode — move on the bed
///   plane, rotate around the ring (screen-space angle), or scale (vertical)
/// - one-finger drag elsewhere: orbit
/// - two-finger drag: pan; pinch: zoom; double-tap: frame scene
@MainActor
struct MetalCanvas: UIViewRepresentable {
    let onStatus: (String) -> Void
    var scene: SceneSync
    let manipulation: CanvasManipulation

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
        context.coordinator.attach(view: view, onStatus: onStatus)
        context.coordinator.manipulation = manipulation
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        let coordinator = context.coordinator
        coordinator.manipulation = manipulation
        coordinator.renderer?.setGizmo(mode: scene.gizmoMode, rotationAxis: scene.rotationAxis)
        let needsSceneApply =
            scene.snapshot.documentID != coordinator.lastDocumentID ||
            scene.snapshot.revision != coordinator.lastDocumentRevision ||
            scene.presentationRevision != coordinator.lastPresentationRevision ||
            scene.selectedObjectID != coordinator.lastSelectedObjectID ||
            scene.selectedInstanceID != coordinator.lastSelectedInstanceID

        if needsSceneApply {
            do {
                try coordinator.renderer?.applyScene(
                    scene.snapshot,
                    bed: scene.bed,
                    selectedObjectID: scene.selectedObjectID,
                    selectedInstanceID: scene.selectedInstanceID,
                    previewMatrix: scene.previewMatrix
                )
                coordinator.lastDocumentID = scene.snapshot.documentID
                coordinator.lastDocumentRevision = scene.snapshot.revision
                coordinator.lastPresentationRevision = scene.presentationRevision
                coordinator.lastSelectedObjectID = scene.selectedObjectID
                coordinator.lastSelectedInstanceID = scene.selectedInstanceID
            } catch {
                coordinator.report(
                    "Metal scene ERROR — \(String(describing: error))"
                )
            }
        }
        if scene.frameRequest != coordinator.lastFrameRequest {
            coordinator.lastFrameRequest = scene.frameRequest
            coordinator.renderer?.frameScene()
        }
    }

    // MARK: Coordinator — gestures + renderer lifetime

    @MainActor
    final class Coordinator: NSObject {
        var renderer: Renderer?
        var lastDocumentID: DocumentID?
        var lastDocumentRevision: DocumentRevision?
        var lastPresentationRevision: UInt64?
        var lastSelectedObjectID: ObjectID?
        var lastSelectedInstanceID: InstanceID?
        var lastFrameRequest: UInt64?

        var manipulation: CanvasManipulation?
        private var onStatus: ((String) -> Void)?

        private enum DragState {
            case orbit
            case move(bedOrigin: SIMD3<Float>)
            case rotate(center: CGPoint, startAngle: Double)
            case scale(startY: CGFloat)
        }
        private var dragState: DragState?

        func attach(view: MTKView, onStatus: @escaping (String) -> Void) {
            renderer = Renderer(view: view, onStatus: onStatus)
            self.onStatus = onStatus

            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(onDoubleTap(_:)))
            doubleTap.numberOfTapsRequired = 2
            view.addGestureRecognizer(doubleTap)

            let tap = UITapGestureRecognizer(target: self, action: #selector(onTap(_:)))
            tap.require(toFail: doubleTap)
            view.addGestureRecognizer(tap)

            let drag = UIPanGestureRecognizer(target: self, action: #selector(onDrag(_:)))
            drag.minimumNumberOfTouches = 1
            drag.maximumNumberOfTouches = 1
            view.addGestureRecognizer(drag)

            let pan = UIPanGestureRecognizer(target: self, action: #selector(onPan(_:)))
            pan.minimumNumberOfTouches = 2
            pan.maximumNumberOfTouches = 2
            view.addGestureRecognizer(pan)

            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(onPinch(_:)))
            view.addGestureRecognizer(pinch)
        }

        func report(_ message: String) {
            onStatus?(message)
        }

        @objc private func onTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? MTKView, let renderer else { return }
            let location = gesture.location(in: view)
            if let hit = renderer.pickInstance(at: location, in: view) {
                manipulation?.onSelect(hit.objectID, hit.instanceID)
            } else {
                manipulation?.onSelect(nil, nil)
            }
        }

        @objc private func onDoubleTap(_ gesture: UITapGestureRecognizer) {
            renderer?.frameScene()
        }

        /// Screen-space hit on the selection's gizmo ring (rotate/scale): a
        /// generous band around the projected ring so fingers needn't cover
        /// the object itself.
        private func gizmoRingHit(at location: CGPoint, in view: MTKView) -> CGPoint? {
            guard let renderer, let gizmo = renderer.selectedGizmo(),
                  let center = renderer.projectToScreen(gizmo.center, in: view) else { return nil }
            // Projected extent from several rim directions (robust for rings
            // seen at grazing angles).
            var radius: CGFloat = 0
            for direction in [SIMD3<Float>(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)] {
                if let rim = renderer.projectToScreen(gizmo.center + direction * gizmo.radius, in: view) {
                    radius = max(radius, hypot(rim.x - center.x, rim.y - center.y))
                }
            }
            let distance = hypot(location.x - center.x, location.y - center.y)
            return distance <= radius * 1.35 + 24 ? center : nil
        }

        @objc private func onDrag(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view as? MTKView, let renderer else { return }
            let location = gesture.location(in: view)
            switch gesture.state {
            case .began:
                dragState = beginDrag(at: location, in: view, renderer: renderer)
            case .changed:
                switch dragState {
                case .move(let origin):
                    if let bed = renderer.bedPlaneHit(at: location, in: view) {
                        let delta = CoordinateMapper.engineDelta(fromViewer: bed - origin)
                        manipulation?.onMove(SIMD2(delta.x, delta.y))
                        dragState = .move(bedOrigin: bed)
                    }
                case .rotate(let center, let startAngle):
                    let angle = Double(atan2(location.y - center.y, location.x - center.x))
                    // Screen y points down, so visually CCW motion decreases
                    // the angle. A right-handed rotation looks CCW when the
                    // axis points toward the camera — flip otherwise.
                    let axis = CoordinateMapper.viewerAxis(renderer.rotationAxis)
                    let facing: Double = simd_dot(renderer.camera.forward, axis) < 0 ? 1 : -1
                    let delta = atan2(sin(startAngle - angle), cos(startAngle - angle)) * facing
                    manipulation?.onRotate(delta)
                case .scale(let startY):
                    manipulation?.onScale(exp(Double(startY - location.y) / 220))
                case .orbit, .none:
                    let translation = gesture.translation(in: gesture.view)
                    renderer.camera.orbit(dx: Float(translation.x), dy: Float(translation.y))
                    gesture.setTranslation(.zero, in: gesture.view)
                }
            case .ended, .cancelled, .failed:
                switch dragState {
                case .move, .rotate, .scale:
                    manipulation?.onEnd()
                case .orbit, .none:
                    break
                }
                dragState = nil
            default:
                break
            }
        }

        private func beginDrag(
            at location: CGPoint,
            in view: MTKView,
            renderer: Renderer
        ) -> DragState {
            let hit = renderer.pickInstance(at: location, in: view)
            let mode = renderer.gizmoMode
            if mode != .move, hit == nil, let center = gizmoRingHit(at: location, in: view) {
                manipulation?.onBegin()
                return mode == .rotate
                    ? .rotate(center: center, startAngle: Double(atan2(location.y - center.y, location.x - center.x)))
                    : .scale(startY: location.y)
            }
            guard let hit else { return .orbit }
            if !isSelected(hit) {
                manipulation?.onSelect(hit.objectID, hit.instanceID)
            }
            switch mode {
            case .move:
                guard let bed = renderer.bedPlaneHit(at: location, in: view) else { return .orbit }
                return .move(bedOrigin: bed)
            case .rotate:
                // Center from the hit instance itself (selection may not be
                // re-applied to the renderer yet).
                guard let center = renderer.gizmo(objectID: hit.objectID, instanceID: hit.instanceID)
                    .flatMap({ renderer.projectToScreen($0.center, in: view) }) else {
                    return .orbit
                }
                manipulation?.onBegin()
                return .rotate(
                    center: center,
                    startAngle: Double(atan2(location.y - center.y, location.x - center.x))
                )
            case .scale:
                manipulation?.onBegin()
                return .scale(startY: location.y)
            }
        }

        private func isSelected(_ hit: (objectID: ObjectID, instanceID: InstanceID)) -> Bool {
            renderer?.selectedInstanceIDs.contains {
                $0.objectID == hit.objectID && $0.instanceID == hit.instanceID
            } ?? false
        }

        @objc private func onPan(_ gesture: UIPanGestureRecognizer) {
            let translation = gesture.translation(in: gesture.view)
            renderer?.camera.pan(
                dx: Float(translation.x),
                dy: Float(translation.y)
            )
            gesture.setTranslation(.zero, in: gesture.view)
        }

        @objc private func onPinch(_ gesture: UIPinchGestureRecognizer) {
            renderer?.camera.zoom(by: Float(gesture.scale))
            gesture.scale = 1
        }
    }
}
