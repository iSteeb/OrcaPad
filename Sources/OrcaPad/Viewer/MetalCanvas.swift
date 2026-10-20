// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

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
    /// The selected volume of the selected object (part selection), if any.
    var selectedVolumeID: VolumeID?
    /// Every selected instance (multi-selection highlight).
    var highlightedInstanceIDs: Set<InstanceID>
    /// Live gesture previews (engine-frame matrices) keyed by instance.
    var previewMatrices: [InstanceID: simd_float4x4]
    var presentationRevision: UInt64
    var frameRequest: UInt64
    /// Camera view preset request (advances when a preset is chosen).
    var cameraRequest: (id: UInt64, preset: CameraViewPreset)
    var gizmoMode: GizmoMode
    var rotationAxis: EngineAxis
    /// Flatten-gizmo planes of the selected instance (desktop hull grouping);
    /// nil = unavailable (facet-tap fallback) or not in lay-flat mode.
    var flattenPlanes: [EnginePlater.FlattenPlane]? = nil
    /// Index of the plane highlighted under the finger (touch hover).
    var flattenHighlight: Int? = nil
    /// Filament slot colors (multi-filament extruder tinting).
    var filamentColors: [SIMD4<Float>] = []
}

/// Manipulation callbacks from the canvas gestures (engine-space units).
struct CanvasManipulation {
    let onSelect: (ObjectID?, InstanceID?) -> Void
    /// Desktop ctrl+click: long-press toggles multi-selection membership.
    let onToggleSelect: (ObjectID, InstanceID) -> Void
    /// Part selection: refine the (already selected) instance to one volume
    /// (nil returns to the whole object).
    let onSelectVolume: (ObjectID, InstanceID, VolumeID?) -> Void
    /// Rectangle (marquee) selection: the instances whose screen footprint
    /// intersected the drawn rectangle.
    let onRectangleSelect: ([(objectID: ObjectID, instanceID: InstanceID)]) -> Void
    /// Incremental bed-plane translation in engine millimetres.
    let onMove: (SIMD2<Float>) -> Void
    let onBegin: () -> Void
    /// Total rotation since gesture start about the selected world axis,
    /// radians (right-handed).
    let onRotate: (Double, Double) -> Void
    /// Total uniform scale factor since gesture start.
    let onScale: (Double) -> Void
    /// Lay flat: engine-frame normal of the tapped facet — or of the picked
    /// hull plane when planes are available (desktop behavior).
    let onLayFlat: (SIMD3<Double>) -> Void
    /// Touch-hover highlight of the flatten plane under the finger.
    let onHighlightFlattenPlane: (Int?) -> Void
    /// Rotate mode: tapping the (selected) model cycles the rotation axis
    /// focus (user spec; desktop picks the ring you grab instead).
    let onCycleRotationAxis: () -> Void
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
        coordinator.lastVolumeOfSelection = scene.selectedVolumeID
        coordinator.renderer?.setGizmo(mode: scene.gizmoMode, rotationAxis: scene.rotationAxis)
        coordinator.renderer?.setFlattenPlanes(scene.flattenPlanes)
        coordinator.renderer?.setFlattenHighlight(scene.flattenHighlight)
        coordinator.renderer?.setFilamentColors(scene.filamentColors)
        let needsSceneApply =
            scene.snapshot.documentID != coordinator.lastDocumentID ||
            scene.snapshot.revision != coordinator.lastDocumentRevision ||
            scene.presentationRevision != coordinator.lastPresentationRevision ||
            scene.selectedObjectID != coordinator.lastSelectedObjectID ||
            scene.selectedInstanceID != coordinator.lastSelectedInstanceID ||
            scene.selectedVolumeID != coordinator.lastSelectedVolumeID

