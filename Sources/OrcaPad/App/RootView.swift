import SwiftUI

enum AppTab: Hashable {
    case plate
    case prepare
    case preview
    case device
}

/// App root: the four-tab glass shell (Plate / Prepare / Preview / Device)
/// with a debug status overlay that is hidden by default and toggled by
/// pressing the Device tab button five times in quick succession. Tab
/// content is presentation-only; orchestration lives in AppEnvironment.
struct RootView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var selectedTab: AppTab = .plate
    @State private var showDebugOverlay = false
    @State private var devicePresses: [Date] = []

    /// Presses of the Device tab button needed to toggle the debug overlay,
    /// and the window they must fall within.
    private static let debugTogglePresses = 5
    private static let debugToggleWindow: TimeInterval = 3

    var body: some View {
        TabView(selection: tabSelection) {
            PlateTabView()
                .tabItem { Label("Plate", systemImage: "square.3.layers.3d") }
                .tag(AppTab.plate)
            PrepareTabView()
                .tabItem { Label("Prepare", systemImage: "slider.horizontal.3") }
                .tag(AppTab.prepare)
            PreviewTabView()
                .tabItem { Label("Preview", systemImage: "eye") }
                .tag(AppTab.preview)
            DeviceTabView()
                .tabItem { Label("Device", systemImage: "printer") }
                .tag(AppTab.device)
        }
        .overlay(alignment: .topLeading) {
            if showDebugOverlay { statusOverlay }
        }
        .preferredColorScheme(.dark)
    }

    /// SwiftUI calls the setter on every tab-button press, including
    /// re-presses of the already selected tab — that is what lets repeated
    /// Device presses be counted.
    private var tabSelection: Binding<AppTab> {
        Binding(
            get: { selectedTab },
            set: { newTab in
                if newTab == .device { registerDevicePress() }
                selectedTab = newTab
            }
        )
    }

    private func registerDevicePress() {
        let now = Date()
        devicePresses = devicePresses.filter {
            now.timeIntervalSince($0) <= Self.debugToggleWindow
        } + [now]
        if devicePresses.count >= Self.debugTogglePresses {
            devicePresses.removeAll()
            showDebugOverlay.toggle()
        }
    }

    private var statusOverlay: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("OrcaPad · debug")
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
