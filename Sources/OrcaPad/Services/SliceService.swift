import Foundation
import Observation
import OrcaBridge

struct SliceProgress: Sendable {
    let percent: Int
    let message: String
}

struct CompletedSlice: Sendable {
    let sourceRevision: DocumentRevision
    let presetSelection: PresetSelection?
    let outputURL: URL
    let result: SliceResult
}

@MainActor
@Observable
final class SliceService {
    private let status: StatusCenter
    private var nextJobID: UInt64 = 0
    private var activeJobID: UInt64?
    private(set) var progress: SliceProgress?
    private(set) var lastOutcome: CompletedSlice?
    private(set) var lastFailure: AppFailure?

    init(status: StatusCenter) {
        self.status = status
    }

    func run(document: DocumentStore, presets: PresetStore) async {
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

        nextJobID += 1
        let jobID = nextJobID
        activeJobID = jobID
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
                    progress: progressCallback
                )
            }
            return try input.plater.slice(
                to: outputURL.path,
                progress: progressCallback
            )
        }

        activeJobID = nil
        progress = nil
        switch result {
        case .success(let sliceResult):
            let outcome = CompletedSlice(
                sourceRevision: input.snapshot.revision,
                presetSelection: presetSelection,
                outputURL: outputURL,
                result: sliceResult
            )
            lastOutcome = outcome
            let minutes = Int(sliceResult.timeEstimateSeconds / 60)
            let kilobytes = sliceResult.gcodeBytes / 1024
            status.report(
                .slice,
                "\(instanceCount) instance(s): G-code ready\n" +
                    "\(kilobytes) KB · ~\(minutes) min print · " +
                    "Files → On My iPhone → OrcaPad"
            )
        case .failure(let failure):
            lastFailure = failure
            status.report(.slice, failure: failure)
        }
    }
}
