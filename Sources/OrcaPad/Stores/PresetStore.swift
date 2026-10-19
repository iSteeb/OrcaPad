// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

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
    let bedType: BedTypeState
    let editedConfigs: [PresetKind: [String: String]]
    let systemConfigs: [PresetKind: [String: String]]
    let filamentSlots: [EnginePresets.FilamentSlot]
    let warning: AppFailure?
    /// Non-failure, UI-visible note from the load (e.g. a stored selection
    /// that is no longer listed was replaced by the engine defaults).
    let notice: String?

    init(engine: EnginePresets, machines: [PresetEntry], filaments: [PresetEntry],
         processes: [PresetEntry], selection: PresetSelection,
         printVolume: PrintVolume, bedType: BedTypeState,
         editedConfigs: [PresetKind: [String: String]],
         systemConfigs: [PresetKind: [String: String]],
         filamentSlots: [EnginePresets.FilamentSlot] = [],
         warning: AppFailure?, notice: String? = nil) {
        self.engine = engine
        self.machines = machines
        self.filaments = filaments
        self.processes = processes
        self.selection = selection
        self.printVolume = printVolume
        self.bedType = bedType
        self.editedConfigs = editedConfigs
        self.systemConfigs = systemConfigs
        self.filamentSlots = filamentSlots
        self.warning = warning
        self.notice = notice
    }
}

/// Desktop `app_config` per-printer `curr_bed_type` memory: the engine resets
/// the plate type to the machine default on machine change, then the user's
/// last choice for that machine is re-applied when still valid.
private enum BedTypeMemory {
    static let key = "preset.bedTypes"

