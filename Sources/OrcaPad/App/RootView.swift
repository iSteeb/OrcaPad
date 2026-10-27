// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

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
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: AppTab = .plate
    @State private var showDebugOverlay = false
    @State private var devicePresses: [Date] = []
    /// Tip of the Day (app.tips): shown ONCE per launch when enabled.
    @AppStorage(TipCatalog.Storage.enabledKey) private var tipsEnabled = true
    @State private var tipsPresented = false
    @State private var didPresentTipsThisLaunch = false
    /// Preferences ▸ Files ▸ autosave interval (minutes,
    /// 0 = off) — drives the interval timer task below.
    @AppStorage("autosave.intervalMinutes") private var autosaveInterval = 5

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
        .overlay(alignment: .top) {
            if let alert = environment.status.alert {
                FailureBanner(alert: alert) {
                    environment.status.dismissAlert(alert.id)
                }
                .padding(.top, 6)
                .padding(.horizontal, 16)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: environment.status.alert)
        .preferredColorScheme(.dark)
        .onChange(of: environment.presets.printVolume) { _, volume in
            // Machine selection changed the bed: re-derive the plate grid.
            guard let volume else { return }
            Task { await environment.document.syncBed(volume) }
        }
        .onChange(of: environment.slicing.lastOutcome?.jobID) { _, jobID in
            // Desktop swaps the canvas to the preview when a slice finishes;
            // OrcaPad selects the Preview tab (the outcome identity — not
            // the path — drives the reload, so this also covers re-slices).
            if jobID != nil { selectedTab = .preview }
        }
        .onChange(of: scenePhase) { _, phase in
            // Session autosave: best-effort 3MF snapshot before suspension
            // (desktop auto-backup subset; restore happens on next launch).
            if phase == .background {
                Task { await environment.autosaveSession() }
            }
        }
        // Interval autosave (files.auto-backup): a repeating timer while
        // the app is ACTIVE. The task id re-keys on the interval AND the
        // active flag, so changing the preference or leaving the foreground
        // cancels/pauses it (background = no timer); AppEnvironment decides
        // dirty (revision since last autosave) and idle at each tick.
        .task(id: autosaveTickKey) {
            guard scenePhase == .active, autosaveInterval > 0 else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(60 * autosaveInterval))
                } catch {
                    break  // cancelled: interval or active state changed
                }
                guard !Task.isCancelled else { break }
                await environment.autosaveIfDirty()
            }
        }
        .onOpenURL { url in
            handleOpenURL(url)
        }
        // Tip of the Day: one sheet per launch, only while enabled (the
        // toggle lives in the sheet itself and in the About screen).
        .onAppear {
            if tipsEnabled, !didPresentTipsThisLaunch {
                didPresentTipsThisLaunch = true
                tipsPresented = true
            }
        }
        .sheet(isPresented: $tipsPresented) {
            TipsSheet()
        }
        .confirmationDialog(
            "Open project?",
            isPresented: Binding(
                get: { openInProjectURL != nil },
                set: { if !$0 { openInProjectURL = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Replace current plate", role: .destructive) {
                if let url = openInProjectURL {
                    Task { await openProject(url) }
                }
                openInProjectURL = nil
            }
        } message: {
            Text("Opening a project replaces the objects on the plate and loads the project's printer, filament and process settings. Unsaved changes are lost.")
        }
    }

    /// The interval timer's identity: active state + interval minutes.
    private var autosaveTickKey: String {
        "\(scenePhase == .active)-\(autosaveInterval)"
    }

    // MARK: Open-in from Files / Mail (document types)

    @State private var openInProjectURL: URL?

    /// Models import into the document; 3MF opens as a project (with the
    /// same replace-confirmation the File menu uses).
    private func handleOpenURL(_ url: URL) {
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        guard url.pathExtension.lowercased() == "3mf" else {
            Task {
                selectedTab = .plate
                if !environment.document.isReady {
                    await environment.bootstrap()
                }
                guard environment.document.isReady else { return }
                let center = environment.document.currentPlateCenter
                    ?? environment.presets.printVolume.map {
                        SIMD2($0.centerX, $0.centerY)
                    }
                    ?? .zero
                await environment.document.importModel(from: url, bedCenter: center)
            }
            return
        }
        if environment.document.scene?.objects.isEmpty == false {
            openInProjectURL = url
        } else {
            Task { await openProject(url) }
        }
    }

    private func openProject(_ url: URL) async {
        selectedTab = .plate
        await environment.openProject(url)
        if let volume = environment.presets.printVolume {
            await environment.document.syncBed(volume)
        }
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

    /// Failure banner: every typed failure reaches the user, not only the
    /// hidden debug overlay and os_log.
    private struct FailureBanner: View {
        let alert: StatusAlert
        let dismiss: () -> Void

        var body: some View {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                VStack(alignment: .leading, spacing: 2) {
                    Text(alert.subsystem.rawValue.capitalized)
                        .font(.caption.weight(.semibold))
                    Text(alert.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 4)
                Button(action: dismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .padding(12)
            .frame(maxWidth: 560)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.red.opacity(0.45)))
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
