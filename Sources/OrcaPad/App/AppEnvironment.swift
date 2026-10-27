// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

import Foundation
import Observation
import OrcaBridge
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
    /// Online system-profile updates (0.19 flagship, Preferences ▸ Presets
    /// and the launch check below).
    let profileUpdates: ProfileUpdates
    private(set) var isBootstrapping = false

    init() {
        let status = StatusCenter()
        self.status = status
        document = DocumentStore(status: status)
        presets = PresetStore(status: status)
        slicing = SliceService(status: status)
        printHost = PrintHostService(status: status)
        printers = PrinterStore(status: status)
        profileUpdates = ProfileUpdates(status: status)
        // Preset operations must REJECT (not silently queue) while the
        // engine is slicing — they would park on the engine mutex for the
        // whole slice and apply minutes later.
        presets.engineIsSlicing = { [weak self] in
            self?.document.isSlicing ?? false
        }
        // A refreshed SimplyPrint access token (the 401 retry inside an
        // upload) is persisted back into the engine's printer records so
        // the NEXT upload does not repeat the refresh (desktop
        // save_oauth_credential parity).
        printHost.onSimplyPrintTokenRefreshed = { [weak self] token in
            Task { await self?.updateCloudHostAPIKey(hostType: "simplyprint", apiKey: token) }
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
        createDownloadsFolder()
        await document.bootstrap()
        await presets.load()
        // The plate grid derives from the selected machine's bed (ABI v27).
        if let volume = presets.printVolume {
            await document.syncBed(volume)
        }
        await restoreAutosaveIfNeeded()
        await checkProfileUpdatesAtLaunch()
    }

    // MARK: Downloads folder (desktop "Downloads folder" parity)

    /// Files-app-visible `Documents/Downloads`: Safari's "Save to Files"
    /// can target it, so downloaded models land inside OrcaPad's own
    /// container next to the exports. Created at launch; a failure is a
    /// real filesystem problem and surfaces loudly.
    private func createDownloadsFolder() {
        let downloads = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        )[0].appendingPathComponent("Downloads", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: downloads, withIntermediateDirectories: true)
        } catch {
            status.report(.document, failure: AppFailure.wrap(
                error, operation: "create Downloads folder"))
        }
    }

    // MARK: Profile updates at launch (Preferences ▸ Presets ▸ toggle)

    /// "Check at launch" (profiles.autoUpdate, default off): a quiet check
    /// once the preset tree is loaded; found updates are REPORTED through
    /// the status center, never installed without the user — installing
    /// lives in Preferences ▸ Presets.
    private func checkProfileUpdatesAtLaunch() async {
        guard UserDefaults.standard.bool(forKey: "profiles.autoUpdate") else { return }
        let vendors = await profileUpdates.installedVendors(from: presets)
        guard !vendors.isEmpty else { return }
        await profileUpdates.check(vendors: vendors)
    }

    // MARK: Cloud print-host account linking (0.19 device host completion)

    /// Runs the SimplyPrint OAuth flow (PrintHostService) and stores the
    /// access token on every SimplyPrint printer record — creating the
    /// default record when none exists (the printer is picked on the
    /// SimplyPrint side; the record URL is their home). Returns whether
    /// the account ended up linked.
    @discardableResult
    func linkSimplyPrintAccount() async -> Bool {
        let account: PrintHostService.LinkedAccount
        do {
            account = try await printHost.linkSimplyPrintAccount()
        } catch {
            status.report(.device, failure: AppFailure.wrap(
                error, operation: "link SimplyPrint account"))
            return false
        }
        return await updateCloudHostAPIKey(
            hostType: "simplyprint",
            apiKey: account.apiKey,
            createWhenMissing: EnginePresets.PhysicalPrinterRecord(
                name: "SimplyPrint",
                hostType: "simplyprint",
                url: "https://simplyprint.io",
                webUI: "https://simplyprint.io/panel",
                apiKey: account.apiKey,
                presetNames: []
            ))
    }

    /// Runs the 3DPrinterOS browser login-token flow against the EXISTING
    /// 3DPrinterOS printer's host (their cloud URL); the returned session
    /// becomes that record's API key (upstream stores the session in
    /// 3dprinteros_api_cred.json — OrcaPad keeps it on the engine record).
    @discardableResult
    func link3DPrinterOSAccount() async -> Bool {
        guard let existing = printers.printers.first(where: { $0.hostType == "3dprinteros" })
        else {
            status.report(.device, failure: .invariant(
                operation: "link 3DPrinterOS account",
                diagnostic: "add a 3DPrinterOS printer first (Device tab), then link its account"))
            return false
        }
        let account: PrintHostService.LinkedAccount
        do {
            account = try await printHost.link3DPrinterOSAccount(record: existing)
        } catch {
            status.report(.device, failure: AppFailure.wrap(
                error, operation: "link 3DPrinterOS account"))
            return false
        }
        return await updateCloudHostAPIKey(
            hostType: "3dprinteros",
            apiKey: account.apiKey,
            createWhenMissing: nil)
    }

    /// Writes `apiKey` on every record of `hostType` (optionally creating
    /// the default record when none exists). Reports the outcome either way.
    @discardableResult
    private func updateCloudHostAPIKey(
        hostType: String,
        apiKey: String,
        createWhenMissing: EnginePresets.PhysicalPrinterRecord? = nil
    ) async -> Bool {
        guard let engine = presets.engineForSlicing, presets.isReady else {
            status.report(.device, "account link blocked: presets are not ready")
            return false
        }
        var records = printers.printers.filter { $0.hostType == hostType }
        if records.isEmpty, let created = createWhenMissing {
            records = [created]
        }
        guard !records.isEmpty else {
            status.report(.device, "account linked, but no \(hostType) printer stores it")
            return false
        }
        var saved = false
        for record in records {
            let updated = EnginePresets.PhysicalPrinterRecord(
                name: record.name,
                hostType: record.hostType,
                url: record.url,
                webUI: record.webUI,
                apiKey: apiKey,
                presetNames: record.presetNames
            )
            saved = await printers.save(updated, presets: engine) || saved
        }
        if saved {
            status.report(.device, "\(records[0].name): account linked")
        }
        return saved
    }
}
