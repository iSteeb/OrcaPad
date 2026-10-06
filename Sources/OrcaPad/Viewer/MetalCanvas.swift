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
    var previewTransform: InstanceTransform?
    var presentationRevision: UInt64
    var frameRequest: UInt64
}

/// SwiftUI wrapper around MTKView + gesture recognizers.
///
/// Gesture model:
/// - tap: select instance (nearest ray hit); tap empty space deselects
/// - one-finger drag on the selected instance: move it on the bed plane
/// - one-finger drag elsewhere: orbit
/// - two-finger drag: pan; pinch: zoom
@MainActor
struct MetalCanvas: UIViewRepresentable {
    let onStatus: (String) -> Void
    var scene: SceneSync
    let onSelect: (ObjectID?, InstanceID?) -> Void
    let onMoveSelected: (SIMD2<Float>) -> Void
    let onMoveEnded: () -> Void

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
            onStatus: onStatus,
            onSelect: onSelect,
            onMoveSelected: onMoveSelected,
            onMoveEnded: onMoveEnded
        )
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        let coordinator = context.coordinator
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
                    previewTransform: scene.previewTransform
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

        private var onStatus: ((String) -> Void)?
        private var onSelect: ((ObjectID?, InstanceID?) -> Void)?
        private var onMoveSelected: ((SIMD2<Float>) -> Void)?
        private var onMoveEnded: (() -> Void)?
        private var moveState: (bedOrigin: SIMD3<Float>, active: Bool)?

        func attach(
            view: MTKView,
            onStatus: @escaping (String) -> Void,
            onSelect: @escaping (ObjectID?, InstanceID?) -> Void,
            onMoveSelected: @escaping (SIMD2<Float>) -> Void,
            onMoveEnded: @escaping () -> Void
        ) {
            renderer = Renderer(view: view, onStatus: onStatus)
            self.onStatus = onStatus
            self.onSelect = onSelect
            self.onMoveSelected = onMoveSelected
            self.onMoveEnded = onMoveEnded

            let tap = UITapGestureRecognizer(
                target: self,
                action: #selector(onTap(_:))
            )
            view.addGestureRecognizer(tap)

            let orbit = UIPanGestureRecognizer(
                target: self,
                action: #selector(onOrbitOrMove(_:))
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
        }

        func report(_ message: String) {
            onStatus?(message)
        }

        @objc private func onTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? MTKView,
                  let renderer else { return }
            let location = gesture.location(in: view)
            if let hit = renderer.pickInstance(at: location, in: view) {
                onSelect?(hit.objectID, hit.instanceID)
            } else {
                onSelect?(nil, nil)
            }
        }

        @objc private func onOrbitOrMove(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view as? MTKView,
                  let renderer else { return }
            let location = gesture.location(in: view)
            switch gesture.state {
            case .began:
                if let hit = renderer.pickInstance(at: location, in: view),
                   let bed = renderer.bedPlaneHit(at: location, in: view) {
                    // Desktop-like touch flow: dragging an unselected instance
                    // selects it AND starts the move in one gesture.
                    if !isSelected(hit) {
                        onSelect?(hit.objectID, hit.instanceID)
                    }
                    moveState = (bed, true)
                } else {
                    moveState = nil
                }
            case .changed:
                if moveState != nil,
                   let bed = renderer.bedPlaneHit(at: location, in: view),
                   let origin = moveState?.bedOrigin {
                    let engineDelta = CoordinateMapper.engineDelta(
                        fromViewer: bed - origin
                    )
                    onMoveSelected?(SIMD2(engineDelta.x, engineDelta.y))
                    moveState = (bed, true)
                } else {
                    let translation = gesture.translation(in: gesture.view)
                    renderer.camera.orbit(
                        dx: Float(translation.x),
                        dy: Float(translation.y)
                    )
                    gesture.setTranslation(.zero, in: gesture.view)
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

        private func isSelected(
            _ hit: (objectID: ObjectID, instanceID: InstanceID)
        ) -> Bool {
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
