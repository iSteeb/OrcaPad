// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

import SwiftUI

/// The complete resolved configuration exactly as slicing will consume it:
/// labeled and categorized from the pinned-engine schema, with non-default
/// values highlighted and a machine/filament/process/bed summary header.
struct ResolvedConfigView: View {
    let presets: PresetStore

    @State private var service = ResolvedConfigService()
    @State private var search = ""
    @State private var nonDefaultsOnly = false

    var body: some View {
        Group {
            switch service.phase {
            case .idle, .loading:
                ProgressView("resolving configuration…")
            case .failed(let failure):
                ContentUnavailableView(
                    "Configuration unavailable",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(failure.localizedDescription)
                )
            case .ready:
                list
            }
        }
        .navigationTitle("Resolved Config")
        .navigationBarTitleDisplayMode(.inline)
        .task { await service.load(presets: presets) }
    }

    private struct SectionModel: Identifiable {
        let category: String
        let rows: [ResolvedConfigRow]
        var id: String { category }
    }

    private var sections: [SectionModel] {
        let filtered = service.rows.filter { row in
            if nonDefaultsOnly && row.isDefault { return false }
            guard !search.isEmpty else { return true }
            return row.key.localizedCaseInsensitiveContains(search) ||
                row.label.localizedCaseInsensitiveContains(search) ||
                row.value.localizedCaseInsensitiveContains(search)
        }
        return Dictionary(grouping: filtered, by: \.category)
            .map { SectionModel(category: $0.key, rows: $0.value.sorted { $0.key < $1.key }) }
            .sorted { $0.category < $1.category }
    }

    private var list: some View {
        List {
            summarySection
            ForEach(sections) { section in
                Section(section.category) {
                    ForEach(section.rows) { row in
                        rowView(row)
                    }
                }
            }
        }
        .searchable(
            text: $search,
            placement: .navigationBarDrawer(displayMode: .always)
        )
        .safeAreaInset(edge: .bottom) {
            Toggle("Modified values only", isOn: $nonDefaultsOnly)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
        }
    }

    private var summarySection: some View {
        Section("Selection") {
            LabeledContent("Machine", value: presets.selection.machine)
            LabeledContent("Filament", value: presets.selection.filament)
            LabeledContent("Process", value: presets.selection.process)
            if let volume = presets.printVolume {
                LabeledContent(
                    "Print volume",
                    value: String(
                        format: "%.0f × %.0f mm",
                        volume.width,
                        volume.depth
                    )
                )
                LabeledContent(
                    "Bed origin",
                    value: String(
                        format: "(%.0f, %.0f) → (%.0f, %.0f)",
                        volume.minX, volume.minY,
                        volume.maxX, volume.maxY
                    )
                )
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: ResolvedConfigRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.label)
                    .font(.subheadline)
                    .foregroundStyle(row.isDefault ? Color.primary : Color.accentColor)
                    .lineLimit(1)
                Spacer()
                Text(row.value)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Text(row.key)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 1)
    }
}