    static func load() -> [String: Int32] {
        let raw = UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:]
        return raw.mapValues(Int32.init)
    }

    static func store(_ memory: [String: Int32]) {
        UserDefaults.standard.set(memory.mapValues(Int.init), forKey: key)
    }

    /// Re-applies the remembered choice. Returns the resulting engine state
    /// and whether the remembered value was stale (no longer offered).
    static func apply(
        _ remembered: Int32?,
        engine: EnginePresets
    ) throws -> (BedTypeState, stale: Bool) {
        let state = try engine.bedType().get()
        guard let remembered, remembered != state.current else { return (state, false) }
        guard state.selectable, state.supported.contains(remembered) else {
            return (state, true)
        }
        try engine.setBedType(remembered).get()
        return (try engine.bedType().get(), false)
    }
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
    /// Project plate type (`curr_bed_type`); nil until presets are ready.
    private(set) var bedType: BedTypeState?
    private var bedTypeMemory = BedTypeMemory.load()
    /// Per-kind edited (working) and selected-system config dumps. Diffing the
    /// two is how the editor detects modified values — engine truth, no
    /// client-side default tables.
    private(set) var editedConfigs: [PresetKind: [String: String]] = [:]
    private(set) var systemConfigs: [PresetKind: [String: String]] = [:]

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
        let memory = bedTypeMemory
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
            var notice: String?
            // Only a stored selection that is still listed can be restored.
            // Anything else is the fresh-install default triple ("Default
            // Printer" & co, which are not listed presets) or presets that no
            // longer exist: keep the engine defaults either way.
            func listed(_ name: String, in entries: [PresetEntry]) -> Bool {
                entries.contains { $0.name == name }
            }
            if stored.isComplete,
               listed(stored.machine, in: machines),
               listed(stored.filament, in: filaments),
               listed(stored.process, in: processes) {
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
                    // Explicit recovery for a rejected combination: retain
                    // the engine defaults and report the typed rejection.
                    warning = .bridge(error)
                }
            } else if stored.isComplete {
                notice = "stored preset no longer available; using engine defaults"
            }
            // Compatibility flags are correct for whatever is selected.
            let refreshedProcesses = try engine.entries(kind: .process).get()
            let volume = try engine.printVolume().get()
            let (bedType, staleBedType) = try BedTypeMemory.apply(
                memory[selected.machine], engine: engine
            )
            if staleBedType, warning == nil {
                warning = .invariant(
                    operation: "restore plate type",
                    diagnostic: "remembered plate type is no longer offered by \(selected.machine)"
                )
            }
            var edited: [PresetKind: [String: String]] = [:]
            var system: [PresetKind: [String: String]] = [:]
            for kind in [PresetKind.machine, .filament, .process] {
                edited[kind] = try engine.configDump(kind: kind, edited: true).get()
                system[kind] = try engine.configDump(kind: kind, edited: false).get()
            }
            return PresetLoadPayload(
                engine: engine,
                machines: machines,
                filaments: filaments,
                processes: refreshedProcesses,
                selection: selected,
                printVolume: volume,
                bedType: bedType,
                editedConfigs: edited,
                systemConfigs: system,
                warning: warning,
                notice: notice
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
            bedType = payload.bedType
            rememberBedType(payload.bedType, machine: payload.selection.machine)
            editedConfigs = payload.editedConfigs
            systemConfigs = payload.systemConfigs
            persist(payload.selection)
            phase = .ready
            if let warning = payload.warning {
                status.report(
                    .presets,
                    "stored preset rejected; using engine defaults — " +
                        warning.localizedDescription
                )
            } else if let notice = payload.notice {
                status.report(.presets, notice)
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
        // Value snapshots for the nonisolated background closure.
        let current = selection
        let memory = bedTypeMemory
        isSelecting = true
        let result = await BackgroundWork.run(operation: "select presets") {
            switch kind {
            case .machine:
                // Desktop printer change: the engine resolves a compatible
                // process and filament (machine-declared defaults while the
                // selection is still a default preset, then
                // update_compatible(Always)).
                try engine.selectMachine(name).get()
            case .filament:
                try engine.select(
                    machine: current.machine,
                    filament: name,
                    process: current.process
                ).get()
            case .process:
                try engine.select(
                    machine: current.machine,
                    filament: current.filament,
                    process: name
                ).get()
            }
            // The engine owns the resulting triple (a machine change may swap
            // the filament and process); the client never guesses.
            let selected = PresetSelection(
                machine: try engine.current(kind: .machine).get(),
                filament: try engine.current(kind: .filament).get(),
                process: try engine.current(kind: .process).get()
            )
            let bedType = try BedTypeMemory.apply(
                memory[selected.machine], engine: engine
            )
            // Selection changes invalidate process compatibility, the bed,
            // and the edited/system config pair (selecting resets the edited
            // working copy). Re-read engine state; the client never guesses.
            var edited: [PresetKind: [String: String]] = [:]
            var system: [PresetKind: [String: String]] = [:]
            for kind in [PresetKind.machine, .filament, .process] {
                edited[kind] = try engine.configDump(kind: kind, edited: true).get()
                system[kind] = try engine.configDump(kind: kind, edited: false).get()
            }
            return (
                selected,
                try engine.entries(kind: .process).get(),
                try engine.printVolume().get(),
                edited,
                system,
                bedType
            )
        }
        isSelecting = false
        switch result {
        case .success((
            let selected,
            let refreshedProcesses,
            let volume,
            let edited,
            let system,
            let bed
        )):
            selection = selected
            processes = refreshedProcesses
            printVolume = volume
            bedType = bed.0
            if bed.stale {
                bedTypeMemory[selected.machine] = nil
                BedTypeMemory.store(bedTypeMemory)
                status.report(.presets, failure: .invariant(
                    operation: "restore plate type",
                    diagnostic: "remembered plate type is no longer offered by \(selected.machine)"
                ))
            }
            editedConfigs = edited
            systemConfigs = system
            persist(selected)
            status.report(.presets, "presets: selection ready")
        case .failure(let failure):
            status.report(.presets, failure: failure)
        }
    }

    // MARK: Exclusive engine sessions (project open/save)

    /// Runs `body` while preset edits/selection are blocked — for operations
    /// that read or replace the engine preset session from another store.
    func withExclusiveSession(_ body: () async -> Void) async {
        guard isReady, !isSelecting else {
            status.report(.presets, "preset session busy")
            return
        }
        isSelecting = true
        await body()
        isSelecting = false
    }

    /// Re-reads every listing, the selection, bed, plate type and dumps from
    /// the engine after an external replacement of the session (project
    /// open). Only valid inside `withExclusiveSession`.
    func reloadFromEngine() async {
        precondition(isSelecting, "reloadFromEngine requires an exclusive preset session")
        if await refreshFromEngine() {
            status.report(.presets, "presets: project settings loaded")
        }
    }

    // MARK: Multi-filament (desktop Sidebar filament list, ABI v31)

    private(set) var filamentSlots: [EnginePresets.FilamentSlot] = []

    var filamentCount: Int { filamentSlots.count }

    private func refreshFilamentSlots() async {
        guard let engine else {
            filamentSlots = []
            return
        }
        let result = await BackgroundWork.run(operation: "load filament slots") {
            try engine.filamentSlots().get()
        }
        switch result {
        case .success(let slots): filamentSlots = slots
        case .failure: filamentSlots = []
        }
    }

    func addFilament() async {
        guard let engine, isReady, !isSelecting else {
            status.report(.presets, "add filament blocked: presets are busy")
            return
        }
        isSelecting = true
        defer { isSelecting = false }
        let targetCount = filamentSlots.count + 1
        let result = await BackgroundWork.run(operation: "add filament") {
            try engine.setFilamentCount(targetCount).get()
        }
        switch result {
        case .success:
            await refreshFilamentSlots()
            status.report(.presets, "filament added (slot \(filamentSlots.count))")
        case .failure(let failure):
            status.report(.presets, failure: failure)
        }
    }

    func removeFilament(slot: Int) async {
        guard let engine, isReady, !isSelecting, filamentSlots.count > 1,
              slot >= 0, slot < filamentSlots.count else {
            status.report(.presets, "remove filament blocked")
            return
        }
        isSelecting = true
        defer { isSelecting = false }
        let targetCount = filamentSlots.count - 1
        let result = await BackgroundWork.run(operation: "remove filament") {
            try engine.setFilamentCount(targetCount).get()
        }
        switch result {
        case .success:
            await refreshFilamentSlots()
            status.report(.presets, "filament removed (slot \(slot + 1))")
        case .failure(let failure):
            status.report(.presets, failure: failure)
        }
    }

    func selectFilamentPreset(slot: Int, name: String) async {
        guard let engine, isReady, !isSelecting,
              slot >= 0, slot < filamentSlots.count else {
            status.report(.presets, "filament preset change blocked")
            return
        }
        isSelecting = true
        defer { isSelecting = false }
        let result = await BackgroundWork.run(operation: "select filament preset") {
            try engine.selectFilament(slot: slot, presetName: name).get()
        }
        switch result {
        case .success:
            await refreshFilamentSlots()
            status.report(.presets, "slot \(slot + 1): \(name)")
        case .failure(let failure):
            status.report(.presets, failure: failure)
        }
    }

    func setFilamentColour(slot: Int, colour: String) async {
        guard let engine, isReady, !isSelecting,
              slot >= 0, slot < filamentSlots.count else {
            status.report(.presets, "filament colour change blocked")
            return
        }
        isSelecting = true
        defer { isSelecting = false }
        let result = await BackgroundWork.run(operation: "set filament colour") {
            try engine.setFilamentColour(slot: slot, colour: colour).get()
        }
        switch result {
        case .success:
            await refreshFilamentSlots()
        case .failure(let failure):
            status.report(.presets, failure: failure)
        }
    }

    // MARK: User presets (desktop Save / Delete preset)

    func origin(of kind: PresetKind) -> PresetOrigin? {
        let name: String
        let entries: [PresetEntry]
        switch kind {
        case .machine: name = selection.machine; entries = machines
        case .filament: name = selection.filament; entries = filaments
        case .process: name = selection.process; entries = processes
        }
        return entries.first { $0.name == name }?.origin
    }

    func saveUserPreset(kind: PresetKind, name: String, detach: Bool) async {
        guard let engine, isReady, !isSelecting else {
            status.report(.presets, "save preset blocked: presets are busy")
            return
        }
        isSelecting = true
        defer { isSelecting = false }
        let result = await BackgroundWork.run(operation: "save user preset") {
            try engine.saveUser(kind: kind, name: name, detach: detach).get()
        }
        switch result {
        case .success:
            if await refreshFromEngine() {
                status.report(.presets, "preset saved: \(name)")
            }
        case .failure(let failure):
            status.report(.presets, failure: failure)
        }
    }

    func deleteUserPreset(kind: PresetKind, name: String) async {
        guard let engine, isReady, !isSelecting else {
            status.report(.presets, "delete preset blocked: presets are busy")
            return
        }
        isSelecting = true
        defer { isSelecting = false }
        let result = await BackgroundWork.run(operation: "delete user preset") {
            try engine.deleteUser(kind: kind, name: name).get()
        }
        switch result {
        case .success:
            if await refreshFromEngine() {
                status.report(.presets, "preset deleted: \(name)")
            }
        case .failure(let failure):
            status.report(.presets, failure: failure)
        }
    }

    /// Re-reads every listing, the selection, bed, plate type and dumps.
    private func refreshFromEngine() async -> Bool {
        guard let engine else { return false }
        let result = await BackgroundWork.run(operation: "reload presets") {
            let machines = try engine.entries(kind: .machine).get()
            let filaments = try engine.entries(kind: .filament).get()
            let processes = try engine.entries(kind: .process).get()
            let selection = PresetSelection(
                machine: try engine.current(kind: .machine).get(),
                filament: try engine.current(kind: .filament).get(),
                process: try engine.current(kind: .process).get()
            )
            var edited: [PresetKind: [String: String]] = [:]
            var system: [PresetKind: [String: String]] = [:]
            for kind in [PresetKind.machine, .filament, .process] {
                edited[kind] = try engine.configDump(kind: kind, edited: true).get()
                system[kind] = try engine.configDump(kind: kind, edited: false).get()
            }
            let slots = try engine.filamentSlots().get()
            return PresetLoadPayload(
                engine: engine,
                machines: machines,
                filaments: filaments,
                processes: processes,
                selection: selection,
                printVolume: try engine.printVolume().get(),
                bedType: try engine.bedType().get(),
                editedConfigs: edited,
                systemConfigs: system,
                filamentSlots: slots,
                warning: nil
            )
        }
        switch result {
        case .success(let payload):
            machines = payload.machines
            filaments = payload.filaments
            processes = payload.processes
            selection = payload.selection
            printVolume = payload.printVolume
            bedType = payload.bedType
            editedConfigs = payload.editedConfigs
            systemConfigs = payload.systemConfigs
            filamentSlots = payload.filamentSlots
            // Project/external presets are session-only: persist a selection
            // only when every preset survives a relaunch.
            let pairs: [([PresetEntry], String)] = [
                (payload.machines, payload.selection.machine),
                (payload.filaments, payload.selection.filament),
                (payload.processes, payload.selection.process),
            ]
            let durable: Bool = pairs.allSatisfy { entries, name in
                let entry: PresetEntry? = entries.first { $0.name == name }
                if let entry {
                    return entry.origin == .system || entry.origin == .user
                }
                return false
            }
            if durable { persist(payload.selection) }
            return true
        case .failure(let failure):
            status.report(.presets, failure: failure)
            return false
        }
    }

    // MARK: Plate type (desktop sidebar "Plate type")

    func setBedType(_ value: Int32) async {
        guard let engine, isReady, !isSelecting else {
            status.report(.presets, "plate type change blocked: presets are busy")
            return
        }
        let machine = selection.machine
        let result = await BackgroundWork.run(operation: "set plate type") {
            try engine.setBedType(value).get()
            return try engine.bedType().get()
        }
        switch result {
        case .success(let state):
            bedType = state
            bedTypeMemory[machine] = state.current
            BedTypeMemory.store(bedTypeMemory)
            status.update(.presets, "presets: plate type set")
        case .failure(let failure):
            status.report(.presets, failure: failure)
        }
    }

    private func rememberBedType(_ state: BedTypeState, machine: String) {
        guard bedTypeMemory[machine] != nil, bedTypeMemory[machine] != state.current else { return }
        // Stale memory (value no longer offered): drop it; load() reported it.
        bedTypeMemory[machine] = nil
        BedTypeMemory.store(bedTypeMemory)
    }

    // MARK: Desktop-parity config overrides

    /// Writes a serialized override into the edited preset of `kind` and
    /// refreshes the engine dumps for that kind.
    func setValue(
        kind: PresetKind,
        key: String,
        serializedValue: String
    ) async {
        guard let engine, isReady, !isSelecting else {
            status.report(.presets, "setting change blocked: presets are busy")
            return
        }
        let result = await BackgroundWork.run(operation: "set config value") {
            try engine.setValue(
                kind: kind,
                key: key,
                serializedValue: serializedValue
            ).get()
            return (
                try engine.configDump(kind: kind, edited: true).get(),
                try engine.configDump(kind: kind, edited: false).get()
            )
        }
        switch result {
        case .success((let edited, let system)):
            editedConfigs[kind] = edited
            systemConfigs[kind] = system
            status.update(.presets, "presets: \(key) modified")
        case .failure(let failure):
            status.report(.presets, failure: failure)
        }
    }

    /// Restores one key of the edited preset of `kind` from its selection.
    func resetValue(kind: PresetKind, key: String) async {
        guard let engine, isReady, !isSelecting else {
            status.report(.presets, "value reset blocked: presets are busy")
            return
        }
        let result = await BackgroundWork.run(operation: "reset config value") {
            try engine.resetValue(kind: kind, key: key).get()
            return (
                try engine.configDump(kind: kind, edited: true).get(),
                try engine.configDump(kind: kind, edited: false).get()
            )
        }
        switch result {
        case .success((let edited, let system)):
            editedConfigs[kind] = edited
            systemConfigs[kind] = system
        case .failure(let failure):
            status.report(.presets, failure: failure)
        }
    }

    /// Restores the whole edited preset of `kind` from its selection.
    func resetKind(_ kind: PresetKind) async {
        guard let engine, isReady, !isSelecting else {
            status.report(.presets, "reset blocked: presets are busy")
            return
        }
        let result = await BackgroundWork.run(operation: "reset preset kind") {
            try engine.resetKind(kind).get()
            return (
                try engine.configDump(kind: kind, edited: true).get(),
                try engine.configDump(kind: kind, edited: false).get()
            )
        }
        switch result {
        case .success((let edited, let system)):
            editedConfigs[kind] = edited
            systemConfigs[kind] = system
            status.update(.presets, "presets: modifications reset")
        case .failure(let failure):
            status.report(.presets, failure: failure)
        }
    }

    /// Engine-derived membership: an option belongs to a preset kind when the
    /// kind's selected system presets actually define the key — no
    /// client-side desktop page tables to drift.
    func definesKey(_ key: String, kind: PresetKind) -> Bool {
        systemConfigs[kind]?[key] != nil
    }

    func modifiedKeys(in kind: PresetKind) -> Set<String> {
        guard let edited = editedConfigs[kind],
              let system = systemConfigs[kind] else { return [] }
        var modified = Set<String>()
        for (key, value) in edited where system[key] != value {
            modified.insert(key)
        }
        for key in system.keys where edited[key] == nil {
            modified.insert(key)
        }
        return modified
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
