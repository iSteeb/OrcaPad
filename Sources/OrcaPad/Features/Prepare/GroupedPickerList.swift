import OrcaBridge
import SwiftUI

/// Searchable single-choice preset list grouped by manufacturer (engine
/// vendor). Incompatible entries carry a warning glyph.
struct GroupedPickerList: View {
    let title: String
    let entries: [PresetEntry]
    let selected: String
    let vendorPlaceholder: String
    let onSelect: (String) -> Void

    @State private var search = ""
    @Environment(\.dismiss) private var dismiss

    private struct Group: Identifiable {
        let vendor: String
        let entries: [PresetEntry]
        var id: String { vendor }
    }

    private var groups: [Group] {
        let filtered = search.isEmpty
            ? entries
            : entries.filter {
                $0.name.localizedCaseInsensitiveContains(search) ||
                    $0.vendor.localizedCaseInsensitiveContains(search)
            }
        let byVendor = Dictionary(grouping: filtered) { entry in
            entry.vendor.isEmpty ? vendorPlaceholder : entry.vendor
        }
        return byVendor
            .map { Group(vendor: $0.key, entries: $0.value) }
            .sorted { $0.vendor < $1.vendor }
    }

    var body: some View {
        List {
            ForEach(groups) { group in
                Section(group.vendor) {
                    ForEach(group.entries, id: \.name) { entry in
                        Button {
                            onSelect(entry.name)
                            dismiss()
                        } label: {
                            HStack {
                                Text(entry.name)
                                    .lineLimit(1)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if entry.name == selected {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                } else if !entry.isCompatible {
                                    Image(systemName: "exclamationmark.triangle")
                                        .foregroundStyle(.secondary)
                                        .font(.caption)
                                }
                            }
                        }
                    }
                }
            }
        }
        .searchable(
            text: $search,
            placement: .navigationBarDrawer(displayMode: .always)
        )
        .navigationTitle(title)
    }
}