        if needsSceneApply {
            do {
                try coordinator.renderer?.applyScene(
                    scene.snapshot,
                    bed: scene.bed,
                    selectedObjectID: scene.selectedObjectID,
                    selectedInstanceID: scene.selectedInstanceID,
                    highlightedInstanceIDs: scene.highlightedInstanceIDs,
                    previewMatrices: scene.previewMatrices,
                    selectedVolumeID: scene.selectedVolumeID
                )
                coordinator.lastDocumentID = scene.snapshot.documentID
                coordinator.lastDocumentRevision = scene.snapshot.revision
                coordinator.lastPresentationRevision = scene.presentationRevision
                coordinator.lastSelectedObjectID = scene.selectedObjectID
                coordinator.lastSelectedInstanceID = scene.selectedInstanceID
                coordinator.lastSelectedVolumeID = scene.selectedVolumeID
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
        if scene.cameraRequest.id != coordinator.lastCameraRequest {
            coordinator.lastCameraRequest = scene.cameraRequest.id
            coordinator.renderer?.camera.apply(scene.cameraRequest.preset)
            // View reset (desktop): Default View also re-fits the focused
            // bed on screen instead of keeping a stale zoom.
            if scene.cameraRequest.preset == .defaultValue {
                coordinator.renderer?.frameBed()
            }
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
        var lastSelectedVolumeID: VolumeID?
        var lastFrameRequest: UInt64?
        var lastCameraRequest: UInt64?

        var manipulation: CanvasManipulation?
        /// The renderer's current selection volume (for the tap toggle);
        /// kept in sync by updateUIView.
        var lastVolumeOfSelection: VolumeID?
        private var onStatus: ((String) -> Void)?

        private enum DragState {
            case orbit
            case move(bedOrigin: SIMD3<Float>)
            case rotate(center: CGPoint, startAngle: Double, ringRadius: CGFloat)
            case scale(startY: CGFloat)
            case layFlatPlane
            /// Rectangle selection: one-finger drag draws the marquee.
            case marquee(start: CGPoint)
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

            // Desktop ctrl+click: long-press toggles multi-selection membership.
            let longPress = UILongPressGestureRecognizer(
                target: self, action: #selector(onLongPress(_:)))
            longPress.minimumPressDuration = 0.45
            view.addGestureRecognizer(longPress)
        }

        @objc private func onLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began,
                  let view = gesture.view as? MTKView, let renderer else { return }
            let location = gesture.location(in: view)
            if let hit = renderer.pickInstance(at: location, in: view) {
                manipulation?.onToggleSelect(hit.objectID, hit.instanceID)
            }
        }

        func report(_ message: String) {
            onStatus?(message)
        }

        @objc private func onTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? MTKView, let renderer else { return }
            let location = gesture.location(in: view)
            if renderer.gizmoMode == .layFlat {
                // Desktop Flatten gizmo: the hull plane under the touch wins
                // (whole coplanar region); the raw facet remains the fallback
                // when planes are unavailable.
                if let plane = renderer.pickFlattenPlane(at: location, in: view) {
                    manipulation?.onHighlightFlattenPlane(nil)
                    manipulation?.onLayFlat(plane.engineNormal)
                    return
                }
                if let face = renderer.pickFace(at: location, in: view) {
                    // Lay flat: the tapped facet decides the resting face.
                    manipulation?.onSelect(face.objectID, face.instanceID)
                    manipulation?.onLayFlat(face.engineNormal)
                    return
                }
            } else if renderer.gizmoMode == .rotate,
                      let hit = renderer.pickInstance(at: location, in: view),
                      isSelected(hit) {
                // Rotate focus follows the model: tap it to cycle X -> Y -> Z.
                manipulation?.onCycleRotationAxis()
            } else if let hit = renderer.pickInstance(at: location, in: view) {
                // Desktop part selection: tapping the already-selected
                // instance refines the selection to the tapped volume; the
                // currently selected part toggles back to the object.
                if renderer.selectedInstanceIDs.count == 1, isSelected(hit),
                   let volume = renderer.pickVolume(at: location, in: view),
                   volume.objectID == hit.objectID, volume.instanceID == hit.instanceID {
                    let current = lastVolumeOfSelection
                    manipulation?.onSelectVolume(
                        hit.objectID, hit.instanceID,
                        current == volume.volumeID ? nil : volume.volumeID
                    )
                } else {
                    manipulation?.onSelect(hit.objectID, hit.instanceID)
                }
            } else {
                manipulation?.onSelect(nil, nil)
            }
        }

        @objc private func onDoubleTap(_ gesture: UITapGestureRecognizer) {
            renderer?.frameScene()
        }

        /// Screen-space hit on the selection's gizmo ring (rotate/scale): a
        /// generous band around the projected ring so fingers needn't cover
        /// the object itself. Also returns the projected ring radius — the
        /// rotate gesture picks its snap zone from the drag distance.
        private func gizmoRingHit(at location: CGPoint, in view: MTKView)
            -> (center: CGPoint, radius: CGFloat)? {
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
            return distance <= radius * 1.35 + 24 ? (center, max(radius, 1)) : nil
        }

        /// Desktop GLGizmoRotate zones, by drag distance from the center as
        /// a fraction of the ring radius: 1/3..2/3 = coarse 45° steps,
        /// 1.0..1.1 (the scale teeth) = fine 5° steps, everywhere else free.
        static func rotationSnapDegrees(dragDistance: CGFloat, ringRadius: CGFloat) -> Double {
            let fraction = Double(dragDistance / max(ringRadius, 1))
            if fraction >= 1.0 / 3.0 && fraction <= 2.0 / 3.0 { return 45 }
            if fraction >= 1.0 && fraction <= 1.1 { return 5 }
            return 0
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
                case .rotate(let center, let startAngle, let ringRadius):
                    let angle = Double(atan2(location.y - center.y, location.x - center.x))
                    // Screen y points down, so visually CCW motion decreases
                    // the angle. A right-handed rotation looks CCW when the
                    // axis points toward the camera — flip otherwise.
                    let axis = CoordinateMapper.viewerAxis(renderer.rotationAxis)
                    let facing: Double = simd_dot(renderer.camera.forward, axis) < 0 ? 1 : -1
                    let delta = atan2(sin(startAngle - angle), cos(startAngle - angle)) * facing
                    manipulation?.onRotate(delta, Self.rotationSnapDegrees(
                        dragDistance: hypot(location.x - center.x, location.y - center.y),
                        ringRadius: ringRadius
                    ))
                case .scale(let startY):
                    manipulation?.onScale(exp(Double(startY - location.y) / 220))
                case .marquee(let start):
                    renderer.setMarquee(Self.normalizedRect(from: start, to: location))
                case .layFlatPlane:
                    if let plane = renderer.pickFlattenPlane(at: location, in: view) {
                        manipulation?.onHighlightFlattenPlane(plane.index)
                    } else {
                        manipulation?.onHighlightFlattenPlane(nil)
                    }
                case .orbit, .none:
                    let translation = gesture.translation(in: gesture.view)
                    renderer.camera.orbit(dx: Float(translation.x), dy: Float(translation.y))
                    gesture.setTranslation(.zero, in: gesture.view)
                }
            case .ended, .cancelled, .failed:
                switch dragState {
                case .layFlatPlane:
                    if let plane = renderer.pickFlattenPlane(at: location, in: view) {
                        manipulation?.onLayFlat(plane.engineNormal)
                    }
                    manipulation?.onHighlightFlattenPlane(nil)
                case .move, .rotate, .scale:
                    manipulation?.onEnd()
                case .marquee(let start):
                    renderer.setMarquee(nil)
                    let rect = Self.normalizedRect(from: start, to: location)
                    // A near-degenerate rect is a tap: the tap gesture
                    // handles selection.
                    if rect.width > 6, rect.height > 6 {
                        let hits = renderer.instancesIntersecting(rect: rect, in: view)
                        if !hits.isEmpty {
                            manipulation?.onRectangleSelect(hits)
                        }
                    }
                case .orbit, .none:
                    break
                }
                dragState = nil
            default:
                break
            }
        }

