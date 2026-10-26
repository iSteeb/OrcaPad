// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

import Foundation
import Observation
import OrcaBridge

struct SliceProgress: Sendable {
    let percent: Int
    let message: String
}

/// One plate of a slice-all result: marker index/name plus the plate's
/// WORLD origin at slice time (each section's G-code is plate-relative).
struct SlicePlateOrigin: Sendable {
    let plateIndex: Int
    let name: String
    let origin: SIMD3<Float>
}

struct CompletedSlice: Sendable {
    /// Unique per slice job: re-slicing to the same output path must still
    /// refresh consumers (Preview) keyed by it.
    let jobID: UInt64
    let sourceRevision: DocumentRevision
    let presetSelection: PresetSelection?
    let outputURL: URL
    let result: SliceResult
    /// World origin of the plate this G-code belongs to (nil for a combined
    /// slice-all file): the engine emits plate-RELATIVE G-code (desktop
    /// PartPlate::set_print parity), so the preview shifts it back.
    let plateOrigin: SIMD3<Float>?
    /// Slice-all: the document's plates (index, name, world origin at slice
    /// time). The preview splits the ORCA_PLATE marker sections and offsets
    /// every section back - without this, all plate-relative sections stack
    /// on the bed origin.
    let plateSections: [SlicePlateOrigin]
}

@MainActor
@Observable
final class SliceService {
    private let status: StatusCenter
    private var nextJobID: UInt64 = 0
    private var activeJobID: UInt64?
    private var activeJob: SliceJob?
    private(set) var progress: SliceProgress?
    private(set) var lastOutcome: CompletedSlice?
    private(set) var lastFailure: AppFailure?

    init(status: StatusCenter) {
        self.status = status
    }

    func run(document: DocumentStore, presets: PresetStore) async {
        guard presets.hasListedMachine else {
            // Fresh install: the "- default -" printer slices with raw
            // engine defaults (relative E, no per-layer reset) — refuse with
            // directions instead (desktop shows the ConfigWizard first).
            let failure = AppFailure.invariant(
                operation: "slice",
                diagnostic: "select a printer first: Prepare \u{25b8} Printer, then slice"
            )
            lastFailure = failure
            status.report(.slice, failure: failure)
            return
        }
        guard let input = document.beginSlicing() else {
            status.report(.slice, "slice blocked: document is not ready or is busy")
            return
        }
        defer { document.finishSlicing() }

        let sceneName = input.snapshot.objects.first?.name.isEmpty == false
            ? input.snapshot.objects[0].name
            : "plater"
        let outputURL: URL
        do {
            outputURL = try EnginePaths.gcodeOutputURL(sceneName: sceneName)
        } catch {
            let failure = AppFailure.wrap(
                error,
                operation: "prepare G-code output"
            )
            lastFailure = failure
            status.report(.slice, failure: failure)
            return
        }

        let job: SliceJob
        do {
            job = try SliceJob()
        } catch {
            let failure = AppFailure.wrap(error, operation: "create slice job")
            lastFailure = failure
            status.report(.slice, failure: failure)
            return
        }
        // Desktop embeds plate thumbnails in every non-BBL G-code. Explicit
        // recovery on failure: thumbnails are cosmetic metadata, the slice
        // itself is unaffected — reported loudly, slicing proceeds without.
        do {
            let bed = presets.printVolume.map(EngineBed.init) ?? EngineBed.fallback
            let rgba = try ThumbnailService.render(scene: input.snapshot, bed: bed)
            try job.setThumbnail(size: ThumbnailService.size, rgba: rgba)
        } catch {
            status.report(.slice, failure: AppFailure.wrap(error, operation: "render G-code thumbnail"))
        }
        nextJobID += 1
        let jobID = nextJobID
        activeJobID = jobID
        activeJob = job
        progress = SliceProgress(percent: 0, message: "starting")
        lastFailure = nil
        let instanceCount = input.snapshot.objects.reduce(0) {
            $0 + $1.instances.count
        }
        let presetEngine = presets.engineForSlicing
        let presetSelection = presetEngine == nil ? nil : presets.selection
        let presetNote = presetEngine == nil
            ? " (defaults — presets unavailable)"
            : ""
        status.report(
            .slice,
            "\(instanceCount) instance(s): slicing…\(presetNote)"
        )

        let progressCallback: @Sendable (Int, String) -> Void = {
            [weak self] percent, message in
            Task { @MainActor in
                guard let self, self.activeJobID == jobID else { return }
                self.progress = SliceProgress(
                    percent: percent,
                    message: message
                )
                self.status.update(
                    .slice,
                    "\(instanceCount) instance(s): \(percent)% \(message)"
                )
            }
        }
        let result = await BackgroundWork.run(operation: "slice document") {
            if let presetEngine {
                return try input.plater.slice(
                    to: outputURL.path,
                    presets: presetEngine,
                    job: job,
                    progress: progressCallback
                )
            }
            return try input.plater.slice(
                to: outputURL.path,
                job: job,
                progress: progressCallback
            )
        }

        finish(
            result: result,
            input: input,
            jobID: jobID,
            outputURL: outputURL,
            presetSelection: presetSelection,
            instanceCount: instanceCount,
            plateOrigin: currentPlateOrigin(input),
            plateSections: []
        )
    }

