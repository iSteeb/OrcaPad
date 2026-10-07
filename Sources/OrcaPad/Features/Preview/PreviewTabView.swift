import SwiftUI

/// Preview tab: gcode visualization (feature-colored toolpath, layer
/// scrubbing — desktop parity). Rendered in Gate C3; until then it reports
/// the latest slice result and where the file lives.
struct PreviewTabView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        Group {
            if let outcome = environment.slicing.lastOutcome {
                ContentUnavailableView {
                    Label("G-code ready", systemImage: "checkmark.seal")
                } description: {
                    Text(
                        "\(outcome.outputURL.lastPathComponent)\n" +
                            "\(outcome.result.gcodeBytes / 1024) KB · ~" +
                            "\(Int(outcome.result.timeEstimateSeconds / 60)) min print"
                    )
                } actions: {
                    Text("Toolpath rendering lands in the next gate.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                ContentUnavailableView(
                    "Nothing to preview",
                    systemImage: "eye",
                    description: Text(
                        "Slice a plate first — the toolpath viewer will " +
                            "render here with layer controls."
                    )
                )
            }
        }
    }
}
