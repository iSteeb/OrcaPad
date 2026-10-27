// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

import Foundation

/// Tip of the Day (app.tips): a fixed catalog of concise, real tips —
/// presentation rotates through `tips.lastShownIndex` (UserDefaults), one
/// per launch and on demand from the About screen.
enum TipCatalog {
    struct Tip: Identifiable, Sendable {
        let id: Int
        let symbol: String
        let title: String
        let body: String
    }

    /// @AppStorage keys (enable flag + rotation state).
    enum Storage {
        static let enabledKey = "tips.enabled"
        static let lastShownIndexKey = "tips.lastShownIndex"
    }

    static let all: [Tip] = [
        Tip(
            id: 0,
            symbol: "hand.draw",
            title: "Camera gestures",
            body: "Drag one finger on empty space to orbit, drag two fingers to pan, pinch to zoom, and double-tap to frame the whole plate."),
        Tip(
            id: 1,
            symbol: "rectangle.dashed",
            title: "Select several objects",
            body: "Switch to the Select tool and drag on empty space to marquee-select. Long-press any object to toggle it in and out of a multi-selection."),
        Tip(
            id: 2,
            symbol: "rotate.3d",
            title: "Rotate in steps",
            body: "While rotating, drag near the middle of the ring to snap in 45° steps, or at its outer edge for fine 5° steps. Anywhere else rotates freely."),
        Tip(
            id: 3,
            symbol: "square.3.layers.3d.down",
            title: "Lay prints flat",
            body: "Choose the Lay-flat tool and tap one of the translucent resting faces — the object settles onto exactly the plane you picked."),
        Tip(
            id: 4,
            symbol: "paintbrush.pointed",
            title: "Paint supports and seams",
            body: "The paint tools apply with a tap-brush: pick a layer (support, seam, MMU, fuzzy skin), set the radius, and tap triangles to paint or erase."),
        Tip(
            id: 5,
            symbol: "slider.horizontal.3",
            title: "Per-object settings",
            body: "Select an object and use its menu to override process settings for just that object — the plate's preset stays untouched."),
        Tip(
            id: 6,
            symbol: "square.split.2x1",
            title: "Compare presets",
            body: "In Prepare, Compare presets shows the changed keys side by side before you commit to a different printer, filament or process."),
        Tip(
            id: 7,
            symbol: "square.stack.3d.up",
            title: "Work with plates",
            body: "The plate bar beside the bed switches plates; arrange overflow and Fill bed create new plates, and slice-all cuts every plate into one G-code."),
        Tip(
            id: 8,
            symbol: "keyboard",
            title: "Keyboard shortcuts",
            body: "With an iPad keyboard: Preview steps layers with ↑/↓ and moves with ←/→ (Shift = ×5, 1 = one-layer mode); Plate undoes with ⌘Z and redoes with ⇧⌘Z."),
        Tip(
            id: 9,
            symbol: "printer",
            title: "Device tab",
            body: "The Device tab probes every saved printer and marks which are reachable. Open one to watch its webcam, status and send G-code directly."),
    ]
}
