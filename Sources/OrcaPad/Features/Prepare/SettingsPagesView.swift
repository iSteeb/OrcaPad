// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

import OrcaBridge
import SwiftUI

/// Desktop-parity settings for one preset kind, embeddable inside an outer
/// List: a page strip (Quality / Strength / Speed / …) and the selected
/// page's optgroups as collapsible accordions.
struct SettingsPagesSections: View {
    let kind: PresetKind
    let filter: SettingsModeFilter
    let search: String
    /// External page selection (the top pill's page chips drive it).
    var externalSelectedPage: Binding<String?>? = nil

    @Environment(AppEnvironment.self) private var environment
    @State private var collapsedGroups: Set<String> = []

    private var selectedPage: Binding<String?> {
        externalSelectedPage ?? Binding(
            get: { internalPage },
            set: { internalPage = $0 }
        )
    }
    @State private var internalPage: String?

    private var presets: PresetStore { environment.presets }

    var body: some View {
        switch SettingsPageModel.build(
            kind: kind,
            edited: presets.editedConfigs[kind] ?? [:],
            modified: presets.modifiedKeys(in: kind),
            filter: filter,
            search: search
        ) {
        case .failure(let failure):
            Section {
                Text("Settings unavailable: \(failure.localizedDescription)")
                    .foregroundStyle(.red)
            }
        case .success(let pages):
            if pages.isEmpty {
                Section {
                    Text(search.isEmpty ? "No settings at this level" : "No matches")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                content(pages)
            }
        }
    }

    @ViewBuilder
    private func content(_ pages: [SettingsPageModel]) -> some View {
        // While searching, show every matching page; otherwise one page.
        let current = pages.first { $0.title == selectedPage.wrappedValue } ?? pages[0]
        let visible = search.isEmpty ? [current] : pages

        Section {
            // The pill's page chips drive selection when bound externally —
            // no duplicate strip in the body (user spec).
            if externalSelectedPage == nil {
                PageStrip(
                    pages: pages,
                    selected: current.title,
                    onSelect: { selectedPage.wrappedValue = $0 }
                )
                .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
            }
        }

        ForEach(visible) { page in
            ForEach(page.groups) { group in
                let groupID = "\(page.title)/\(group.title)"
                Section {
                    if !collapsedGroups.contains(groupID) {
                        ForEach(group.rows) { row in
                            SettingsEditorRowView(
                                row: row,
                                onCommit: { commit(row.key, $0) },
                                onReset: { reset(row.key) },
                                onReject: { environment.status.report(.presets, $0) }
                            )
                        }
                    }
                } header: {
                    GroupHeader(
                        title: search.isEmpty ? group.title : "\(page.title) · \(group.title)",
                        modifiedCount: group.modifiedCount,
                        collapsed: collapsedGroups.contains(groupID),
                        onToggle: { toggle(groupID) }
                    )
                }
            }
        }
    }

    private func toggle(_ groupID: String) {
        if collapsedGroups.contains(groupID) {
            collapsedGroups.remove(groupID)
        } else {
            collapsedGroups.insert(groupID)
        }
    }

    private func commit(_ key: String, _ value: String) {
        Task {
            await presets.setValue(kind: kind, key: key, serializedValue: value)
        }
    }

    private func reset(_ key: String) {
        Task { await presets.resetValue(kind: kind, key: key) }
    }
}

/// Pushed screen variant (machine / filament settings, desktop "edit" dialogs).
struct SettingsPagesScreen: View {
    let kind: PresetKind
    let title: String

    @Environment(AppEnvironment.self) private var environment
    @State private var filter: SettingsModeFilter = .advanced
    @State private var search = ""

    var body: some View {
        List {
            Section {
                Picker("Mode", selection: $filter) {
                    ForEach(SettingsModeFilter.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }
            SettingsPagesSections(kind: kind, filter: filter, search: search)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                PresetActionsMenu(kind: kind)
            }
        }
    }
}

private struct PageStrip: View {
    let pages: [SettingsPageModel]
    let selected: String
    let onSelect: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pages) { page in
                    Button {
                        onSelect(page.title)
                    } label: {
                        HStack(spacing: 4) {
                            Text(page.title)
                                .font(.subheadline.weight(page.title == selected ? .semibold : .regular))
                            if page.modifiedCount > 0 {
                                Circle()
                                    .fill(Color.accentColor)
                                    .frame(width: 6, height: 6)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            page.title == selected
                                ? AnyShapeStyle(Color.accentColor.opacity(0.25))
                                : AnyShapeStyle(.quaternary),
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct GroupHeader: View {
    let title: String
    let modifiedCount: Int
    let collapsed: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.caption2.weight(.bold))
                Text(title)
                if modifiedCount > 0 {
                    Text("\(modifiedCount) modified")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                        .textCase(nil)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One option row: typed editor, unit, tooltip, range validation, modified
/// badge, and per-row reset.
/// Desktop per-extruder vector editing: one compact numeric field per
/// element, slot-numbered; commits recombine the CSV serialization.
struct PerElementVectorEditor: View {
    let value: String
    let onCommit: (String) -> Void
    let onReject: (String) -> Void

    @State private var elements: [String] = []

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(elements.indices), id: \.self) { index in
                    HStack(spacing: 2) {
                        Text("\(index + 1)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        TextField("0", text: binding(index))
                            .keyboardType(.numbersAndPunctuation)
                            .frame(width: 56)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption.monospaced())
                            .onSubmit { commit() }
                    }
                }
            }
        }
        .onAppear { elements = value.split(separator: ",").map(String.init) }
        .onChange(of: value) { _, newValue in
            elements = newValue.split(separator: ",").map(String.init)
        }
    }

    private func binding(_ index: Int) -> Binding<String> {
        Binding(
            get: { index < elements.count ? elements[index] : "" },
            set: { if index < elements.count { elements[index] = $0 } }
        )
    }

    private func commit() {
        let combined = elements
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: ",")
        // element-level numeric sanity: every element must parse
        for element in elements {
            let trimmed = element.trimmingCharacters(in: .whitespaces)
            let candidate = trimmed.hasSuffix("%")
                ? String(trimmed.dropLast()) : trimmed
            if !candidate.isEmpty, Double(candidate) == nil {
                onReject("\"\(element)\" is not a number")
                return
            }
        }
        onCommit(combined)
    }
}

struct SettingsEditorRowView: View {
    let row: SettingsEditorRow
    let onCommit: (String) -> Void
    let onReset: () -> Void
    let onReject: (String) -> Void

