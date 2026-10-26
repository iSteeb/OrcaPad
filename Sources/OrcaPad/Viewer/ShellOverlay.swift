// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

import OrcaBridge

/// One published object shell: the convex hull + volume centroid as
/// delivered by `EnginePlater.objectHull` — ENGINE world coordinates
/// (z-up, millimetres), one hull per OBJECT (multi-instance objects draw
/// it at the facade's reference placement, first instance).
struct ShellDraw: Sendable {
    let objectID: ObjectID
    let hull: EnginePlater.HullMesh
}

/// Plate → Renderer channel for the "Shells + COG" overlay (board
/// §wave-b/5).
///
/// The renderer instance is owned by MetalCanvas's coordinator, and this
/// wave does not extend `SceneSync`/`MetalCanvas` (not in IMPL-B's file
/// set) — so the Plate tab PUBLISHES the overlay here and the renderer
/// SAMPLES it while drawing. Both sides are main-actor; the whole channel
/// is one documented value, no hidden state. `generation` advances on
/// every publish so the renderer can cache its derived GPU buffers.
@MainActor
final class ShellOverlayCenter {
    static let shared = ShellOverlayCenter()

    private(set) var shells: [ShellDraw] = []
    /// Advances on every `update`; empty shells still advance it so a
    /// cleared overlay also invalidates renderer caches.
    private(set) var generation: UInt64 = 0

    private init() {}

    /// Publishes the full overlay state (empty = overlay off / nothing to
    /// show). Callers reload on every document revision while the View
    /// menu toggle is on.
    func update(_ shells: [ShellDraw]) {
        self.shells = shells
        generation &+= 1
    }
}
