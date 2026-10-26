// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

import OrcaBridge
import SwiftUI

/// Cross-kind settings search (board cycle-0.15): a non-empty query lists
/// matching options from ALL THREE preset kinds' edited config dumps
/// (grouped by kind), replacing the per-kind page filter in the Prepare
/// tab. Tapping a match hands the jump (kind + option key + page to
/// reveal) back to the host; the host owns mode elevation and navigation.
///
/// The search runs at expert level on purpose: searching is an explicit
/// find-intent, and mode-hidden options must stay findable (desktop
/// search unhides them too).
struct SettingsSearchResults: View {
    let presets: PresetStore
    let query: String
    /// kind, matched option key, page title to reveal.
    let onJump: (PresetKind, String, String) -> Void

    private struct Match: Identifiable {
        let kind: PresetKind
        let page: String
        let row: SettingsEditorRow
        var id: String { "\(kind.rawValue)|\(page)|\(row.key)" }
    }

    private func buildMatches(kind: PresetKind) -> Result<[Match], AppFailure> {
        switch SettingsPageModel.build(
            kind: kind,
            edited: presets.editedConfigs[kind] ?? [:],
            modified: presets.modifiedKeys(in: kind),
            filter: .expert,
            search: query
        ) {
        case .success(let pages):
            return .success(pages.flatMap { page in
                page.groups.flatMap { group in
                    group.rows.map { Match(kind: kind, page: page.title, row: $0) }
                }
            })
        case .failure(let failure):
            return .failure(failure)
        }
    }

    var body: some View {
        // One build per kind; the schema/layout decode is process-cached.
        let results = PresetKind.allCases.map { ($0, buildMatches(kind: $0)) }
        let firstFailure = results.compactMap { _, result in
            if case .failure(let failure) = result { return failure } else { return nil }
        }.first
        if let firstFailure {
            Section {
                Text("Settings unavailable: \(firstFailure.localizedDescription)")
                    .foregroundStyle(.red)
            }
        } else {
            let matches = results.compactMap { _, result in
                if case .success(let list) = result { return list } else { return nil }
            }.flatMap { $0 }
            if matches.isEmpty {
                Section {
                    Text("No settings match \"\(query)\"")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(PresetKind.allCases, id: \.self) { kind in
                    let kindMatches = matches.filter { $0.kind == kind }
                    if !kindMatches.isEmpty {
                        Section {
                            ForEach(kindMatches) { match in
                                matchRow(match)
                            }
                        } header: {
                            Label(
                                "\(title(kind)) · \(kindMatches.count)",
                                systemImage: symbol(kind)
                            )
                        }
                    }
                }
            }
        }
    }

    private func matchRow(_ match: Match) -> some View {
        Button {
            onJump(match.kind, match.row.key, match.page)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(match.row.label)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text("\(match.page) · \(match.row.key)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(match.row.value)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 150, alignment: .trailing)
            }
        }
        .buttonStyle(.plain)
    }

    private func title(_ kind: PresetKind) -> String {
        switch kind {
        case .machine: return "Printer"
        case .filament: return "Filament"
        case .process: return "Process"
        }
    }

    private func symbol(_ kind: PresetKind) -> String {
        switch kind {
        case .machine: return "printer"
        case .filament: return "circle.dotted.circle"
        case .process: return "slider.horizontal.3"
        }
    }
}