    /// Desktop "Slice all": every non-empty plate in order into ONE G-code
    /// file with `; ORCA_PLATE` markers between the plate sections.
    func runAll(document: DocumentStore, presets: PresetStore) async {
        guard presets.hasListedMachine else {
            let failure = AppFailure.invariant(
                operation: "slice all",
                diagnostic: "select a printer first: Prepare \u{25b8} Printer, then slice"
            )
            lastFailure = failure
            status.report(.slice, failure: failure)
            return
        }
        guard let input = document.beginSlicing() else {
            status.report(.slice, "slice blocked: document is not ready or is busy")
            return
        }
        defer { document.finishSlicing() }

        let plateCount = input.snapshot.plates.count
        let sceneName = input.snapshot.objects.first?.name.isEmpty == false
            ? input.snapshot.objects[0].name
            : "plater"
        let outputURL: URL
        do {
            outputURL = try EnginePaths.gcodeOutputURL(sceneName: sceneName)
        } catch {
            let failure = AppFailure.wrap(
                error,
                operation: "prepare G-code output"
            )
            lastFailure = failure
            status.report(.slice, failure: failure)
            return
        }
        let job: SliceJob
        do {
            job = try SliceJob()
        } catch {
            let failure = AppFailure.wrap(error, operation: "create slice job")
            lastFailure = failure
            status.report(.slice, failure: failure)
            return
        }
        do {
            let bed = presets.printVolume.map(EngineBed.init) ?? EngineBed.fallback
            let rgba = try ThumbnailService.render(scene: input.snapshot, bed: bed)
            try job.setThumbnail(size: ThumbnailService.size, rgba: rgba)
        } catch {
            status.report(.slice, failure: AppFailure.wrap(error, operation: "render G-code thumbnail"))
        }
        nextJobID += 1
        let jobID = nextJobID
        activeJobID = jobID
        activeJob = job
        progress = SliceProgress(percent: 0, message: "starting")
        lastFailure = nil
        let instanceCount = input.snapshot.objects.reduce(0) {
            $0 + $1.instances.count
        }
        let presetEngine = presets.engineForSlicing
        let presetSelection = presetEngine == nil ? nil : presets.selection
        let presetNote = presetEngine == nil
            ? " (defaults — presets unavailable)"
            : ""
        status.report(
            .slice,
            "\(plateCount) plate(s), \(instanceCount) instance(s): slicing all…\(presetNote)"
        )
        let progressCallback: @Sendable (Int, String) -> Void = {
            [weak self] percent, message in
            Task { @MainActor in
                guard let self, self.activeJobID == jobID else { return }
                self.progress = SliceProgress(
                    percent: percent,
                    message: message
                )
                self.status.update(
                    .slice,
                    "\(plateCount) plate(s): \(percent)% \(message)"
                )
            }
        }
        let result = await BackgroundWork.run(operation: "slice all plates") {
            if let presetEngine {
                return try input.plater.sliceAll(
                    to: outputURL.path,
                    presets: presetEngine,
                    job: job,
                    progress: progressCallback
                )
            }
            return try input.plater.sliceAll(
                to: outputURL.path,
                job: job,
                progress: progressCallback
            )
        }

        finish(
            result: result,
            input: input,
            jobID: jobID,
            outputURL: outputURL,
            presetSelection: presetSelection,
            instanceCount: instanceCount,
            plateOrigin: nil,  // combined file: marker-separated plate sections
            plateSections: input.snapshot.plates.enumerated().map { index, plate in
                SlicePlateOrigin(
                    plateIndex: index,
                    name: plate.name,
                    origin: plate.origin
                )
            }
        )
    }

