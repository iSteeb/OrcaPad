import SwiftUI

/// Preview tab (desktop parity): toolpath with a vertical layer range slider,
/// a horizontal in-layer move scrubber with tool marker, color schemes
/// (line type / speed / layer height / line width), feature visibility
/// legend, and travel toggle. Data comes from the engine's GCodeProcessor.
struct PreviewTabView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var store = GcodePreviewStore()
    @State private var showLegend = true
    @State private var frameRequest = 0

    var body: some View {
        Group {
            switch store.phase {
            case .idle:
                ContentUnavailableView(
                    "Nothing to preview",
                    systemImage: "eye",
                    description: Text("Slice a plate in Prepare — the toolpath renders here with layer controls.")
                )
            case .loading:
                ProgressView("parsing gcode…")
            case .failed(let failure):
                ContentUnavailableView(
                    "Preview unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(failure.localizedDescription)
                )
            case .ready:
                viewer
            }
        }
        .task(id: sliceIdentity) {
            if let outcome = environment.slicing.lastOutcome {
                await store.load(url: outcome.outputURL)
                frameRequest += 1
            }
        }
    }

    private var sliceIdentity: String {
        environment.slicing.lastOutcome.map(\.outputURL.path) ?? ""
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

            HStack(alignment: .top) {
                Spacer()
                VStack(alignment: .trailing, spacing: 12) {
                    if showLegend { legend }
                    LayerRangeSlider(
                        lower: store.lowerLayer,
                        upper: store.upperLayer,
                        maximum: max(store.layerCount - 1, 0),
                        label: layerLabel,
                        onChange: { store.setLayerRange(lower: $0, upper: $1) }
                    )
                    .frame(width: 44)
                    .frame(maxHeight: .infinity)
                }
                .padding(.trailing, 12)
                .padding(.top, 70)
            }
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

    // MARK: Bottom panel: move scrubber + scheme controls

    private var bottomPanel: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Menu {
                    Picker("Color scheme", selection: $store.colorMode) {
                        ForEach(ToolpathColorMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                } label: {
                    Label(store.colorMode.rawValue, systemImage: "paintpalette")
                }
                Toggle(isOn: $store.showTravel) {
                    Label("Travel", systemImage: "arrow.triangle.swap")
                }
                .toggleStyle(.button)
                Button {
                    showLegend.toggle()
                } label: {
                    Label("Legend", systemImage: showLegend ? "list.bullet.rectangle.fill" : "list.bullet.rectangle")
                }
                Button {
                    frameRequest += 1
                } label: {
                    Label("Frame", systemImage: "viewfinder")
                }
                Spacer()
                Text("~\(Int(store.remainingSeconds / 60)) min after layer \(store.upperLayer + 1)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            .labelStyle(.titleAndIcon)
            .font(.caption)

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
                Text("\(store.topLayerProgress)/\(store.topLayerSegmentCount)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 70, alignment: .trailing)
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
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 240, alignment: .leading)
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