        private static func normalizedRect(from start: CGPoint, to end: CGPoint) -> CGRect {
            CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            )
        }

        private func beginDrag(
            at location: CGPoint,
            in view: MTKView,
            renderer: Renderer
        ) -> DragState {
            let mode = renderer.gizmoMode
            // Rectangle selection: the drag ALWAYS draws the marquee in this
            // mode (taps still select).
            if mode == .select {
                return .marquee(start: location)
            }
            // Finger-drag scale is UNIFORM ONLY (user spec); per-axis
            // scaling lives in the expanded tools panel's numeric fields.
            let hit = renderer.pickInstance(at: location, in: view)
            if mode != .move, hit == nil, let ring = gizmoRingHit(at: location, in: view) {
                manipulation?.onBegin()
                return mode == .rotate
                    ? .rotate(
                        center: ring.center,
                        startAngle: Double(atan2(location.y - ring.center.y, location.x - ring.center.x)),
                        ringRadius: ring.radius
                    )
                    : .scale(startY: location.y)
            }
            guard let hit else { return .orbit }
            if !isSelected(hit) {
                manipulation?.onSelect(hit.objectID, hit.instanceID)
            }
            switch mode {
            case .layFlat:
                // Touch-hover: dragging across the object highlights the
                // plane under the finger (desktop hover); release applies it.
                if let plane = renderer.pickFlattenPlane(at: location, in: view) {
                    manipulation?.onHighlightFlattenPlane(plane.index)
                    return .layFlatPlane
                }
                manipulation?.onHighlightFlattenPlane(nil)
                return .orbit
            case .move:
                guard let bed = renderer.bedPlaneHit(at: location, in: view) else { return .orbit }
                return .move(bedOrigin: bed)
            case .rotate:
                // Center from the hit instance itself (selection may not be
                // re-applied to the renderer yet).
                guard let gizmo = renderer.gizmo(objectID: hit.objectID, instanceID: hit.instanceID),
                      let center = renderer.projectToScreen(gizmo.center, in: view) else {
                    return .orbit
                }
                var ringRadius: CGFloat = 1
                for direction in [SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 0, 1)] {
                    if let rim = renderer.projectToScreen(gizmo.center + direction * gizmo.radius, in: view) {
                        ringRadius = max(ringRadius, hypot(rim.x - center.x, rim.y - center.y))
                    }
                }
                manipulation?.onBegin()
                return .rotate(
                    center: center,
                    startAngle: Double(atan2(location.y - center.y, location.x - center.x)),
                    ringRadius: ringRadius
                )
            case .scale:
                manipulation?.onBegin()
                return .scale(startY: location.y)
            case .select:
                return .orbit
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
