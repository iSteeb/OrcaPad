import SwiftUI

/// App root: the four-tab glass shell (Plate / Prepare / Preview / Device)
/// with a global status overlay. Tab content is presentation-only; all
/// orchestration lives in the process-lifetime AppEnvironment stores.
struct RootView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        TabView {
            PlateTabView()
                .tabItem { Label("Plate", systemImage: "square.3.layers.3d") }
            PrepareTabView()
                .tabItem { Label("Prepare", systemImage: "slider.horizontal.3") }
            PreviewTabView()
                .tabItem { Label("Preview", systemImage: "eye") }
            DeviceTabView()
                .tabItem { Label("Device", systemImage: "printer") }
        }
        .overlay(alignment: .topLeading) { statusOverlay }
        .preferredColorScheme(.dark)
    }

    private var statusOverlay: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("OrcaPad")
                .font(.caption.weight(.semibold))
            ForEach(environment.status.visibleEntries) { entry in
                Text(entry.text)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(entry.subsystem == .slice ? 3 : 2)
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(12)
        .allowsHitTesting(false)
    }
}
