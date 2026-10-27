// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

import OrcaBridge
import SwiftUI
import UniformTypeIdentifiers

/// Preview tab (desktop parity): toolpath with a vertical layer range slider,
/// a horizontal in-layer move scrubber with tool marker, color schemes
/// (line type / speed / layer height / line width), feature visibility
/// legend, and travel toggle. Data comes from the engine's GCodeProcessor.
struct PreviewTabView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var store = GcodePreviewStore()
    @State private var showLegend = false
    @State private var frameRequest = 0
    @State private var openPresented = false
    /// Last slice job consumed: tab re-appearance must not override an
    /// externally opened file, while every new slice replaces it.
    @State private var consumedSliceJob: UInt64?
    /// Desktop "Jump to layer": typed layer number.
    @State private var jumpLayerText = ""
    /// Desktop layer ticks: custom G-code (pause / colour change / custom).
    @State private var ticksPresented = false
    @State private var ticks: [EnginePlater.CustomGcodeItem] = []
    /// The shared add/edit tick editor (nil = dismissed).
    @State private var tickEditor: TickEditorTarget?
    /// Desktop "From template…" snippets (UserDefaults-backed).
    @State private var templates = CustomGcodeTemplatesStore()
    @State private var templatesPresented = false
    /// Desktop "Show G-code Window": the viewed layer's G-code text.
    @State private var lineWindowPresented = false
    /// Board §wave-b/4: toolpath → OBJ export, shared through the system
    /// sheet (the URL only exists after a background write).
    @State private var sharingOBJ: ShareURL?
    /// Board cycle-0.15: desktop "Total Estimation" panel as a sheet.
    @State private var summaryPresented = false

    /// Identifiable URL wrapper so `.sheet(item:)` can present the share
    /// sheet for an export that finished asynchronously.
    private struct ShareURL: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }

    /// Sheet(item:) driver for the add-tick editor (the list sheet owns
    /// its nested EDIT editor; this one presents only from the Tick menu).
    private struct TickEditorTarget: Identifiable {
        let height: Double
        var id: String { "add-\(height)" }
    }

    var body: some View {
        Group {
            switch store.phase {
            case .idle:
                ContentUnavailableView {
                    Label("Nothing to preview", systemImage: "eye")
                } description: {
                    Text("Slice a plate in Prepare, or open an existing G-code file.")
                } actions: {
                    Button("Open G-code…") { openPresented = true }
                }
            case .loading:
                ProgressView("parsing gcode…")
            case .failed(let failure):
                ContentUnavailableView {
                    Label("Preview unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(failure.localizedDescription)
                } actions: {
                    Button("Open G-code…") { openPresented = true }
                }
            case .ready:
                viewer
            }
        }
        .task(id: environment.slicing.lastOutcome?.jobID) {
            guard let outcome = environment.slicing.lastOutcome,
                  consumedSliceJob != outcome.jobID else { return }
            consumedSliceJob = outcome.jobID
            if outcome.plateSections.isEmpty {
                await store.load(
                    url: outcome.outputURL,
                    identity: "slice:\(outcome.jobID)",
                    origin: outcome.plateOrigin ?? .zero
                )
            } else {
                // Combined slice-all file: split at the ; ORCA_PLATE markers,
                // offset every section back to its plate's world position
                // (each section is plate-relative — without the offsets all
                // plates would stack on the bed origin).
                await store.loadPlateSections(
                    url: outcome.outputURL,
                    identity: "slice:\(outcome.jobID)",
                    origins: Dictionary(
                        uniqueKeysWithValues: outcome.plateSections.map {
                            ($0.plateIndex, $0.origin)
                        })
                )
            }
            frameRequest += 1
        }
        .fileImporter(
            isPresented: $openPresented,
            allowedContentTypes: GcodeTypes.all,
            onCompletion: openExternal
        )
        .task(id: environment.document.scene?.revision.rawValue) {
            await reloadTicks()
        }
        .sheet(isPresented: $ticksPresented) {
            CustomGcodeSheet(
                ticks: ticks,
                slotCount: max(environment.presets.filamentSlots.count, 1),
                onSaveEdit: { tick, kind, extruder, color, extra in
                    Task {
                        await environment.document.editCustomGcode(
                            printZ: tick.printZ, kind: kind,
                            extruder: extruder, color: color, extra: extra)
                        await reloadTicks()
                    }
                },
                onDelete: { printZ in
                    Task {
                        await environment.document.deleteCustomGcode(printZ: printZ)
                    }
                }
            )
        }
        .sheet(item: $tickEditor) { target in
            CustomGcodeTickEditorSheet(
                mode: .add(height: target.height),
                slotCount: max(environment.presets.filamentSlots.count, 1),
                onSave: { kind, extruder, color, extra in
                    Task {
                        await addTick(
                            printZ: target.height, kind: kind, extruder: extruder,
                            color: color, extra: extra)
                    }
                }
            )
        }
        .sheet(isPresented: $templatesPresented) {
            CustomGcodeTemplatesSheet(store: templates)
        }
        .sheet(isPresented: $lineWindowPresented) {
            GcodeLineWindowSheet(store: store, url: store.loadedURL)
        }
        .sheet(item: $sharingOBJ) { share in
            ActivityShareSheet(items: [share.url])
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $summaryPresented) {
            PreviewSummarySheet(store: store)
        }
    }

    /// The print height the next tick lands at: the current upper layer's z.
    private var tickHeight: Double? {
        guard let layer = store.layer(at: store.upperLayer), layer.z > 0 else { return nil }
        return Double(layer.z)
    }

    /// Template insert (desktop "custom template"): a CUSTOM tick carrying
    /// the snippet's G-code, at the top visible layer's height.
    private func addTemplateTick(_ template: CustomGcodeTemplatesStore.Template) async {
        guard let height = tickHeight else {
            environment.status.report(
                .document, failure: .invariant(
                    operation: "add custom G-code",
                    diagnostic: "no layer height to attach the tick to"))
            return
        }
        await addTick(
            printZ: height, kind: .custom, extruder: 0, color: "",
            extra: template.gcode)
    }

    private func reloadTicks() async {
        if let items = await environment.document.customGcodes() {
            ticks = items
        }
    }

    private func addTick(
        printZ: Double,
        kind: EnginePlater.CustomGcodeKind,
        extruder: Int,
        color: String,
        extra: String
    ) async {
        await environment.document.addCustomGcode(
            printZ: printZ, kind: kind, extruder: extruder,
            color: color, extra: extra)
        await reloadTicks()
    }

    /// Desktop "G-code viewer" parity: preview any G-code file.
    private func openExternal(_ result: Result<URL, any Error>) {
        switch result {
        case .success(let url):
            Task {
                let copy: URL
                do {
                    copy = try EnginePaths.copyImportIntoSandbox(url, kind: "gcode")
                } catch {
                    environment.status.report(
                        .preview,
                        failure: AppFailure.wrap(error, operation: "open G-code")
                    )
                    return
                }
                await store.load(url: copy, identity: "external:\(UUID().uuidString)")
                frameRequest += 1
            }
        case .failure(let error):
            environment.status.report(
                .preview,
                failure: AppFailure.wrap(error, operation: "choose G-code file")
            )
        }
    }

    /// Board §wave-b/4: writes the visible toolpath to
    /// `Documents/Exports/<name>.obj` off the main actor, then presents
    /// the system share sheet for the result.
    private func exportToolpathOBJ() async {
        guard let toolpath = store.toolpath else {
            environment.status.report(
                .preview,
                failure: .invariant(
                    operation: "export OBJ",
                    diagnostic: "no toolpath is loaded"))
            return
        }
        let lower = store.lowerLayer
        let upper = store.upperLayer
        let hidden = store.hiddenRoles
        let baseName = (store.loadedURL?
            .deletingPathExtension()
            .lastPathComponent ?? "toolpath") + "-toolpath"
        let result = await BackgroundWork.run(operation: "export OBJ") {
            try ToolpathOBJ.write(
                toolpath: toolpath,
                lowerLayer: lower,
                upperLayer: upper,
                hiddenRoles: hidden,
                baseName: baseName)
        }
        switch result {
        case .success(let url):
            environment.status.report(
                .preview,
                "OBJ exported: \(url.lastPathComponent) " +
                    "(\(store.lowerLayer + 1)–\(store.upperLayer + 1) of \(store.layerCount) layers visible at export)")
            sharingOBJ = ShareURL(url: url)
        case .failure(let failure):
            environment.status.report(.preview, failure: failure)
        }
    }

    private var bed: EngineBed {
        environment.presets.printVolume.map(EngineBed.init) ?? EngineBed.fallback
    }

    private var viewer: some View {
        ZStack {
            GcodeCanvas(
                onStatus: { environment.status.report(.renderer, $0) },
                store: store,
                buildKey: ToolpathBuildKey(
                    loadedPath: store.loadedPath,
                    colorMode: store.colorMode,
                    hiddenRoles: store.hiddenRoles,
                    showTravel: store.showTravel,
                    showSeams: store.showSeams,
                    showRetractions: store.showRetractions,
                    showWipes: store.showWipes,
                    showToolChanges: store.showToolChanges,
                    bed: bed
                ),
                drawRange: ToolpathDrawRange(
                    lowerLayer: store.lowerLayer,
                    upperLayer: store.upperLayer,
                    topLayerProgress: store.topLayerProgress
                ),
                toolPosition: store.toolSegment?.end,
                frameRequest: frameRequest
            )
            .ignoresSafeArea()

            // One wide top pill bar (Plate-style chrome): Scheme | View |
            // Open | Share. The former left dock is gone.
            VStack(spacing: 8) {
                topBar
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                if showLegend {
                    legend
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                }
                Spacer()
            }

            // Right: desktop-style vertical layer range slider.
            HStack {
                Spacer()
                LayerRangeSlider(
                    lower: store.lowerLayer,
                    upper: store.upperLayer,
                    maximum: max(store.layerCount - 1, 0),
                    label: layerLabel,
                    onChange: { store.setLayerRange(lower: $0, upper: $1) }
                )
                .frame(width: 44)
                .frame(maxHeight: .infinity)
                .padding(.trailing, 12)
            }
            .padding(.top, 70)
            .padding(.bottom, 110)

            VStack {
                Spacer()
                bottomPanel
            }
        }
        // Hardware-keyboard parity for the preview sliders (desktop arrow
        // keys): hidden zero-size buttons — the same mechanism the Plate
        // tab uses on its visible controls. Shortcuts live only on the
        // ready viewer so the idle/failure screens never swallow keys.
        .background {
            keyboardShortcuts
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
    }

    /// Up/down step the layer range (Shift = ×5), left/right step the
    /// in-layer move scrubber, "1" toggles one-layer mode — all through
    /// the same store setters the on-screen sliders write.
    @ViewBuilder
    private var keyboardShortcuts: some View {
        Button("Layer up", action: { stepLayer(1) })
            .keyboardShortcut(.upArrow, modifiers: [])
        Button("Layer up ×5", action: { stepLayer(5) })
            .keyboardShortcut(.upArrow, modifiers: .shift)
        Button("Layer down", action: { stepLayer(-1) })
            .keyboardShortcut(.downArrow, modifiers: [])
        Button("Layer down ×5", action: { stepLayer(-5) })
            .keyboardShortcut(.downArrow, modifiers: .shift)
        Button("Move back", action: { scrubMoves(-1) })
            .keyboardShortcut(.leftArrow, modifiers: [])
        Button("Move back ×5", action: { scrubMoves(-5) })
            .keyboardShortcut(.leftArrow, modifiers: .shift)
        Button("Move forward", action: { scrubMoves(1) })
            .keyboardShortcut(.rightArrow, modifiers: [])
        Button("Move forward ×5", action: { scrubMoves(5) })
            .keyboardShortcut(.rightArrow, modifiers: .shift)
        Button("One layer mode", action: { store.oneLayerMode.toggle() })
            .keyboardShortcut("1", modifiers: [])
        Button("G-code window", action: { lineWindowPresented.toggle() })
            .keyboardShortcut("g", modifiers: [])
    }

    /// Translates the visible layer band (top handle first, span kept);
    /// in one-layer mode the store collapses it to single-layer walking.
    private func stepLayer(_ delta: Int) {
        let last = max(store.layerCount - 1, 0)
        let span = store.upperLayer - store.lowerLayer
        let target = min(max(store.upperLayer + delta, 0), last)
        store.setLayerRange(lower: max(0, target - span), upper: target)
    }

    private func scrubMoves(_ delta: Int) {
        store.setTopLayerProgress(store.topLayerProgress + delta)
    }

    private func layerLabel(_ index: Int) -> String {
        guard let layer = store.layer(at: index) else { return "\(index + 1)" }
        return String(format: "%d · %.2f", index + 1, layer.z)
    }

    /// Applies the typed layer jump (1-based input, clamped to the stack).
    private func jumpToLayer() {
        let trimmed = jumpLayerText.trimmingCharacters(in: .whitespaces)
        guard let layer = Int(trimmed) else { return }
        let last = max(store.layerCount - 1, 0)
        let target = min(max(layer - 1, 0), last)
        store.setLayerRange(lower: min(store.lowerLayer, target), upper: target)
        jumpLayerText = ""
    }

    // MARK: Bottom panel: move scrubber + scheme controls

    /// Preview chrome: ONE wide, horizontally SCROLLABLE pill with direct
    /// (de-nested) controls: Scheme menu | travel / seams / retractions /
    /// legend / frame toggles | Open | Share.
    private var topBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                Menu {
                    Picker("Color scheme", selection: $store.colorMode) {
                        ForEach(ToolpathColorMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                } label: {
                    ChromeToolLabel(symbol: "paintpalette", label: "Scheme")
                }
                if store.sections.count > 1 {
                    // Slice-all results: jump the layer range onto one
                    // plate's layers (the whole plate stack stays rendered).
                    Menu {
                        ForEach(Array(store.sections.enumerated()), id: \.offset) { _, section in
                            Button {
                                store.focus(section: section)
                            } label: {
                                let name = section.name.isEmpty
                                    ? "Plate \(section.plateIndex + 1)" : section.name
                                Text(name + " \u{00b7} ~" +
                                     "\(Int(section.estimatedSeconds / 60)) min")
                            }
                        }
                    } label: {
                        ChromeToolLabel(symbol: "square.stack.3d.up", label: "Plates")
                    }
                    .buttonStyle(.plain)
                }
                Divider().frame(height: 28)
                barToggle("arrow.triangle.swap", "Travel", store.showTravel) {
                    store.showTravel.toggle()
                }
                barToggle("smallcircle.filled.circle", "Seams", store.showSeams) {
                    store.showSeams.toggle()
                }
                barToggle("arrow.uturn.left.circle", "Retract", store.showRetractions) {
                    store.showRetractions.toggle()
                }
                barToggle("hand.draw", "Wipe", store.showWipes) {
                    store.showWipes.toggle()
                }
                barToggle("wrench.and.screwdriver", "Tool", store.showToolChanges) {
                    store.showToolChanges.toggle()
                }
                barToggle("1.circle", "1 layer", store.oneLayerMode) {
                    store.oneLayerMode.toggle()
                }
                barToggle("list.bullet.rectangle", "Legend", showLegend) {
                    showLegend.toggle()
                }
                Button {
                    frameRequest += 1
                } label: {
                    ChromeToolLabel(symbol: "viewfinder", label: "Frame")
                }
                .buttonStyle(.plain)
                // Board cycle-0.15: desktop Total Estimation panel.
                Button {
                    summaryPresented = true
                } label: {
                    ChromeToolLabel(symbol: "timer", label: "Summary")
                }
                .buttonStyle(.plain)
                // Desktop "Show G-code Window": the viewed layer's text.
                Button {
                    lineWindowPresented = true
                } label: {
                    ChromeToolLabel(symbol: "doc.plaintext", label: "G-code")
                }
                .buttonStyle(.plain)
                Divider().frame(height: 28)
                Button {
                    openPresented = true
                } label: {
                    ChromeToolLabel(symbol: "doc.badge.plus", label: "Open")
                }
                .buttonStyle(.plain)
                // Board §wave-b/4: export the VISIBLE toolpath as an OBJ
                // (one box per extrusion segment) and share it.
                Button {
                    Task { await exportToolpathOBJ() }
                } label: {
                    ChromeToolLabel(symbol: "cube", label: "OBJ")
                }
                .buttonStyle(.plain)
                .disabled(store.toolpath == nil)
                if let url = store.loadedURL {
                    ShareLink(item: url) {
                        ChromeToolLabel(symbol: "square.and.arrow.up", label: "Share")
                    }
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 6)
        }
        .frame(height: 58)
        .background(.ultraThinMaterial, in: Capsule())
        .clipShape(Capsule())
    }

    private func barToggle(
        _ symbol: String, _ label: String, _ active: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ChromeToolLabel(symbol: symbol, label: label)
                .foregroundStyle(active ? Color.accentColor : Color.primary)
                .background(
                    active ? Color.accentColor.opacity(0.18) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 10)
                )
        }
        .buttonStyle(.plain)
    }

    private var bottomPanel: some View {
        HStack(spacing: 10) {
            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                .foregroundStyle(.secondary)
            Slider(
                value: Binding(
                    get: { Double(store.topLayerProgress) },
                    set: { store.setTopLayerProgress(Int($0.rounded())) }
                ),
                in: 0...Double(max(store.topLayerSegmentCount, 1)),
                step: 1
            )
            // Bounded readouts: shrink to fit, never wrap or squeeze
            // neighbors (global text rule).
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(store.topLayerProgress)/\(store.topLayerSegmentCount) moves")
                Text("~\(Int(store.remainingSeconds / 60)) min after layer \(store.upperLayer + 1)")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(minWidth: 150, alignment: .trailing)
            // Desktop layer ticks: custom G-code at the top visible layer.
            // One editor for every kind (add and edit-in-place), plus the
            // reusable template snippets.
            Menu {
                Button {
                    if let height = tickHeight {
                        tickEditor = TickEditorTarget(height: height)
                    } else {
                        environment.status.report(
                            .document, failure: .invariant(
                                operation: "add custom G-code",
                                diagnostic: "no layer height to attach the tick to"))
                    }
                } label: {
                    Label("Add tick\u{2026}", systemImage: "plus.circle")
                }
                if !templates.templates.isEmpty {
                    Menu {
                        ForEach(templates.templates) { template in
                            Button(template.name) {
                                Task {
                                    await addTemplateTick(template)
                                }
                            }
                        }
                    } label: {
                        Label("From template\u{2026}", systemImage: "doc.text")
                    }
                }
                Button {
                    templatesPresented = true
                } label: {
                    Label("Manage templates\u{2026}", systemImage: "list.bullet.rectangle")
                }
            } label: {
                ChromeToolLabel(symbol: "plus.circle", label: "Tick")
            }
            .buttonStyle(.plain)
            .disabled(tickHeight == nil || environment.document.isBusy)
            if !ticks.isEmpty {
                Button {
                    ticksPresented = true
                } label: {
                    ChromeToolLabel(symbol: "clock.badge.exclamationmark", label: "\(ticks.count)")
                }
                .buttonStyle(.plain)
            }
            // Desktop "Jump to layer": type a layer number, land on it.
            HStack(spacing: 4) {
                TextField("Layer", text: $jumpLayerText)
                    .frame(width: 52)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.numberPad)
                    .onSubmit(jumpToLayer)
                Button("Go", action: jumpToLayer)
                    .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    // MARK: Legend

    @ViewBuilder
    private var legend: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(store.colorMode.rawValue)
                .font(.caption.weight(.semibold))
            switch store.colorMode {
            case .feature:
                ForEach(store.roles) { summary in
                    let hidden = store.hiddenRoles.contains(summary.role)
                    Button {
                        store.toggleRole(summary.role)
                    } label: {
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(swatch(ToolpathPalette.color(role: summary.role)))
                                .frame(width: 12, height: 12)
                                .opacity(hidden ? 0.25 : 1)
                            Text(ToolpathRole.name(summary.role))
                                .font(.caption2)
                                .foregroundStyle(hidden ? .tertiary : .primary)
                            Spacer(minLength: 6)
                            Text(roleTime(summary))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            case .speed:
                gradientLegend(store.feedrateRange, unit: store.colorMode.unit, digits: 0)
            case .layerHeight:
                gradientLegend(store.heightRange, unit: store.colorMode.unit, digits: 2)
            case .lineWidth:
                gradientLegend(store.widthRange, unit: store.colorMode.unit, digits: 2)
            case .fanSpeed:
                gradientLegend(store.fanRange, unit: store.colorMode.unit, digits: 0)
            case .temperature:
                gradientLegend(store.temperatureRange, unit: store.colorMode.unit, digits: 0)
            case .volumetricRate:
                gradientLegend(store.volumetricRange, unit: store.colorMode.unit, digits: 1)
            case .actualVolumetricRate:
                gradientLegend(store.actualVolumetricRange, unit: store.colorMode.unit, digits: 1)
            case .actualSpeed:
                gradientLegend(store.actualSpeedRange, unit: store.colorMode.unit, digits: 0)
            case .layerTime, .layerTimeLog:
                gradientLegend(store.layerTimeRange, unit: store.colorMode.unit, digits: 0)
            case .pressureAdvance:
                gradientLegend(store.pressureAdvanceRange, unit: store.colorMode.unit, digits: 3)
            case .acceleration:
                gradientLegend(store.accelerationRange, unit: store.colorMode.unit, digits: 0)
            case .jerk:
                gradientLegend(store.jerkRange, unit: store.colorMode.unit, digits: 1)
            case .tool:
                ForEach(store.extruderStats.indices, id: \.self) { index in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(swatch(ToolpathPalette.gradient(
                                Float(index) / max(Float(store.extruderStats.count - 1), 1)
                            )))
                            .frame(width: 12, height: 12)
                        Text("T\(index)")
                            .font(.caption2)
                        Spacer()
                    }
                }
            }
            estimationTotals
        }

        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 240, alignment: .leading)
    }

        /// Desktop Total Estimation: time (normal + silent), filament usage
        /// per extruder (length / weight) and cost.
        private var estimationTotals: some View {
            VStack(alignment: .leading, spacing: 3) {
                Divider()
                if let toolpath = store.toolpath {
                    Label(
                        formatDuration(toolpath.estimatedSeconds) +
                            (toolpath.estimatedStealthSeconds > 0
                             ? "  ·  silent \(formatDuration(toolpath.estimatedStealthSeconds))" : ""),
                        systemImage: "clock"
                    )
                    .font(.caption2.monospaced())
                    ForEach(Array(store.extruderStats.enumerated()), id: \.offset) { index, stats in
                        let length = String(format: "%.2f m", stats.lengthM)
                        let weight = stats.densityGCm3 > 0
                            ? String(format: " · %.1f g", stats.weightG) : ""
                        let cost = stats.costPerKG > 0 && stats.weightG > 0
                            ? String(format: " · %.2f €", stats.weightG / 1000 * Double(stats.costPerKG))
                            : ""
                        Text("T\(index): \(length)\(weight)\(cost)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    /// Desktop legend parity: per-feature time and share of extrusion time.
    private func roleTime(_ summary: GcodePreviewStore.RoleSummary) -> String {
        let minutes = Int((summary.timeSeconds / 60).rounded())
        let share = store.extrusionSeconds > 0
            ? summary.timeSeconds / store.extrusionSeconds * 100 : 0
        return String(format: "%dm %4.1f%%", minutes, share)
    }

    private func gradientLegend(_ range: ClosedRange<Float>, unit: String, digits: Int) -> some View {
        HStack(alignment: .center, spacing: 8) {
            LinearGradient(
                colors: (0...4).reversed().map { swatch(ToolpathPalette.gradient(Float($0) / 4)) },
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(width: 12, height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            VStack(alignment: .leading) {
                Text(String(format: "%.\(digits)f \(unit)", range.upperBound))
                Spacer()
                Text(String(format: "%.\(digits)f \(unit)", range.lowerBound))
            }
            .font(.caption2.monospaced())
            .frame(height: 90)
        }
    }

    private func swatch(_ color: SIMD4<Float>) -> Color {
        Color(red: Double(color.x), green: Double(color.y), blue: Double(color.z))
    }
}

private struct PreviewDock: View {
    @Binding var colorMode: ToolpathColorMode
    @Binding var showTravel: Bool
    @Binding var showSeams: Bool
    @Binding var showRetractions: Bool
    @Binding var showLegend: Bool
    let onFrame: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Menu {
                Picker("Color scheme", selection: $colorMode) {
                    ForEach(ToolpathColorMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
            } label: {
                dockLabel(symbol: "paintpalette", label: shortName(colorMode), active: true)
            }
            Button { showTravel.toggle() } label: {
                dockLabel(symbol: "arrow.triangle.swap", label: "Travel", active: showTravel)
            }
            .buttonStyle(.plain)
            Button { showSeams.toggle() } label: {
                dockLabel(symbol: "smallcircle.filled.circle", label: "Seams", active: showSeams)
            }
            .buttonStyle(.plain)
            Button { showRetractions.toggle() } label: {
                dockLabel(symbol: "arrow.uturn.left.circle", label: "Retract", active: showRetractions)
            }
            .buttonStyle(.plain)
            Button { showLegend.toggle() } label: {
                dockLabel(symbol: "list.bullet.rectangle", label: "Legend", active: showLegend)
            }
            .buttonStyle(.plain)
            Divider().frame(width: 32)
            Button(action: onFrame) {
                dockLabel(symbol: "viewfinder", label: "Frame", active: false)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private func shortName(_ mode: ToolpathColorMode) -> String {
        switch mode {
        case .feature: return "Type"
        case .speed: return "Speed"
        case .layerHeight: return "Height"
        case .lineWidth: return "Width"
        case .fanSpeed: return "Fan"
        case .temperature: return "Temp"
        case .volumetricRate: return "Flow"
        case .actualVolumetricRate: return "Act.Flow"
        case .actualSpeed: return "Actual"
        case .layerTime: return "Time"
        case .layerTimeLog: return "Log"
        case .pressureAdvance: return "PA"
        case .acceleration: return "Accel"
        case .jerk: return "Jerk"
        case .tool: return "Tool"
        }
    }

    private func dockLabel(symbol: String, label: String, active: Bool) -> some View {
        VStack(spacing: 2) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
            Text(label)
                .font(.system(size: 9))
        }
        .frame(width: 52, height: 44)
        .foregroundStyle(active ? Color.accentColor : Color.primary)
        .background(
            active ? Color.accentColor.opacity(0.18) : Color.clear,
            in: RoundedRectangle(cornerRadius: 10)
        )
        .contentShape(Rectangle())
    }
}

/// "1h 23m" / "23m 45s" — desktop estimation formatting (shared by the
/// legend and the summary sheet).
private func formatDuration(_ seconds: Float) -> String {
    let total = Int(seconds.rounded())
    let hours = total / 3600, minutes = (total % 3600) / 60
    return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m \(total % 60)s"
}

/// Desktop "Total Estimation" panel parity (board cycle-0.15): normal +
/// silent time, per-extruder filament length/weight/cost and per-plate
/// times. Read-only view over the already-parsed toolpath — no engine calls.
private struct PreviewSummarySheet: View {
    let store: GcodePreviewStore

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let toolpath = store.toolpath {
                    timeSection(toolpath)
                    filamentSection
                    if store.sections.count > 1 {
                        platesSection(toolpath)
                    }
                    if let url = store.loadedURL {
                        Section {
                            LabeledContent("File", value: url.lastPathComponent)
                                .font(.caption)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .navigationTitle("Summary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func timeSection(_ toolpath: GcodeToolpath) -> some View {
        Section("Time") {
            LabeledContent("Estimated", value: formatDuration(toolpath.estimatedSeconds))
            if toolpath.estimatedStealthSeconds > 0 {
                LabeledContent("Silent mode", value: formatDuration(toolpath.estimatedStealthSeconds))
            }
            LabeledContent("Extruding", value: formatDuration(store.extrusionSeconds))
            LabeledContent("Layers", value: "\(store.layerCount)")
        }
    }

    private var filamentSection: some View {
        Group {
            if !store.extruderStats.isEmpty {
                Section("Filament") {
                    ForEach(Array(store.extruderStats.enumerated()), id: \.offset) { index, stats in
                        extruderRow(index, stats)
                    }
                    totalsRow
                }
            }
        }
    }

    /// One extruder's usage: length, weight (when the density is known) and
    /// cost (weight × cost per kg) — the legend's math, laid out as rows.
    private func extruderRow(_ index: Int, _ stats: ExtruderStats) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("T\(index)")
                .font(.subheadline.weight(.medium))
                .monospaced()
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: "%.2f m", stats.lengthM))
                if stats.densityGCm3 > 0 {
                    Text(String(format: "%.1f g", stats.weightG))
                }
                if stats.costPerKG > 0 && stats.weightG > 0 {
                    Text(String(format: "%.2f €", stats.weightG / 1000 * Double(stats.costPerKG)))
                }
            }
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var totalsRow: some View {
        let length = store.extruderStats.map(\.lengthM).reduce(0, +)
        let weight = store.extruderStats.map(\.weightG).reduce(0, +)
        let cost = store.extruderStats.reduce(0) {
            $0 + ($1.weightG / 1000 * Double($1.costPerKG))
        }
        VStack(alignment: .trailing, spacing: 2) {
            Text(String(format: "%.2f m", length))
            if store.extruderStats.contains(where: { $0.densityGCm3 > 0 }) {
                Text(String(format: "%.1f g", weight))
            }
            if store.extruderStats.contains(where: { $0.costPerKG > 0 && $0.weightG > 0 }) {
                Text(String(format: "%.2f €", cost))
            }
        }
        .font(.callout.monospacedDigit().weight(.semibold))
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// Slice-all results: one time row per plate section.
    private func platesSection(_ toolpath: GcodeToolpath) -> some View {
        Section("Plates") {
            ForEach(store.sections, id: \.plateIndex) { section in
                LabeledContent(
                    section.name.isEmpty ? "Plate \(section.plateIndex + 1)" : section.name,
                    value: formatDuration(section.estimatedSeconds)
                )
            }
            LabeledContent("Total", value: formatDuration(toolpath.estimatedSeconds))
        }
    }
}

/// Desktop layer-tick list (custom G-code editor): one row per tick, tap
/// to EDIT in place (the same editor sheet "Add tick\u{2026}" uses, nested
/// over the list), swipe to delete (one undo step each).
private struct CustomGcodeSheet: View {
    let ticks: [EnginePlater.CustomGcodeItem]
    let slotCount: Int
    /// Applies an edit (kind, extruder, color, extra) to `tick`.
    let onSaveEdit: (
        _ tick: EnginePlater.CustomGcodeItem,
        _ kind: EnginePlater.CustomGcodeKind,
        _ extruder: Int,
        _ color: String,
        _ extra: String
    ) -> Void
    let onDelete: (Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var editing: EnginePlater.CustomGcodeItem?

    var body: some View {
        NavigationStack {
            List {
                ForEach(ticks) { tick in
                    Button {
                        editing = tick
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Label(tick.kind.label, systemImage: symbol(tick.kind))
                                Spacer()
                                Text(String(format: "%.2f mm", tick.printZ))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            if !detail(tick).isEmpty {
                                Text(detail(tick))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button(role: .destructive) {
                            onDelete(tick.printZ)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle("Custom G-code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $editing) { tick in
                CustomGcodeTickEditorSheet(
                    mode: .edit(tick),
                    slotCount: slotCount,
                    onSave: { kind, extruder, color, extra in
                        onSaveEdit(tick, kind, extruder, color, extra)
                    }
                )
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func symbol(_ kind: EnginePlater.CustomGcodeKind) -> String {
        switch kind {
        case .colorChange: return "paintbrush"
        case .pausePrint: return "pause.circle"
        case .toolChange: return "wrench.and.screwdriver"
        case .template: return "doc.text"
        case .custom: return "chevron.left.forwardslash.chevron.right"
        }
    }

    private func detail(_ tick: EnginePlater.CustomGcodeItem) -> String {
        switch tick.kind {
        case .colorChange: return tick.extruder > 0 ? "Extruder \(tick.extruder) \(tick.color)" : tick.color
        case .pausePrint: return tick.extra.isEmpty ? "Pauses the print" : tick.extra
        case .toolChange: return "Extruder \(tick.extruder)"
        case .template: return "Template tick (read-only)"
        case .custom: return tick.extra
        }
    }
}

/// G-code file types for preview import and the Device send sheet.
enum GcodeTypes {
    /// Desktop G-code viewer extensions (`.gcode`, `.g`, `.gco`, `.ngc`).
    static let all: [UTType] = ["gcode", "g", "gco", "ngc"].map { ext in
        guard let type = UTType(filenameExtension: ext, conformingTo: .data) else {
            preconditionFailure("iOS did not provide a content type for .\(ext)")
        }
        return type
    }
}
