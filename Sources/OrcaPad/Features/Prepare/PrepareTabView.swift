import OrcaBridge
import SwiftUI

/// Prepare tab (desktop parity): machine / filament / process selection, the
/// full generated settings editor (collapsible category accordions under a
/// Simple/Advanced/Expert filter), and the slice action.
struct PrepareTabView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var modeFilter: SettingsModeFilter = .simple
    @State private var search = ""

    private var presets: PresetStore { environment.presets }

    var body: some View {
        NavigationStack {
            Group {
                switch presets.phase {
                case .idle, .loading:
                    ProgressView("loading presets…")
                case .failed(let failure):
                    ContentUnavailableView(
                        "Presets unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text(failure.localizedDescription)
                    )
                case .ready:
                    editor
                }
            }
            .navigationTitle("Prepare")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    sliceButton
                }
            }
            .searchable(
                text: $search,
                placement: .navigationBarDrawer(displayMode: .automatic)
            )
        }
    }

    // MARK: Slice action (desktop parity: top toolbar)

    private var sliceButton: some View {
        Button {
            Task {
                await environment.slicing.run(
                    document: environment.document,
                    presets: presets
                )
            }
        } label: {
            if environment.slicing.progress != nil {
                ProgressView(value: Double(environment.slicing.progress?.percent ?? 0), total: 100)
                    .frame(width: 72)
            } else {
                Label("Slice", systemImage: "scissors")
                    .font(.headline)
            }
        }
        .disabled(
            environment.document.scene?.objects.isEmpty != false ||
                environment.document.isBusy ||
                presets.isSelecting
        )
    }

    // MARK: Editor

    private var editor: some View {
        List {
            Section {
                Picker("Mode", selection: $modeFilter) {
                    ForEach(SettingsModeFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
            }

            presetSelectionSection

            ForEach([PresetKind.machine, .filament, .process], id: \.self) { kind in
                kindSection(kind)
            }

            Section {
                NavigationLink {
                    ResolvedConfigView(presets: presets)
                } label: {
                    Label("Resolved configuration", systemImage: "doc.text.magnifyingglass")
                }
            } footer: {
                if let failure = environment.slicing.lastFailure {
                    Text("Last slice failed: \(failure.localizedDescription)")
                        .foregroundStyle(.red)
                } else if let outcome = environment.slicing.lastOutcome {
                    Text(
                        "G-code ready — \(outcome.outputURL.lastPathComponent) · ~" +
                            "\(Int(outcome.result.timeEstimateSeconds / 60)) min"
                    )
                }
            }
        }
    }

    private var presetSelectionSection: some View {
        Section("Presets") {
            NavigationLink {
                PresetPickerView(presets: presets)
            } label: {
                Label(
                    presets.selection.machine.isEmpty
                        ? "Select machine" : presets.selection.machine,
                    systemImage: "printer"
                )
            }
            LabeledContent("Filament") {
                Text(presets.selection.filament)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Process") {
                Text(presets.selection.process)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func kindSectionModel(_ kind: PresetKind) -> KindSectionModel {

        let title: String
        switch kind {
        case .machine: title = "Machine settings"
        case .filament: title = "Filament settings"
        case .process: title = "Process settings"
        }

        guard case .success(let schema) = ConfigSchema.shared else {
            return KindSectionModel(kind: kind, title: title, categories: [], modifiedCount: 0)
        }
        let edited = presets.editedConfigs[kind] ?? [:]
        let modified = presets.modifiedKeys(in: kind)

        let rows: [SettingsEditorRow] = schema.compactMap { option in
            // Engine-derived membership: only options the kind's presets
            // actually define (desktop page parity without page tables).
            guard edited[option.key] != nil else { return nil }
            guard ConfigSchema.isVisible(
                mode: option.mode ?? 0,
                filter: modeFilter
            ) else { return nil }
            guard search.isEmpty ||
                option.key.localizedCaseInsensitiveContains(search) ||
                (option.label ?? "").localizedCaseInsensitiveContains(search)
            else { return nil }
            return SettingsEditorRow(
                key: option.key,
                label: option.label?.isEmpty == false ? option.label! : option.key,
                category: option.category?.isEmpty == false ? option.category! : "Other",
                tooltip: option.tooltip?.isEmpty == false ? option.tooltip : nil,
                mode: option.mode ?? 0,
                type: option.type,
                defaultValue: option.defaultValue,
                enumValues: option.enumValues ?? [],
                enumLabels: option.enumLabels ?? [],
                value: edited[option.key] ?? "",
                isModified: modified.contains(option.key)
            )
        }

        let grouped = Dictionary(grouping: rows, by: \.category)
            .map { (name: $0.key, rows: $0.value.sorted { $0.key < $1.key }) }
            .sorted { $0.name < $1.name }
        return KindSectionModel(
            kind: kind,
            title: title,
            categories: grouped,
            modifiedCount: modified.count
        )
    }

    @ViewBuilder
    private func kindSection(_ kind: PresetKind) -> some View {
        let model = kindSectionModel(kind)
        KindSettingsSection(
            model: model,
            onCommit: { key, value in
                Task {
                    await presets.setValue(
                        kind: kind,
                        key: key,
                        serializedValue: value
                    )
                }
            },
            onReset: { key in
                Task {
                    await presets.resetValue(kind: kind, key: key)
                }
            },
            onResetAll: {
                Task { await presets.resetKind(kind) }
            }
        )
    }
}

private struct KindSectionModel {
    let kind: PresetKind
    let title: String
    let categories: [(name: String, rows: [SettingsEditorRow])]
    let modifiedCount: Int
}

/// One preset-kind settings group: collapsible category accordions with
/// modified markers and per-kind reset.
private struct KindSettingsSection: View {
    let model: KindSectionModel
    let onCommit: (String, String) -> Void
    let onReset: (String) -> Void
    let onResetAll: () -> Void

    var body: some View {
        Section {
            if model.categories.isEmpty {
                Text("No settings at this level")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.categories, id: \.name) { category in
                    CategoryDisclosure(
                        name: category.name,
                        rows: category.rows,
                        onCommit: onCommit,
                        onReset: onReset
                    )
                }
            }
        } header: {
            HStack {
                Text(model.title)
                if model.modifiedCount > 0 {
                    Text("\(model.modifiedCount) modified")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                }
            }
        } footer: {
            if model.modifiedCount > 0 {
                Button("Reset all", action: onResetAll)
                    .font(.caption)
            }
        }
    }
}

private struct CategoryDisclosure: View {
    let name: String
    let rows: [SettingsEditorRow]
    let onCommit: (String, String) -> Void
    let onReset: (String) -> Void

    var body: some View {
        DisclosureGroup {
            ForEach(rows) { row in
                SettingsEditorRowView(
                    row: row,
                    onCommit: { onCommit(row.key, $0) },
                    onReset: { onReset(row.key) }
                )
            }
        } label: {
            HStack {
                Text(name)
                if rows.contains(where: \.isModified) {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                }
                Spacer()
                Text("\(rows.count)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// One option row with its typed editor, modified badge, and per-row reset.
private struct SettingsEditorRowView: View {
    let row: SettingsEditorRow
    let onCommit: (String) -> Void
    let onReset: () -> Void

    @State private var draft = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.label)
                    .font(.subheadline)
                    .foregroundStyle(row.isModified ? Color.accentColor : Color.primary)
                    .lineLimit(1)
                Text(row.key)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            editor
            if row.isModified {
                Button(action: onReset) {
                    Image(systemName: "arrow.uturn.backward.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .onAppear { draft = row.value }
        .onChange(of: row.value) { _, newValue in draft = newValue }
    }

    @ViewBuilder
    private var editor: some View {
        switch row.editorKind {
        case .toggle:
            Toggle("", isOn: Binding(
                get: { row.boolValue },
                set: { onCommit($0 ? "1" : "0") }
            ))
            .labelsHidden()
        case .picker:
            Picker("", selection: Binding(
                get: { row.value },
                set: { onCommit($0) }
            )) {
                ForEach(Array(row.enumValues.enumerated()), id: \.offset) { index, value in
                    Text(index < row.enumLabels.count ? row.enumLabels[index] : value)
                        .tag(value)
                }
            }
            .labelsHidden()
        case .numeric, .text:
            TextField(
                "value",
                text: $draft,
                onCommit: {
                    if draft != row.value { onCommit(draft) }
                }
            )
            .font(.caption.monospaced())
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: 160)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .foregroundStyle(row.isModified ? Color.accentColor : Color.secondary)
        }
    }
}
