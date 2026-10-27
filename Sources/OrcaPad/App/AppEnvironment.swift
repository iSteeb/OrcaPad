// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

import Foundation
import Observation
import os

/// Process-lifetime owner for client stores and their Bridge sessions.
/// Presentation views borrow these references; they never own engine handles.
@MainActor
@Observable
final class AppEnvironment {
    let status: StatusCenter
    let document: DocumentStore
    let presets: PresetStore
    let slicing: SliceService
    let printHost: PrintHostService
    let printers: PrinterStore
    private(set) var isBootstrapping = false

    init() {
        let status = StatusCenter()
        self.status = status
        document = DocumentStore(status: status)
        presets = PresetStore(status: status)
        slicing = SliceService(status: status)
        printHost = PrintHostService(status: status)
        printers = PrinterStore(status: status)
        // Preset operations must REJECT (not silently queue) while the
        // engine is slicing — they would park on the engine mutex for the
        // whole slice and apply minutes later.
        presets.engineIsSlicing = { [weak self] in
            self?.document.isSlicing ?? false
        }
    }

    // MARK: Session autosave (desktop auto-backup subset)

    private let autosaveLogger = Logger(
        subsystem: "ie.duz.OrcaPad",
        category: "autosave"
    )
    /// Document revision captured at the last session autosave (either
    /// path). The interval timer compares against it to decide "dirty".
    private var lastAutosaveRevision: UInt64?

    /// Writes a lightweight 3MF snapshot of the current session when the
    /// app leaves the foreground OR the interval timer fires, and clears
    /// it when the plate is empty — an app kill or iOS eviction then never
    /// loses work. Restored once on the next launch (`bootstrap`). Best
    /// effort: a backgrounding process gets only a short grace window.
    func autosaveSession() async {
        guard let engine = presets.engineForSlicing, presets.isReady,
              document.isReady, !document.isBusy,
              let scene = document.scene else { return }
        let url = EnginePaths.autosaveURL()
        let manager = FileManager.default
        guard !scene.objects.isEmpty else {
            // An empty plate restores nothing: clear any stale autosave so
            // the next launch starts clean.
            if manager.fileExists(atPath: url.path) {
                do {
                    try manager.removeItem(at: url)
                } catch {
                    status.report(.document, failure: AppFailure.wrap(
                        error, operation: "clear session autosave"))
                }
            }
            lastAutosaveRevision = scene.revision.rawValue
            return
        }
        await presets.withExclusiveSession {
            await document.saveAutosave(to: url, presets: engine)
        }
        // The revision is marked saved AFTER the write: a failed save
        // surfaces loudly through the status banner, and the next document
        // change re-dirties it (the same retry cadence as desktop's
        // auto-backup).
        lastAutosaveRevision = scene.revision.rawValue
        autosaveLogger.notice(
            "session autosaved at revision \(scene.revision.rawValue, privacy: .public)"
        )
    }

    /// Interval-timer tick (Preferences ▸ Files ▸ autosave
    /// interval, files.auto-backup): saves when the document is dirty
    /// (revision advanced since the last autosave) and idle. RootView
    /// drives the cadence and pauses it while the app is not active
    /// (ScenePhase re-keys the timer task).
    func autosaveIfDirty() async {
        guard document.isReady, presets.isReady, !document.isBusy else { return }
        guard let scene = document.scene else { return }
        guard scene.revision.rawValue != lastAutosaveRevision else { return }
        autosaveLogger.notice(
            "autosave interval reached at revision \(scene.revision.rawValue, privacy: .public)"
        )
        await autosaveSession()
    }

    private func restoreAutosaveIfNeeded() async {
        let url = EnginePaths.autosaveURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard presets.engineForSlicing != nil, presets.isReady, document.isReady else {
            // Engine not ready (e.g. preset load failure): KEEP the file —
            // deleting the session backup over an unrelated startup failure
            // would be destructive; the next healthy launch restores it.
            return
        }
        if await openProject(url) {
            status.report(.document, "session restored from autosave")
        } else {
            // The engine was ready and still refused the file: it is
            // corrupt — a broken autosave must not fail every future launch.
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                status.report(.document, failure: AppFailure.wrap(
                    error, operation: "discard broken autosave"))
            }
        }
    }

    /// Desktop "Open project": the document AND the preset session change
    /// together, so the preset store is held exclusive for the duration.
    /// Returns whether the engine committed the open.
    @discardableResult
    func openProject(_ url: URL) async -> Bool {
        if !document.isReady || !presets.isReady { await bootstrap() }
        guard let engine = presets.engineForSlicing, presets.isReady, document.isReady else {
            status.report(.document, "open project blocked: engine is not ready")
            return false
        }
        var opened = false
        await presets.withExclusiveSession {
            if await document.openProject(from: url, presets: engine) {
                await presets.reloadFromEngine()
                opened = true
            }
        }
        return opened
    }

    func saveProject(named name: String) async {
        guard let engine = presets.engineForSlicing, presets.isReady else {
            status.report(.document, "save project blocked: presets are not ready")
            return
        }
        let bed = presets.printVolume.map(EngineBed.init) ?? EngineBed.fallback
        await presets.withExclusiveSession {
            await document.saveProject(named: name, presets: engine, bed: bed)
        }
    }

    func bootstrap() async {
        guard !isBootstrapping else { return }
        isBootstrapping = true
        defer { isBootstrapping = false }
        await document.bootstrap()
        await presets.load()
        // The plate grid derives from the selected machine's bed (ABI v27).
        if let volume = presets.printVolume {
            await document.syncBed(volume)
        }
        await restoreAutosaveIfNeeded()
    }
}