    private func currentPlateOrigin(_ input: SliceInput) -> SIMD3<Float>? {
        let scene = input.snapshot
        guard scene.currentPlate >= 0, scene.currentPlate < scene.plates.count else {
            return nil
        }
        return scene.plates[scene.currentPlate].origin
    }

    private func finish(
        result: Result<SliceResult, AppFailure>,
        input: SliceInput,
        jobID: UInt64,
        outputURL: URL,
        presetSelection: PresetSelection?,
        instanceCount: Int,
        plateOrigin: SIMD3<Float>?,
        plateSections: [SlicePlateOrigin]
    ) {
        activeJobID = nil
        activeJob = nil
        progress = nil
        switch result {
        case .success(let sliceResult):
            let outcome = CompletedSlice(
                jobID: jobID,
                sourceRevision: input.snapshot.revision,
                presetSelection: presetSelection,
                outputURL: outputURL,
                result: sliceResult,
                plateOrigin: plateOrigin,
                plateSections: plateSections
            )
            lastOutcome = outcome
            let minutes = Int(sliceResult.timeEstimateSeconds / 60)
            let kilobytes = sliceResult.gcodeBytes / 1024
            let warningNote = sliceResult.warnings.isEmpty
                ? "" : " · \(sliceResult.warnings.count) warning(s)"
            status.report(
                .slice,
                "\(instanceCount) instance(s): G-code ready\n" +
                    "\(outputURL.lastPathComponent) · \(kilobytes) KB · ~\(minutes) min print\(warningNote)"
            )
        case .failure(let failure):
            if case .bridge(let error) = failure, error.status == .cancelled {
                // Explicit recovery: user cancellation is not a failure; the
                // previous outcome stays valid for its own revision.
                status.report(.slice, "slice cancelled")
            } else {
                lastFailure = failure
                status.report(.slice, failure: failure)
            }
        }
    }

    var isSlicing: Bool { activeJob != nil }

    // MARK: Auto-slice (board §wave-b/2: persisted "slice.auto" toggle)

    /// Re-slices when the document moved past the last outcome's revision
    /// while the user's auto-slice toggle is on. The DEBOUNCE is the
    /// caller's `.task(id: revision)` cancellation: this sleeps first, and
    /// every newer document revision cancels the sleep and restarts the
    /// observation — only the last revision of a burst of edits slices.
    ///
    /// Scope (deliberate): document REVISION changes only — preset edits do
    /// not advance the revision, so preset changes wait for the explicit
    /// Slice action (desktop re-slices on those too; wiring that needs a
    /// revision signal for presets, left to a later wave).
    func autoSlice(document: DocumentStore, presets: PresetStore) async {
        // No prior outcome / no listed machine: the explicit Slice action
        // owns first-run guidance (SliceService.run reports it) — auto
        // never becomes a silent first slice.
        guard lastOutcome != nil, presets.hasListedMachine else { return }
        guard let revision = document.scene?.revision,
            revision != lastOutcome?.sourceRevision else { return }
        do {
            try await Task.sleep(for: .seconds(1.5))
        } catch {
            // Explicit recovery: cancellation means a newer revision
            // superseded this one (the debounce working); the restarted
            // task owns the re-slice.
            return
        }
        // The burst may have settled on an outcome that is already current
        // (undo back onto the sliced revision), the plate may have emptied,
        // or a manual slice may be in flight — none of these re-slice.
        guard !isSlicing, !document.isBusy,
            let current = document.scene?.revision,
            current == revision,
            lastOutcome?.sourceRevision != revision,
            document.scene?.objects.isEmpty == false
        else { return }
        await run(document: document, presets: presets)
    }

    /// Desktop "Cancel" during slicing: cooperative engine cancellation.
    func cancel() {
        guard let activeJob else { return }
        status.update(.slice, "cancelling…")
        activeJob.cancel()
    }
}
