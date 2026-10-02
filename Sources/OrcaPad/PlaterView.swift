import SwiftUI
import Engine

/// Root scene: the plater. 3D canvas full-bleed, lightweight overlays on top.
/// This is the Phase 0 scaffold — shell exists, engine not linked yet.
struct PlaterView: View {
    @State private var rendererStatus = "Metal: starting…"
    @State private var engineStatus = "C++: not probed"

    var body: some View {
        ZStack(alignment: .topLeading) {
            MetalCanvas(onStatus: { rendererStatus = $0 })
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 3) {
                Text("OrcaPad")
                    .font(.caption.weight(.semibold))
                Text("Phase 0 · scaffold")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(rendererStatus)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                Text(engineStatus)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding(12)
        }
        .overlay(alignment: .bottom) { platerToolbar }
        .preferredColorScheme(.dark)
        .onAppear { engineStatus = EngineProbe.status() }
    }

    private var platerToolbar: some View {
        HStack(spacing: 22) {
            ToolbarButton(symbol: "plus", label: "Import") {
                // Phase 2: document picker → STL/3MF load
            }
            ToolbarButton(symbol: "arrow.2.circlepath", label: "Arrange") {
                // Phase 2: libslic3r arrange
            }
            ToolbarButton(symbol: "scissors", label: "Slice", disabled: true) {
                // Phase 3: background slice job
            }
            ToolbarButton(symbol: "gearshape", label: "Settings") {
                // Phase 3: generated settings UI
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.bottom, 14)
    }
}

private struct ToolbarButton: View {
    let symbol: String
    let label: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .medium))
                Text(label)
                    .font(.caption2)
            }
            .frame(minWidth: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(disabled ? .secondary : .primary)
        .environment(\.isEnabled, !disabled)
    }
}
