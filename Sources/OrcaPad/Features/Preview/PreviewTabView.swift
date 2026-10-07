import SwiftUI

/// Preview tab: feature-colored gcode toolpath with a layer scrubber and
/// per-layer progress. Loads the latest slice result through the engine's
/// own GCodeProcessor (desktop viewer parity, Metal instead of GL).
struct PreviewTabView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var store = GcodePreviewStore()
    @State private var layerDraft: Double = 0

    var body: some View {
        Group {
            switch store.phase {
            case .idle:
                ContentUnavailableView(
                    "Nothing to preview",
                    systemImage: "eye",
                    description: Text(
                        "Slice a plate first — the toolpath viewer will " +
                            "render here with layer controls."
                    )
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
                layerDraft = Double(store.layerCount)
            }
        }
    }

    private var sliceIdentity: String {
        environment.slicing.lastOutcome.map(\.outputURL.path) ?? ""
    }

    private var viewer: some View {
        let bed = environment.presets.printVolume.map(EngineBed.init)
            ?? EngineBed.fallback
        return VStack(spacing: 0) {
            GcodeCanvas(
                onStatus: { environment.status.report(.renderer, $0) },
                segments: store.toolpath?.segments ?? [],
                loadedPath: store.phase == .ready
                    ? environment.slicing.lastOutcome?.outputURL.path
                    : nil,
                visibleSegmentCount: store.visibleSegmentCount,
                bed: bed,
                boundsMin: store.boundsMin,
                boundsMax: store.boundsMax
            )
            controls
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Layer \(Int(layerDraft))/\(store.layerCount)")
                    .font(.caption.monospaced())
                Spacer()
                if let layer = store.currentLayer {
                    Text(String(format: "z %.2f mm", layer.z))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("~\(Int(store.remainingSeconds / 60)) min left")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: $layerDraft,
                in: 0...Double(max(store.layerCount, 1)),
                onEditingChanged: { editing in
                    if !editing {
                        store.setVisibleLayers(Int(layerDraft))
                    }
                }
            )
            Text("\(store.visibleSegmentCount) segments · total ~\(Int((store.toolpath?.estimatedSeconds ?? 0) / 60)) min")
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }
}
