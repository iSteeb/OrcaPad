// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

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
                Divider().frame(height: 28)
                Button {
                    openPresented = true
                } label: {
                    ChromeToolLabel(symbol: "doc.badge.plus", label: "Open")
                }
                .buttonStyle(.plain)
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

        private func formatDuration(_ seconds: Float) -> String {
            let total = Int(seconds.rounded())
            let hours = total / 3600, minutes = (total % 3600) / 60
            return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m \(total % 60)s"
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