    @State private var draft = ""
    @State private var rejection: String?
    @State private var showTooltip = false
    @State private var editingMultiline = false
    @State private var multilineDraft = ""

    /// The row's value as a single swatch colour when it IS one (plain or
    /// engine-quoted `#rrggbb`); nil keeps the raw text editor only.
    private var colourValue: Color? {
        var token = row.value.trimmingCharacters(in: .whitespaces)
        if token.hasPrefix("\"") && token.hasSuffix("\"") && token.count >= 2 {
            token = String(token.dropFirst().dropLast())
        }
        return Color(hex: token)
    }

    /// #rrggbb from a Color (uppercase, engine serialization).
    private static func hexString(_ colour: Color) -> String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(colour).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func part(_ value: CGFloat) -> String {
            String(format: "%02X", min(max(Int((value * 255).rounded()), 0), 255))
        }
        return "#" + part(red) + part(green) + part(blue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                labelColumn
                Spacer(minLength: 8)
                editor
                if let sidetext = row.sidetext, row.editorKind == .numeric {
                    Text(sidetext)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if row.isModified {
                    Button(action: onReset) {
                        Image(systemName: "arrow.uturn.backward.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            if showTooltip, let tooltip = row.tooltip {
                Text(tooltip)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let rejection {
                Text(rejection)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onAppear { draft = row.value }
        .onChange(of: row.value) { _, newValue in
            draft = newValue
            rejection = nil
        }
        .sheet(isPresented: $editingMultiline) { multilineSheet }
    }

    private var labelColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(row.label)
                    .font(.subheadline)
                    .foregroundStyle(row.isModified ? Color.accentColor : Color.primary)
                    .lineLimit(2)
                if row.tooltip != nil {
                    Image(systemName: showTooltip ? "info.circle.fill" : "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(row.key)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .onTapGesture { showTooltip.toggle() }
    }

    @ViewBuilder
    private var editor: some View {
        switch row.editorKind {
        case .perElement:
            PerElementVectorEditor(
                value: row.value,
                onCommit: onCommit,
                onReject: onReject
            )
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
        case .multiline:
            Button {
                multilineDraft = ConfigStringCodec.unescape(row.value)
                editingMultiline = true
            } label: {
                Label(
                    row.value.isEmpty ? "Empty" : "Edit",
                    systemImage: "text.alignleft"
                )
                .font(.caption)
            }
            .buttonStyle(.bordered)
        case .numeric, .text:
            HStack(spacing: 8) {
                if row.isColour, let colour = colourValue {
                    // Desktop colour options (filament_colour & co): a swatch
                    // picker beside the raw field; vectors stay raw text.
                    ColorPicker("", selection: Binding(
                        get: { colour },
                        set: { newColour in
                            onCommit(Self.hexString(newColour))
                        }
                    ), supportsOpacity: false)
                    .labelsHidden()
                }
                TextField("value", text: $draft)
                    .onSubmit(submit)
                    .font(.callout.monospaced())
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: row.editorKind == .numeric ? 110 : 220)
                    .keyboardType(row.editorKind == .numeric ? .numbersAndPunctuation : .default)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .foregroundStyle(
                        rejection != nil ? Color.red
                            : (row.isModified ? Color.accentColor : Color.secondary)
                    )
            }
        }
    }

    private func submit() {
        guard draft != row.value else { return }
        if let message = row.numericRejection(for: draft) {
            rejection = message
            onReject(message)
            return
        }
        rejection = nil
        onCommit(draft)
    }

    private var multilineSheet: some View {
        NavigationStack {
            TextEditor(text: $multilineDraft)
                .font(.callout.monospaced())
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(8)
                .navigationTitle(row.label)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { editingMultiline = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            let serialized = ConfigStringCodec.escape(multilineDraft)
                            if serialized != row.value { onCommit(serialized) }
                            editingMultiline = false
                        }
                    }
                }
        }
    }
}
