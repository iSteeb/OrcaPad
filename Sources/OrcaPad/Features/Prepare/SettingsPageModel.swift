// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

import Foundation
import OrcaBridge

/// Desktop-shaped settings for one preset kind: pages → optgroups → rows,
/// built from the extracted desktop layout, the schema, and the engine's
/// edited/system config dumps. Pure value construction (no engine calls).
struct SettingsPageModel: Identifiable, Sendable {
    struct Group: Identifiable, Sendable {
        let title: String
        let rows: [SettingsEditorRow]
        var id: String { title }
        var modifiedCount: Int { rows.filter(\.isModified).count }
    }

    let title: String
    let groups: [Group]
    var id: String { title }
    var modifiedCount: Int { groups.reduce(0) { $0 + $1.modifiedCount } }
    var rowCount: Int { groups.reduce(0) { $0 + $1.rows.count } }

    /// Engine metadata keys that never appear as editable settings.
    private static let metadataKeys: Set<String> = [
        "inherits", "print_settings_id", "filament_settings_id",
        "printer_settings_id", "version", "from", "setting_id",
        "compatible_printers_condition_cummulative",
    ]

    static func build(
        kind: PresetKind,
        edited: [String: String],
        modified: Set<String>,
        filter: SettingsModeFilter,
        search: String
    ) -> Result<[SettingsPageModel], AppFailure> {
        let index: [String: ConfigOptionSchema]
        let layout: SettingsLayout
        switch (ConfigSchema.index, ConfigSchema.layout) {
        case (.success(let schemaIndex), .success(let settingsLayout)):
            index = schemaIndex
            layout = settingsLayout
        case (.failure(let failure), _), (_, .failure(let failure)):
            return .failure(failure)
        }

        func row(_ key: String) -> SettingsEditorRow? {
            // Engine-derived membership: only options this kind defines.
            guard let value = edited[key], let option = index[key] else {
                return nil
            }
            let mode = option.mode ?? 0
            guard ConfigSchema.isVisible(mode: mode, filter: filter) else {
                return nil
            }
            let label = option.label?.isEmpty == false ? option.label! : key
            guard search.isEmpty ||
                key.localizedCaseInsensitiveContains(search) ||
                label.localizedCaseInsensitiveContains(search)
            else { return nil }
            return SettingsEditorRow(
                key: key,
                label: label,
                tooltip: option.tooltip?.isEmpty == false ? option.tooltip : nil,
                sidetext: option.sidetext?.isEmpty == false ? option.sidetext : nil,
                mode: mode,
                type: option.type,
                multiline: option.multiline ?? false,
                minimum: option.min,
                maximum: option.max,
                enumValues: option.enumValues ?? [],
                enumLabels: option.enumLabels ?? [],
                value: value,
                isModified: modified.contains(key)
            )
        }

        var placed = Set<String>()
        var pages: [SettingsPageModel] = []
        for page in layout.pages(for: kind) {
            var groups: [Group] = []
            for group in page.groups {
                placed.formUnion(group.options)
                let rows = group.options.compactMap(row)
                if !rows.isEmpty {
                    groups.append(Group(
                        title: group.title.isEmpty ? page.page : group.title,
                        rows: rows
                    ))
                }
            }
            if !groups.isEmpty {
                pages.append(SettingsPageModel(title: page.page, groups: groups))
            }
        }

        // Options the preset defines but the desktop layout omits stay
        // reachable (never silently hidden), grouped by schema category.
        let unplaced = edited.keys
            .filter { !placed.contains($0) && !metadataKeys.contains($0) }
            .sorted()
            .compactMap(row)
        if !unplaced.isEmpty {
            let byCategory = Dictionary(grouping: unplaced) { row in
                index[row.key]?.category.flatMap { $0.isEmpty ? nil : $0 }
                    ?? "Uncategorized"
            }
            let groups = byCategory
                .sorted { $0.key < $1.key }
                .map { Group(title: $0.key, rows: $0.value) }
            pages.append(SettingsPageModel(title: "Other", groups: groups))
        }
        return .success(pages)
    }
}
