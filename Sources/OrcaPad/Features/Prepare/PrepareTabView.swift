// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

import OrcaBridge
import SwiftUI

/// Prepare tab (desktop parity): printer and filament presets with their
/// settings screens, the process preset with its desktop pages inline
/// (Quality / Strength / Speed / Support / Multimaterial / Others), a
/// Simple/Advanced/Expert filter, and the Slice action in the toolbar.
struct PrepareTabView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var activeKind: PresetKind = .process
    @State private var activePage: String?
    @State private var expandedKind: PresetKind?
    /// Desktop Preferences parity: hide incompatible presets GLOBALLY.
    @AppStorage("presets.filterCompatible") private var filterCompatible = true
    @State private var setupPresented = false
    /// Per-kind mode memory (user spec: simple for printer, advanced for
    /// process, remembered across switches). Persisted per kind.
    @State private var kindModes: [PresetKind: SettingsModeFilter] =
        Dictionary(uniqueKeysWithValues: PresetKind.allCases.map { kind in
            (kind, UserDefaults.standard.string(forKey: "prepare.mode.\(kind)")
                .flatMap(SettingsModeFilter.init(rawValue:)) ?? .simple)
        })
    private var modeFilter: SettingsModeFilter {
        get { kindModes[activeKind] ?? .simple }
    }
    @State private var search = ""
    @State private var showAllProcesses = false
    /// Desktop UnsavedChangesDialog: a selection waiting for a decision
    /// about the modified preset it would replace.
    @State private var pendingSelection: PendingSelection?
    @State private var importPresetPresented = false
    @State private var importBundlePresented = false

    private struct PendingSelection: Identifiable {
        let kind: PresetKind
        let name: String
        let modified: Int
        var id: String { "\(kind.rawValue)|\(name)" }
    }

    private var presets: PresetStore { environment.presets }

    var body: some View {
        NavigationStack {
            Group {
                switch presets.phase {
                case .idle, .loading:
                    ProgressView("loading presets…")
                case .failed(let failure):
                    ContentUnavailableView {
                        Label("Presets unavailable", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(failure.localizedDescription)
                    } actions: {
                        Button("Retry") { Task { await presets.load() } }
                    }
                case .ready:
                    editor
                }
            }
            .navigationTitle("Prepare")
                .toolbar(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .primaryAction) { sliceButton }
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic))
            .confirmationDialog(
                "Unsaved changes",
                isPresented: Binding(
                    get: { pendingSelection != nil },
                    set: { if !$0 { pendingSelection = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingSelection
            ) { pending in
                Button("Discard \(pending.modified) change(s) and switch", role: .destructive) {
                    Task { await presets.select(kind: pending.kind, name: pending.name) }
                }
                Button("Keep editing", role: .cancel) {}
            } message: { pending in
                Text("The current preset has \(pending.modified) modified setting(s). Save them as a user preset from the preset menu first, or discard them.")
            }
        }
    }

    // MARK: Slice action (desktop parity: top toolbar)

    @ViewBuilder
    private var sliceButton: some View {
        if environment.slicing.isSlicing {
            Button {
                environment.slicing.cancel()
            } label: {
                HStack(spacing: 6) {
                    ProgressView(
                        value: Double(environment.slicing.progress?.percent ?? 0),
                        total: 100
                    )
                    .frame(width: 64)
                    Image(systemName: "xmark.circle.fill")
                }
            }
            .accessibilityLabel("Cancel slicing")
        } else {
            Menu {
                Button {
                    Task {
                        await environment.slicing.run(
                            document: environment.document,
                            presets: presets
                        )
                    }
                } label: {
                    Label("Slice", systemImage: "scissors")
                }
                if environment.document.plates.count > 1 {
                    Button {
                        Task {
                            await environment.slicing.runAll(
                                document: environment.document,
                                presets: presets
                            )
                        }
                    } label: {
                        Label(
                            "Slice All Plates",
                            systemImage: "square.stack.3d.up.fill"
                        )
                    }
                }
            } label: {
                Label("Slice", systemImage: "scissors")
                    .font(.headline)
            } primaryAction: {
                Task {
                    await environment.slicing.run(
                        document: environment.document,
                        presets: presets
                    )
                }
            }
            .disabled(
                environment.document.scene?.objects.isEmpty != false ||
                    environment.document.isBusy ||
                    presets.isSelecting
            )
        }
    }

    // MARK: Editor

    private var editor: some View {
        VStack(spacing: 0) {
            preparePill
                .padding(.horizontal, 12)
                .padding(.top, 4)
            if !presets.hasListedMachine {
                // Fresh install sits on the "- default -" printer; slicing
                // is refused (SliceService) until a real machine is selected
                // — show why, instead of a dead button.
                Label(
                    "Select a printer under Printer to enable slicing",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.yellow)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, 6)
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search settings", text: $search)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if !search.isEmpty {
                    Button {
                        search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.horizontal, 12)
            .padding(.top, 6)
            settingsList
        }
        .sheet(isPresented: $setupPresented) {
            SetupWizardSheet(presets: presets)
        }
        .fileImporter(
            isPresented: $importPresetPresented,
            allowedContentTypes: [.json],
            onCompletion: { result in
                if case .success(let url) = result {
                    Task { await presets.importPreset(at: url) }
                }
            }
        )
        .fileImporter(
            isPresented: $importBundlePresented,
            allowedContentTypes: [.json],
            onCompletion: { result in
                if case .success(let url) = result {
                    Task { await presets.importBundle(at: url) }
                }
            }
        )
    }

    /// The Prepare chrome: ONE wide, horizontally SCROLLABLE pill.
    /// [Mode] | [Printer][Filament][Process] | active kind's page chips
    /// (Quality / Strength / Support … for process). Mode memory is
    /// per-kind; kind buttons select presets and focus their settings.
    private var preparePill: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                Button {
                    let order: [SettingsModeFilter] = [.simple, .advanced, .expert]
                    setMode(order[(order.firstIndex(of: modeFilter).map { ($0 + 1) % order.count } ?? 0)])
                } label: {
                    ChromeToolLabel(
                        symbol: modeFilter.symbol,
                        label: modeFilter.rawValue
                    )
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings level: \(modeFilter.rawValue)")
                Divider().frame(height: 28)
                kindButton(.machine, symbol: "printer", label: "Printer")
                kindButton(.filament, symbol: "circle.dotted.circle", label: "Filament")
                kindButton(.process, symbol: "slider.horizontal.3", label: "Process")
                Divider().frame(height: 28)
                pageChips
                Spacer(minLength: 4)
                // Desktop Setup Wizard entry: pick printers + which
                // filaments belong in the lists (installed sets).
                Button {
                    setupPresented = true
                } label: {
                    ChromeToolLabel(
                        symbol: "wand.and.stars",
                        label: "Setup"
                    )
                    .foregroundStyle(presets.isConfigured ? Color.primary : Color.accentColor)
                }
                .buttonStyle(.plain)
                // Global preset filter (desktop Preferences: hide
                // incompatible presets everywhere) — persisted.
                Button {
                    filterCompatible.toggle()
                } label: {
                    ChromeToolLabel(
                        symbol: filterCompatible ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle",
                        label: "Filter"
                    )
                    .foregroundStyle(filterCompatible ? Color.accentColor : Color.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(filterCompatible
                    ? "Filtering incompatible presets (tap to show all)"
                    : "Showing all presets (tap to filter)")
                Divider().frame(height: 28)
                Menu {
                    Button {
                        importPresetPresented = true
                    } label: {
                        Label("Import preset\u{2026}", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        importBundlePresented = true
                    } label: {
                        Label("Import config bundle\u{2026}", systemImage: "shippingbox")
                    }
                    Divider()
                    Button {
                        Task { await presets.exportCurrentConfigs() }
                    } label: {
                        Label("Export current presets\u{2026}", systemImage: "square.and.arrow.up")
                    }
                    if let exported = presets.lastExportDirectory {
                        ShareLink(item: exported) {
                            Label("Share \(exported.lastPathComponent)", systemImage: "square.and.arrow.up.circle")
                        }
                    }
                } label: {
                    ChromeToolLabel(symbol: "arrow.left.arrow.right.square", label: "Configs")
                }
                .buttonStyle(.plain)
                Divider().frame(height: 28)
                slicePillButton
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 6)
        }
        .frame(height: 58)
        .background(.ultraThinMaterial, in: Capsule())
        .clipShape(Capsule())  // scrolled content never overflows the pill
    }

    /// Slice, first-class in the pill (desktop's top-right primary action).
    @ViewBuilder
    private var slicePillButton: some View {
        if environment.slicing.isSlicing {
            Button {
                environment.slicing.cancel()
            } label: {
                HStack(spacing: 6) {
                    ProgressView(
                        value: Double(environment.slicing.progress?.percent ?? 0),
                        total: 100
                    )
                    .frame(width: 64)
                    Image(systemName: "xmark.circle.fill")
                }
                .frame(height: 44)
                .padding(.horizontal, 8)
            }
            .accessibilityLabel("Cancel slicing")
        } else {
            Button {
                Task {
                    await environment.slicing.run(
                        document: environment.document,
                        presets: presets
                    )
                }
            } label: {
                ChromeToolLabel(symbol: "scissors", label: "Slice")
                    .foregroundStyle(Color.white)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(
                environment.document.scene?.objects.isEmpty != false ||
                    environment.document.isBusy ||
                    presets.isSelecting || !presets.isReady
            )
            .opacity(environment.document.scene?.objects.isEmpty != false ? 0.35 : 1)
        }
    }

    private func setMode(_ filter: SettingsModeFilter) {
        kindModes[activeKind] = filter
        UserDefaults.standard.set(filter.rawValue, forKey: "prepare.mode.\(activeKind)")
        activePage = nil
    }

    /// Kind buttons SWITCH THE PAGE (the pill drives the main view); each
    /// page carries its own expandable categorized preset list.
    private func kindButton(_ kind: PresetKind, symbol: String, label: String) -> some View {
        let active = activeKind == kind
        return Button {
            activeKind = kind
            activePage = nil
        } label: {
            ChromeToolLabel(symbol: symbol, label: label)
                .foregroundStyle(active ? Color.white : Color.primary)
                .background(
                    active ? Color.accentColor : Color.clear,
                    in: RoundedRectangle(cornerRadius: 10)
                )
        }
        .buttonStyle(.plain)
    }

    private func presetList(for kind: PresetKind) -> [PresetEntry] {
        // Setup-wizard visibility first (desktop installed sets), then the
        // compatibility filter for filament/process.
        let visible = presets.visibleEntries(for: kind)
        switch kind {
        case .machine:
            return visible
        case .filament:
            return visible
        case .process:
            return showAllProcesses ? visible : visible.filter(\.isCompatible)
        }
    }

    private func currentPreset(for kind: PresetKind) -> String {
        switch kind {
        case .machine:
            return presets.selection.machine
        case .filament:
            return presets.selection.filament
        case .process:
            return presets.selection.process
        }
    }

    @ViewBuilder
    private func presetMenuButton(kind: PresetKind, entry: PresetEntry, selected: Bool) -> some View {
        Button {
            requestSelect(kind, entry.name)
        } label: {
            if selected {
                Label(entry.name, systemImage: "checkmark")
            } else {
                Text(entry.name)
            }
        }
    }

    /// The active kind's settings pages as scrollable chips in the pill
    /// (process: Quality / Strength / Support …).
    @ViewBuilder
    private var pageChips: some View {
        switch SettingsPageModel.build(
            kind: activeKind,
            edited: presets.editedConfigs[activeKind] ?? [:],
            modified: presets.modifiedKeys(in: activeKind),
            filter: modeFilter,
            search: ""
        ) {
        case .success(let pages):
            ForEach(pages) { page in
                Button {
                    activePage = page.title
                } label: {
                    Text(page.title)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .frame(height: 36)
                        .background(
                            activePage == page.title
                                ? Color.accentColor.opacity(0.18) : Color(.secondarySystemBackground),
                            in: Capsule()
                        )
                        .foregroundStyle(activePage == page.title ? Color.accentColor : Color.primary)
                }
                .buttonStyle(.plain)
            }
        case .failure:
            EmptyView()
        }
    }

    /// The pill drives the main view: ONE page per kind (user spec).
    /// Printer: current selection + categorized list + plate type + volume +
    ///   settings (defaults to the first page, e.g. Basic information).
    /// Filament / Process: their categorized list + their settings.
    private var settingsList: some View {
        List {
            switch activeKind {
            case .machine:
                presetPickerSection(.machine)
                printerInfoSection
                settingsSections(.machine)
            case .filament:
                presetPickerSection(.filament)
                settingsSections(.filament)
            case .process:
                presetPickerSection(.process)
                processActionsSection
                settingsSections(.process)
            }

            Section {
                NavigationLink {
                    ResolvedConfigView(presets: presets)
                } label: {
                    Label("Resolved configuration", systemImage: "doc.text.magnifyingglass")
                }
            } footer: {
                sliceFooter
            }
        }
    }

    /// Current selection + inline EXPANDABLE categorized preset list.
    @ViewBuilder
    private func presetPickerSection(_ kind: PresetKind) -> some View {
        Section {
            presetHeader(kind)
            if expandedKind == kind {
                InlinePresetList(
                    entries: presetList(for: kind),
                    selected: currentPreset(for: kind),
                    filterCompatible: filterCompatible,
                    globalFilter: filterCompatible
                ) { name in
                    requestSelect(kind, name)
                    expandedKind = nil
                }
            }
        }
    }

    private func presetHeader(_ kind: PresetKind) -> some View {
        let symbol: String
        switch kind {
        case .machine: symbol = "printer"
        case .filament: symbol = "circle.dotted.circle"
        case .process: symbol = "slider.horizontal.3"
        }
        return Button {
            withAnimation(.snappy(duration: 0.2)) {
                expandedKind = expandedKind == kind ? nil : kind
            }
        } label: {
            HStack {
                Label(currentPreset(for: kind), systemImage: symbol)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Spacer()
                Image(systemName: expandedKind == kind ? "chevron.up" : "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Printer-only info rows: plate type + print volume.
    private var printerInfoSection: some View {
        Section("Printer") {
            if let bedType = presets.bedType {
                PlateTypeRow(state: bedType) { value in
                    Task { await presets.setBedType(value) }
                }
                .disabled(presets.isSelecting)
            }
            if let volume = presets.printVolume {
                LabeledContent("Print volume") {
                    Text(String(format: "%.0f × %.0f mm", volume.width, volume.depth))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    private var processActionsSection: some View {
        Section("Process") {
            Toggle("Show incompatible processes", isOn: $showAllProcesses)
                .font(.caption)
            HStack {
                Text("Process preset")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                PresetActionsMenu(kind: .process)
                    .font(.caption)
            }
            let modified = presets.modifiedKeys(in: .process).count
            if modified > 0 {
                Button("Reset \(modified) modified process settings") {
                    Task { await presets.resetKind(.process) }
                }
                .font(.caption)
            }
        }
    }

    private func settingsSections(_ kind: PresetKind) -> some View {
        SettingsPagesSections(
            kind: kind,
            filter: kindModes[kind] ?? .simple,
            search: search,
            externalSelectedPage: Binding(
                get: { activePage },
                set: { activePage = $0 }
            )
        )
    }

    /// Selecting another preset discards the edited copy (engine
    /// select_preset), so modified presets ask first — desktop parity.
    private func requestSelect(_ kind: PresetKind, _ name: String) {
        let modified = presets.modifiedKeys(in: kind).count
        let current: String
        switch kind {
        case .machine: current = presets.selection.machine
        case .filament: current = presets.selection.filament
        case .process: current = presets.selection.process
        }
        if modified > 0 && name != current {
            pendingSelection = PendingSelection(kind: kind, name: name, modified: modified)
        } else {
            Task { await presets.select(kind: kind, name: name) }
        }
    }

    private func presetLabel(_ name: String, symbol: String) -> some View {
        Label(name.isEmpty ? "Not selected" : name, systemImage: symbol)
            .lineLimit(1)
    }

    private func settingsLabel(_ title: String, kind: PresetKind) -> some View {
        let modified = presets.modifiedKeys(in: kind).count
        return HStack {
            Label(title, systemImage: "gearshape")
            Spacer()
            if modified > 0 {
                Text("\(modified) modified")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    @ViewBuilder
    private var sliceFooter: some View {
        if let failure = environment.slicing.lastFailure {
            Text("Last slice failed: \(failure.localizedDescription)")
                .foregroundStyle(.red)
        } else if let outcome = environment.slicing.lastOutcome {
            HStack {
                Text(
                    "G-code ready — \(outcome.outputURL.lastPathComponent) · ~" +
                        "\(Int(outcome.result.timeEstimateSeconds / 60)) min"
                )
                Spacer()
                ShareLink(item: outcome.outputURL) {
                    Label("Export G-code", systemImage: "square.and.arrow.up")
                }
                .font(.caption.weight(.semibold))
            }
            SliceWarningsList(warnings: outcome.result.warnings)
        }
    }
}

/// Desktop sidebar "Plate type" (project `curr_bed_type`): bed temperatures
/// are chosen by it. Machines without selectable plates show the engine's
/// fixed default read-only. Labels come from the engine schema.
private struct PlateTypeRow: View {
    let state: BedTypeState
    let onSelect: (Int32) -> Void

    var body: some View {
        switch ConfigSchema.index {
        case .failure(let failure):
            Label(failure.localizedDescription, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        case .success(let index):
            let labels = index["curr_bed_type"]?.enumLabels ?? []
            if labels.count != Int(state.count) - 1 {
                Label(
                    "Plate type: schema has \(labels.count) labels, engine has \(state.count - 1) types",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.red)
            } else if state.selectable {
                Picker(selection: Binding(
                    get: { state.current },
                    set: { onSelect($0) }
                )) {
                    ForEach(state.supported, id: \.self) { value in
                        Text(label(value, labels)).tag(value)
                    }
                } label: {
                    Label("Plate type", systemImage: "square.grid.3x3.square")
                }
            } else {
                LabeledContent {
                    Text(label(state.current, labels)).foregroundStyle(.secondary)
                } label: {
                    Label("Plate type", systemImage: "square.grid.3x3.square")
                }
            }
        }
    }

    /// Engine BedType v (1-based) ↔ schema enum index v-1 (count verified).
    private func label(_ value: Int32, _ labels: [String]) -> String {
        labels[Int(value) - 1]
    }
}

/// Desktop slicing notifications parity: engine warnings after a slice, with
/// the desktop's texts for coded G-code warnings (Plater.cpp
/// get_slice_warning_string, GLCanvas3D.cpp conflict text).
struct SliceWarningsList: View {
    let warnings: [SliceWarning]

    init(warnings: [SliceWarning]) {
        // Desktop shows no text for "not_generate_timelapse" (Plater.cpp).
        self.warnings = warnings.filter { $0.code != "not_generate_timelapse" }
    }

    var body: some View {
        if !warnings.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: warning.level == .critical
                              ? "exclamationmark.octagon.fill"
                              : warning.level == .warning ? "exclamationmark.triangle.fill" : "info.circle")
                            .foregroundStyle(warning.level == .critical ? Color.red
                                             : warning.level == .warning ? Color.orange : Color.secondary)
                        Text(Self.text(for: warning))
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.top, 6)
        }
    }

    static func text(for warning: SliceWarning) -> String {
        let params = warning.detail.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        switch warning.code {
        case "bed_temperature_too_high_than_filament":
            return "The current hot bed temperature is relatively high. The nozzle may be clogged when printing this filament in a closed enclosure. Please open the front door and/or remove the upper glass."
        case "the_actual_nozzle_hrc_smaller_than_the_required_nozzle_hrc":
            return "The nozzle hardness required by the filament is higher than the default nozzle hardness of the printer. Please replace the hardened nozzle or filament, otherwise, the nozzle will be attrited or damaged."
        case "not_support_traditional_timelapse":
            return "Enabling traditional timelapse photography may cause surface imperfections. It is recommended to change to smooth mode."
        case "smooth_timelapse_without_prime_tower":
            return "Smooth mode for timelapse is enabled, but the prime tower is off, which may cause print defects. Please enable the prime tower, re-slice and print again."
        case "gcode_path_conflict" where params.count == 4:
            let z = Double(params[2]).map { String(format: "%.2f", $0) } ?? params[2]
            return "Conflicts of G-code paths have been found at layer \(params[3]), Z = \(z)mm. Please separate the conflicted objects farther (\(params[0]) <-> \(params[1]))."
        default:
            let base = warning.message.isEmpty ? warning.code : warning.message
            return warning.source == .objectStep && !warning.detail.isEmpty
                ? "\(warning.detail): \(base)" : base
        }
    }
}


/// Inline categorized preset list (the pill's kind pages embed it instead
/// of pushing a picker screen). Vendor sections, checkmark on the current
/// selection, warning glyph on incompatible entries.
private struct InlinePresetList: View {
    let entries: [PresetEntry]
    let selected: String
    /// Desktop preset combos: incompatible entries hidden unless asked.
    var filterCompatible = true
    /// Global preference passed down (desktop: filter presets everywhere).
    var globalFilter = true
    let onSelect: (String) -> Void

    @State private var search = ""
    @State private var showIncompatible = false

    private var visible: [PresetEntry] {
        let filtering = globalFilter ? !showIncompatible : false
        var list = filtering && entries.contains(where: { !$0.isCompatible })
            ? entries.filter(\.isCompatible)
            : entries
        if !search.isEmpty {
            list = list.filter {
                $0.name.localizedCaseInsensitiveContains(search) ||
                    $0.vendor.localizedCaseInsensitiveContains(search)
            }
        }
        return list
    }

    private var groups: [(vendor: String, entries: [PresetEntry])] {
        let visibleList = visible
        let others = visibleList.filter { $0.origin != .system }
        let byVendor = Dictionary(grouping: visibleList.filter { $0.origin == .system }) {
            $0.vendor.isEmpty ? "Other" : $0.vendor
        }
        var result: [(String, [PresetEntry])] = []
        if !others.isEmpty { result.append(("Project / user", others)) }
        result.append(contentsOf: byVendor.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 })
        return result
    }

    var body: some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search presets", text: $search)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            .font(.callout)
            if entries.contains(where: { !$0.isCompatible }) {
                Toggle("Show incompatible presets", isOn: $showIncompatible)
                    .font(.caption)
            }
        }
        ForEach(groups, id: \.vendor) { group in
            Section(group.vendor) {
                ForEach(group.entries, id: \.name) { entry in
                    Button {
                        onSelect(entry.name)
                    } label: {
                        HStack {
                            if entry.name == selected {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                            Text(entry.name)
                                .foregroundStyle(entry.isCompatible ? Color.primary : Color.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                            if !entry.isCompatible {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                            Spacer()
                        }
                    }
                }
            }
        }
    }
}

/// Desktop ConfigWizard parity (user spec): pick printers, then CHECK the
/// filaments that belong in the filament list. The checked sets persist and
/// every preset list shows only installed system presets (user/project
/// presets always show). Picking a printer pre-checks its compatible
/// filaments (desktop: default materials).
struct SetupWizardSheet: View {
    let presets: PresetStore

    enum Step: String, CaseIterable, Identifiable {
        case printers = "Printers"
        case filaments = "Filaments"

        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var step: Step = .printers
    @State private var selectedPrinters: Set<String> = []
    @State private var selectedFilaments: Set<String> = []
    @State private var search = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Step", selection: $step) {
                    ForEach(Step.allCases) { candidate in
                        Text(candidate.rawValue).tag(candidate)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                List {
                    switch step {
                    case .printers: printerGroups
                    case .filaments: filamentGroups
                    }
                }
                .listStyle(.insetGrouped)
            }
            .navigationTitle("Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        presets.setInstalled(
                            printers: selectedPrinters,
                            filaments: selectedFilaments
                        )
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            selectedPrinters = presets.installedPrinters
            selectedFilaments = presets.installedFilaments
        }
    }

    // MARK: Printers (vendor-grouped checklists)

    @ViewBuilder
    private var printerGroups: some View {
        ForEach(group(entries: presets.machines), id: \.0) { group in
            Section(group.0) {
                ForEach(group.1, id: \.name) { entry in
                    checkRow(
                        name: entry.name,
                        checked: selectedPrinters.contains(entry.name),
                        hint: !entry.isCompatible ? "incompatible with current filaments" : nil
                    ) {
                        if selectedPrinters.contains(entry.name) {
                            selectedPrinters.remove(entry.name)
                        } else {
                            selectedPrinters.insert(entry.name)
                            preselectCompatibleFilaments(with: entry)
                        }
                    }
                }
            }
        }
    }

    /// Desktop: picking a printer installs its default materials — we
    /// pre-check every filament compatible with it.
    private func preselectCompatibleFilaments(with printer: PresetEntry) {
        for entry in presets.filaments where entry.isCompatible {
            if entry.vendor == printer.vendor || entry.origin != .system {
                selectedFilaments.insert(entry.name)
            }
        }
    }

    // MARK: Filaments (vendor-grouped checklists)

    @ViewBuilder
    private var filamentGroups: some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search filaments", text: $search)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
        }
        ForEach(group(entries: filteredFilaments), id: \.0) { group in
            Section(group.0) {
                ForEach(group.1, id: \.name) { entry in
                    checkRow(
                        name: entry.name,
                        checked: selectedFilaments.contains(entry.name),
                        hint: !entry.isCompatible ? "not compatible with the selected printers" : nil
                    ) {
                        if selectedFilaments.contains(entry.name) {
                            selectedFilaments.remove(entry.name)
                        } else {
                            selectedFilaments.insert(entry.name)
                        }
                    }
                }
            }
        }
    }

    private var filteredFilaments: [PresetEntry] {
        guard !search.isEmpty else { return presets.filaments }
        return presets.filaments.filter {
            $0.name.localizedCaseInsensitiveContains(search) ||
                $0.vendor.localizedCaseInsensitiveContains(search)
        }
    }

    // MARK: helpers

    private func group(entries: [PresetEntry]) -> [(String, [PresetEntry])] {
        let others = entries.filter { $0.origin != .system }
        let byVendor = Dictionary(grouping: entries.filter { $0.origin == .system }) {
            $0.vendor.isEmpty ? "Other" : $0.vendor
        }
        var result: [(String, [PresetEntry])] = []
        if !others.isEmpty { result.append(("Project / user", others)) }
        result.append(contentsOf: byVendor.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 })
        return result
    }

    private func checkRow(
        name: String, checked: Bool, hint: String?, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(checked ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    if let hint {
                        Text(hint)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
            }
        }
    }
}
