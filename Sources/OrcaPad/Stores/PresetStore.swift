import Foundation
import Observation
import OrcaBridge

struct PresetSelection: Equatable, Sendable {
    var machine: String
    var filament: String
    var process: String

    static let empty = PresetSelection(
        machine: "",
        filament: "",
        process: ""
    )

    var isComplete: Bool {
        !machine.isEmpty && !filament.isEmpty && !process.isEmpty
    }
}

private struct PresetLoadPayload: Sendable {
    let engine: EnginePresets
    let machines: [PresetEntry]
    let filaments: [PresetEntry]
    let processes: [PresetEntry]
    let selection: PresetSelection
    let printVolume: PrintVolume
    let warning: AppFailure?
}

@MainActor
@Observable
final class PresetStore {
    enum Phase: Sendable {
        case idle
        case loading
        case ready
        case failed(AppFailure)
    }

    private enum DefaultsKey {
        static let machine = "preset.machine"
        static let filament = "preset.filament"
        static let process = "preset.process"
    }

    private let status: StatusCenter
    private var engine: EnginePresets?
    private(set) var phase: Phase = .idle
    private(set) var machines: [PresetEntry] = []
    private(set) var filaments: [PresetEntry] = []
    private(set) var processes: [PresetEntry] = []
    private(set) var selection: PresetSelection = .empty
    private(set) var isSelecting = false
    /// Selected machine's print volume; nil until presets are ready.
    private(set) var printVolume: PrintVolume?

    init(status: StatusCenter) {
        self.status = status
    }

    var isReady: Bool {
        if case .ready = phase { return true }
        return false
    }

    var engineForSlicing: EnginePresets? { engine }

    func load() async {
        switch phase {
        case .idle, .failed:
            break
        case .loading, .ready:
            return
        }
        phase = .loading
        status.report(.presets, "presets: loading…")
        let stored = PresetSelection(
            machine: UserDefaults.standard.string(
                forKey: DefaultsKey.machine
            ) ?? "",
            filament: UserDefaults.standard.string(
                forKey: DefaultsKey.filament
            ) ?? "",
            process: UserDefaults.standard.string(
                forKey: DefaultsKey.process
            ) ?? ""
        )
        let result = await BackgroundWork.run(operation: "load presets") {
            let dataDirectory = try EnginePaths.preparePresetDataDirectory()
            let engine = try EnginePresets.create(
                dataDir: dataDirectory.path
            ).get()
            let machines = try engine.entries(kind: .machine).get()
            let filaments = try engine.entries(kind: .filament).get()
            let processes = try engine.entries(kind: .process).get()
            let defaults = PresetSelection(
                machine: try engine.current(kind: .machine).get(),
                filament: try engine.current(kind: .filament).get(),
                process: try engine.current(kind: .process).get()
            )

            var selected = defaults
            var warning: AppFailure?
            if stored.isComplete {
                do {
                    try engine.select(
                        machine: stored.machine,
                        filament: stored.filament,
                        process: stored.process
                    ).get()
                    selected = stored
                } catch let error as BridgeError
                    where error.status == .notFound ||
                        error.status == .invalidConfiguration {
                    // Explicit recovery for removed/incompatible persisted
                    // presets: retain the engine defaults and replace the
                    // obsolete selection after reporting the typed rejection.
                    warning = .bridge(error)
                }
            }
            // Compatibility flags change once a concrete machine is selected.
            let refreshedProcesses = stored.isComplete && warning == nil
                ? try engine.entries(kind: .process).get()
                : processes
            return PresetLoadPayload(
                engine: engine,
                machines: machines,
                filaments: filaments,
                processes: refreshedProcesses,
                selection: selected,
                printVolume: try engine.printVolume().get(),
                warning: warning
            )
        }

        switch result {
        case .success(let payload):
            engine = payload.engine
            machines = payload.machines
            filaments = payload.filaments
            processes = payload.processes
            selection = payload.selection
            printVolume = payload.printVolume
            persist(payload.selection)
            phase = .ready
            if let warning = payload.warning {
                status.report(
                    .presets,
                    "stored preset rejected; using engine defaults — " +
                        warning.localizedDescription
                )
            } else {
                status.report(.presets, "presets: ready")
            }
        case .failure(let failure):
            phase = .failed(failure)
            status.report(.presets, failure: failure)
        }
    }

    func select(kind: PresetKind, name: String) async {
        guard let engine, isReady, !isSelecting else {
            status.report(.presets, "preset selection blocked: presets are busy")
            return
        }
        var candidate = selection
        switch kind {
        case .machine: candidate.machine = name
        case .filament: candidate.filament = name
        case .process: candidate.process = name
        }
        guard candidate.isComplete else {
            status.report(
                .presets,
                failure: .invariant(
                    operation: "select presets",
                    diagnostic: "preset selection is incomplete"
                )
            )
            return
        }

        let requested = candidate
        isSelecting = true
        let result = await BackgroundWork.run(operation: "select presets") {
            try engine.select(
                machine: requested.machine,
                filament: requested.filament,
                process: requested.process
            ).get()
            // Selection changes can invalidate process compatibility and
            // the bed; re-read engine state so the client never guesses it.
            return (
                try engine.entries(kind: .process).get(),
                try engine.printVolume().get()
            )
        }
        isSelecting = false
        switch result {
        case .success((let refreshedProcesses, let volume)):
            selection = requested
            processes = refreshedProcesses
            printVolume = volume
            persist(requested)
            status.report(.presets, "presets: selection ready")
        case .failure(let failure):
            status.report(.presets, failure: failure)
        }
    }

    func names(for kind: PresetKind) -> [PresetEntry] {
        switch kind {
        case .machine: return machines
        case .filament: return filaments
        case .process: return processes
        }
    }

    func selectedName(for kind: PresetKind) -> String {
        switch kind {
        case .machine: return selection.machine
        case .filament: return selection.filament
        case .process: return selection.process
        }
    }

    private func persist(_ selection: PresetSelection) {
        UserDefaults.standard.set(
            selection.machine,
            forKey: DefaultsKey.machine
        )
        UserDefaults.standard.set(
            selection.filament,
            forKey: DefaultsKey.filament
        )
        UserDefaults.standard.set(
            selection.process,
            forKey: DefaultsKey.process
        )
    }
}
