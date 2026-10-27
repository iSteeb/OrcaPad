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
