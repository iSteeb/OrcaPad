// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

import Foundation
import Observation
import OrcaBridge

struct ResolvedConfigRow: Identifiable, Sendable {
    let key: String
    let label: String
    let category: String
    let value: String
    let isDefault: Bool
    let tooltip: String?

    var id: String { key }
}

/// Loads and merges the engine's resolved configuration (`full_config()`
/// exactly as slicing consumes it) with the pinned-engine option schema so
/// the client can present labeled, categorized, default-aware values.
@MainActor
@Observable
final class ResolvedConfigService {
    enum Phase: Sendable {
        case idle
        case loading
        case ready
        case failed(AppFailure)
    }

    private(set) var phase: Phase = .idle
    private(set) var rows: [ResolvedConfigRow] = []
    private(set) var categories: [String] = []

    func load(presets: PresetStore) async {
        guard case .idle = phase else { return }
        // The resolved-config read enters the engine: during a slice it
        // would park on the engine mutex for the whole slice — reject with
        // an explanation instead (same policy as preset operations).
        guard !presets.isEngineBusy else {
            phase = .failed(.invariant(
                operation: "load resolved config",
                diagnostic: "locked while slicing \u{2014} available again when the slice finishes"
            ))
            return
        }
        phase = .loading
        // Capture the engine handle on the main actor; the detached closure
        // must not touch isolated store state.
        guard let engine = presets.engineForSlicing else {
            phase = .failed(.invariant(
                operation: "load resolved config",
                diagnostic: "presets are not loaded"
            ))
            return
        }
        let result = await BackgroundWork.run(operation: "load resolved config") {
            try engine.resolvedConfig().get()
        }
        switch result {
        case .success(let json):
            guard let data = json.data(using: .utf8) else {
                phase = .failed(.invariant(
                    operation: "decode resolved config",
                    diagnostic: "resolved config is not valid UTF-8"
                ))
                return
            }
            let values: [String: String]
            do {
                values = try JSONDecoder().decode([String: String].self, from: data)
            } catch {
                phase = .failed(.invariant(
                    operation: "decode resolved config",
                    diagnostic: "resolved config is not a JSON object of " +
                        "strings: \(String(reflecting: error))"
                ))
                return
            }
            switch ConfigSchema.shared {
            case .success(let schema):
                install(values: values, schema: schema)
            case .failure(let failure):
                phase = .failed(failure)
            }
        case .failure(let failure):
            phase = .failed(failure)
        }
    }

    private func install(values: [String: String], schema: [ConfigOptionSchema]) {

        var built: [ResolvedConfigRow] = []
        built.reserveCapacity(values.count)
        var seen = Set<String>()

        func row(
            key: String,
            label: String?,
            category: String?,
            tooltip: String?,
            defaultValue: String?
        ) {
            guard let value = values[key] else { return }
            seen.insert(key)
            built.append(ResolvedConfigRow(
                key: key,
                label: label?.isEmpty == false ? label! : key,
                category: category?.isEmpty == false ? category! : "Other",
                value: value,
                isDefault: defaultValue == nil || defaultValue == value,
                tooltip: tooltip?.isEmpty == false ? tooltip : nil
            ))
        }

        for option in schema {
            row(
                key: option.key,
                label: option.label,
                category: option.category,
                tooltip: option.tooltip,
                defaultValue: option.defaultValue
            )
        }
        // Machine/filament metadata keys that exist in the resolved config
        // but not in print_config_def — still visible, grouped apart.
        for key in values.keys.sorted() where !seen.contains(key) {
            row(key: key, label: nil, category: "Machine metadata",
                tooltip: nil, defaultValue: nil)
        }

        rows = built
        categories = Array(Set(built.map(\.category))).sorted()
        phase = .ready
    }
}
