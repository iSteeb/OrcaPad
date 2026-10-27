// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

import SwiftUI

/// App preferences (0.18 client flagship, desktop Preferences subset):
/// every scattered setting plus the new Files options in one screen.
/// Honesty rule: each row binds the SAME @AppStorage/UserDefaults key the
/// feature it controls reads — nothing here is decorative, and no row
/// ships without a consumer. Opened from the Prepare pill's gear and from
/// the About screen.
struct PreferencesScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    // General
    @AppStorage("units.inches") private var measureInches = false
    @AppStorage(TipCatalog.Storage.enabledKey) private var tipsEnabled = true
    @AppStorage("slice.auto") private var autoSlice = false
    // Files
    @AppStorage("recent.files.max") private var recentFilesMax = 10
    @AppStorage("autosave.intervalMinutes") private var autosaveInterval = 5
    // Presets
    @AppStorage("presets.filterCompatible") private var filterCompatible = true
    @AppStorage("prepare.mode.machine") private var machineMode =
        SettingsModeFilter.simple.rawValue
    @AppStorage("prepare.mode.filament") private var filamentMode =
        SettingsModeFilter.simple.rawValue
    @AppStorage("prepare.mode.process") private var processMode =
        SettingsModeFilter.simple.rawValue

    var body: some View {
        NavigationStack {
            List {
                generalSection
                filesSection
                presetsSection
                profileUpdatesSection
                cloudAccountsSection
                aboutSection
            }
            .navigationTitle("Preferences")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: General

    private var generalSection: some View {
        Section {
            Picker("Units", selection: $measureInches) {
                Text("Millimetres").tag(false)
                Text("Inches").tag(true)
            }
            .pickerStyle(.segmented)
            Toggle("Show tips at launch", isOn: $tipsEnabled)
            Toggle("Auto-slice after changes", isOn: $autoSlice)
        } header: {
            Text("General")
        } footer: {
            Text("Units apply to measurements and the size readout. Auto-slice re-slices automatically after plate changes while the Prepare tab is open (once a first slice exists).")
        }
    }

    // MARK: Files

    private var filesSection: some View {
        Section {
            Stepper(
                value: $recentFilesMax,
                in: 1...50
            ) {
                LabeledContent("Recent files") {
                    Text("\(recentFilesMax)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Stepper(
                value: $autosaveInterval,
                in: 0...30
            ) {
                LabeledContent("Autosave interval") {
                    Text(autosaveInterval == 0
                         ? "Off"
                         : "\(autosaveInterval) min")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        } header: {
            Text("Files")
        } footer: {
            Text("Recent files bounds the File \u{25b8} Recent list (new entries only). The autosave interval saves the session while there are unsaved changes; 0 turns the timer off — the session is still saved when the app moves to the background.")
        }
    }

    // MARK: Presets

    private var presetsSection: some View {
        Section {
            Toggle("Show incompatible presets", isOn: $filterCompatible)
            modeRow("Printer settings level", $machineMode)
            modeRow("Filament settings level", $filamentMode)
            modeRow("Process settings level", $processMode)
        } header: {
            Text("Presets")
        } footer: {
            Text("The compatibility filter hides presets that do not match the selected machine (desktop Preferences parity). Settings levels pick the initial complexity of each preset kind's pages — the Prepare pill can still cycle them.")
        }
    }

    /// Segmented Simple/Advanced/Expert bound to one per-kind mode key
    /// (the exact keys PrepareTabView reads — changes apply immediately).
    private func modeRow(_ title: String, _ storage: Binding<String>) -> some View {
        Picker(title, selection: storage) {
            ForEach(SettingsModeFilter.allCases) { mode in
                Text(mode.rawValue).tag(mode.rawValue)
            }
        }
        .pickerStyle(.segmented)
    }

    // MARK: Profile updates (0.19 flagship, desktop PresetUpdater)

    @AppStorage("profiles.autoUpdate") private var profileAutoCheck = false

    private var profileUpdates: ProfileUpdates { environment.profileUpdates }

    private var profileUpdatesSection: some View {
        Section {
            Button {
                Task {
                    let vendors = await profileUpdates.installedVendors(
                        from: environment.presets)
                    guard !vendors.isEmpty else {
                        environment.status.report(
                            .presets, "no installed system vendors to check")
                        return
                    }
                    await profileUpdates.check(vendors: vendors)
                }
            } label: {
                LabeledContent {
                    if profileUpdates.isChecking {
                        ProgressView()
                    } else {
                        Text(checkedAgo)
                            .foregroundStyle(.secondary)
                    }
                } label: {
                    Label("Check for profile updates", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .disabled(profileUpdates.isChecking || environment.presets.isEngineBusy)
            Toggle("Check at launch", isOn: $profileAutoCheck)
            ForEach(profileUpdates.available) { update in
                profileUpdateRow(update)
            }
            ForEach(
                Array(profileUpdates.lastCheckFailures.enumerated()),
                id: \.offset
            ) { _, failure in
                Label("\(failure.vendor): \(failure.message)", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Profile updates")
        } footer: {
            Text(profileUpdatesFooter)
        }
    }

    @ViewBuilder
    private func profileUpdateRow(_ update: ProfileUpdates.VendorUpdate) -> some View {
        let installing = profileUpdates.isInstalling
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(update.displayName)
                Text("update \(update.installedVersion ?? "—") → \(update.version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await profileUpdates.install(update, presets: environment.presets) }
            } label: {
                if installing {
                    ProgressView()
                } else {
                    Text("Install")
                        .font(.caption.weight(.semibold))
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(installing || environment.presets.isEngineBusy)
        }
    }

    private var profileUpdatesFooter: String {
        var lines = [
            "Checks check-version.orcaslicer.com for every installed vendor (desktop PresetUpdater). "
                + "Installing loads the vendor bundle into the session like “Import config bundle…” — "
                + "save presets to keep them.",
        ]
        if profileAutoCheck {
            lines.append("Check at launch reports found updates; it never installs them for you.")
        }
        return lines.joined(separator: " ")
    }

    /// "2 h ago" / "never" — short, bounded relative text for the row.
    private var checkedAgo: String {
        guard let date = profileUpdates.lastCheckDate else { return "never" }
        let interval = Date().timeIntervalSince(date)
        if interval < 90 { return "just now" }
        if interval < 5_400 { return "\(Int(interval / 60)) min ago" }
        if interval < 172_800 { return "\(Int(interval / 3600)) h ago" }
        return "\(Int(interval / 86_400)) d ago"
    }

    // MARK: Cloud print hosts (0.19 device host completion)

    private var cloudAccountsSection: some View {
        Section {
            cloudAccountRow(
                title: "SimplyPrint",
                symbol: "cloud.fill",
                linked: environment.printers.printers.contains {
                    $0.hostType == "simplyprint" && !$0.apiKey.isEmpty
                },
                detail: simplyPrintDetail
            ) {
                Task { await environment.linkSimplyPrintAccount() }
            }
            cloudAccountRow(
                title: "3DPrinterOS",
                symbol: "network",
                linked: environment.printers.printers.contains {
                    $0.hostType == "3dprinteros" && !$0.apiKey.isEmpty
                },
                detail: "Opens the 3DPrinterOS login in Safari; the session token is stored on its printer record."
            ) {
                Task { await environment.link3DPrinterOSAccount() }
            }
        } header: {
            Text("Cloud print hosts")
        } footer: {
            Text("Browser sign-in replaces pasting an API key by hand (desktop OAuthDialog parity). Linking needs the preset engine ready; the token is stored on the printer record like a pasted key.")
        }
    }

    private var simplyPrintDetail: String {
        let linked = environment.printers.printers.contains {
            $0.hostType == "simplyprint" && !$0.apiKey.isEmpty
        }
        return linked
            ? "Linked — uploads use the stored access token."
            : "OAuth sign-in to simplyprint.io; the access token is stored on the SimplyPrint printer record."
    }

    private func cloudAccountRow(
        title: String,
        symbol: String,
        linked: Bool,
        detail: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                } icon: {
                    Image(systemName: symbol)
                        .foregroundStyle(linked ? Color.green : Color.accentColor)
                }
                Spacer()
                Text(linked ? "Relink…" : "Link…")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .disabled(environment.presets.isEngineBusy)
    }

    // MARK: About

    private var aboutSection: some View {
        Section {
            LabeledContent("Version") {
                Text(versionLine)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("About")
        } footer: {
            Text("Full attribution and licenses: Plate \u{25b8} Menu \u{25b8} About OrcaPad.")
        }
    }

    private var versionLine: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(version) (build \(build))"
    }
}
