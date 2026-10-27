// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

import OrcaBridge
import SwiftUI

/// Device tab, desktop Device page parity: the selected physical printer's
/// own web interface (desktop `PrinterWebView`, the scoped AGENTS.md
/// exception) wrapped in native controls: printer picker, reload, open in
/// the browser, send the sliced G-code, and printer management (desktop
/// PhysicalPrinterDialog). Presentation only: printers live in
/// `PrinterStore`, uploads in `PrintHostService`.
struct DeviceTabView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openURL) private var openURL
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var session = PrinterWebSession()
    @State private var editorTarget: EditorTarget?
    @State private var managePresented = false
    @State private var sendPresented = false

    private var store: PrinterStore { environment.printers }

    private var selected: PrinterStore.Record? {
        store.selectedPrinter(machinePreset: environment.presets.selection.machine)
    }

    private var selectedURL: URL? {
        guard let selected, case .success(let url) = PrinterStore.webUIURL(for: selected) else {
            return nil
        }
        return url
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Same wide pill chrome as Plate / Preview: Printers | file
                // actions (reload, browser, send).
                topBar
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                deviceLayout
            }
                .navigationTitle(selected?.name ?? "Device")
                .toolbar(.hidden, for: .navigationBar)
                .navigationBarTitleDisplayMode(.inline)
                .sheet(item: $editorTarget) { target in
                    PhysicalPrinterEditor(
                        existing: target.record,
                        defaultPreset: environment.presets.selection.machine
                    ) { record in
                        Task { await save(record) }
                    }
                }
                .sheet(isPresented: $managePresented) {
                    PrinterManagementSheet(
                        onAdd: { editorTarget = .add },
                        onEdit: { editorTarget = .edit($0) },
                        onDelete: { name in Task { await delete(name) } }
                    )
                }
                .sheet(isPresented: $sendPresented) {
                    if let selected {
                        SendGcodeSheet(printer: selected)
                    }
                }
                .task(id: environment.presets.isReady) { await reload() }
                // Desktop device list: probe every printer's reachability
                // while the tab is open, not just the selected one.
                .task {
                    while !Task.isCancelled {
                        await store.refreshStatuses()
                        do {
                            try await Task.sleep(for: .seconds(10))
                        } catch {
                            break  // cancellation: the tab went away
                        }
                    }
                }
        }
    }

    /// All-printers support (desktop device page): a leading list of every
    /// configured printer with live status on regular widths; compact
    /// widths get a horizontal chip bar.
    @ViewBuilder
    private var deviceLayout: some View {
        if store.printers.isEmpty {
            content
        } else if horizontalSizeClass == .regular {
            HStack(spacing: 0) {
                PrinterSidebar(
                    printers: store.printers,
                    selectedName: selected?.name,
                    phases: store.phases,
                    onSelect: { store.select($0) },
                    onAdd: { editorTarget = .add }
                )
                Divider()
                content
            }
        } else {
            VStack(spacing: 0) {
                PrinterChipBar(
                    printers: store.printers,
                    selectedName: selected?.name,
                    phases: store.phases,
                    onSelect: { store.select($0) }
                )
                content
            }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if !store.isLoaded {
            ProgressView("Loading printers…")
        } else if let printer = selected {
            switch PrinterStore.webUIURL(for: printer) {
            case .success(let url):
                webContent(printer: printer, url: url)
            case .failure(let error):
                ContentUnavailableView {
                    Label("Cannot show \(printer.name)", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error.localizedDescription)
                } actions: {
                    Button("Edit printer") { editorTarget = .edit(printer) }
                }
            }
        } else {
            ContentUnavailableView {
                Label("No printers", systemImage: "printer")
            } description: {
                Text("Add your printer (Moonraker/Klipper or OctoPrint) to use its web interface here and send G-code from OrcaPad.")
            } actions: {
                Button("Add printer") { editorTarget = .add }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func webContent(printer: PrinterStore.Record, url: URL) -> some View {
        PrinterWebView(session: session)
            .overlay(alignment: .top) {
                if session.isLoading {
                    ProgressView()
                        .padding(8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 8)
                }
            }
            .overlay {
                if let failure = session.failure {
                    ContentUnavailableView {
                        Label("\(printer.name) is unreachable", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text("\(failure.url.absoluteString)\n\(failure.message)")
                    } actions: {
                        Button("Retry") { session.reload() }
                            .buttonStyle(.borderedProminent)
                        Button("Edit printer") { editorTarget = .edit(printer) }
                    }
                    .background(.background)
                }
            }
            .task(id: url) {
                session.show(PrinterStore.webUIRequest(for: printer, url: url))
            }
    }

    // MARK: Top bar (Plate-style wide pill)

    private var topBar: some View {
        HStack(spacing: 4) {
            Menu {
                ForEach(store.printers, id: \.name) { printer in
                    Button {
                        store.select(printer.name)
                    } label: {
                        if printer.name == selected?.name {
                            Label(printer.name, systemImage: "checkmark")
                        } else {
                            Text(printer.name)
                        }
                    }
                }
                if !store.printers.isEmpty { Divider() }
                Button {
                    editorTarget = .add
                } label: {
                    Label("Add printer…", systemImage: "plus")
                }
                Button {
                    managePresented = true
                } label: {
                    Label("Manage printers…", systemImage: "list.bullet")
                }
                .disabled(store.printers.isEmpty)
            } label: {
                ChromeToolLabel(symbol: "printer", label: "Printers")
            }
            .disabled(store.isSaving)
            Divider().frame(height: 28)
            Button {
                session.reload()
            } label: {
                ChromeToolLabel(symbol: "arrow.clockwise", label: "Reload")
            }
            .buttonStyle(.plain)
            .disabled(selectedURL == nil)
            Button {
                if let selectedURL { openURL(selectedURL) }
            } label: {
                ChromeToolLabel(symbol: "safari", label: "Browser")
            }
            .buttonStyle(.plain)
            .disabled(selectedURL == nil)
            Button {
                sendPresented = true
            } label: {
                ChromeToolLabel(symbol: "paperplane", label: "Send")
            }
            .buttonStyle(.plain)
            .disabled(
                selected == nil || environment.slicing.lastOutcome?.outputURL == nil
                    || environment.printHost.isUploading
            )
        }
        .padding(6)
        .background(.ultraThinMaterial, in: Capsule())
    }

    // MARK: Actions

    private func reload() async {
        guard let engine = environment.presets.engineForSlicing else { return }
        await store.reload(presets: engine)
    }

    private func save(_ record: PrinterStore.Record) async {
        guard let engine = environment.presets.engineForSlicing else {
            environment.status.report(.device, failure: .invariant(
                operation: "save printer", diagnostic: "presets are not loaded"))
            return
        }
        await store.save(record, presets: engine)
    }

    private func delete(_ name: String) async {
        guard let engine = environment.presets.engineForSlicing else {
            environment.status.report(.device, failure: .invariant(
                operation: "delete printer", diagnostic: "presets are not loaded"))
            return
        }
        await store.delete(name, presets: engine)
    }
}

/// Sheet routing for the printer editor.
private enum EditorTarget: Identifiable {
    case add
    case edit(PrinterStore.Record)

    var id: String {
        switch self {
        case .add: return "+add"
        case .edit(let record): return record.name
        }
    }

    var record: PrinterStore.Record? {
        if case .edit(let record) = self { return record }
        return nil
    }
}

/// All-printers sidebar (desktop device page): every configured printer
/// with live reachability, one tap to switch, add at the bottom.
private struct PrinterSidebar: View {
    let printers: [PrinterStore.Record]
    let selectedName: String?
    let phases: [String: PrinterStore.PrinterPhase]
    let onSelect: (String) -> Void
    let onAdd: () -> Void

    var body: some View {
        List {
            Section {
                ForEach(printers, id: \.name) { printer in
                    Button {
                        onSelect(printer.name)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: PrinterHostKind.symbol(printer.hostType))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(printer.name)
                                    .font(.callout.weight(
                                        printer.name == selectedName ? .semibold : .regular
                                    ))
                                    .lineLimit(1)
                                Text(PrinterHostKind.label(printer.hostType))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            StatusDot(phase: phases[printer.name] ?? .checking)
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        printer.name == selectedName
                            ? Color.accentColor.opacity(0.12)
                            : Color.clear
                    )
                }
            } header: {
                Text("Printers")
            }
            Section {
                Button {
                    onAdd()
                } label: {
                    Label("Add printer…", systemImage: "plus")
                }
            }
        }
        .listStyle(.sidebar)
        .frame(width: 264)
        .safeAreaInset(edge: .bottom) {
            if printers.isEmpty {
                Text("No printers")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Compact-width all-printers bar: horizontal chips with status dots.
private struct PrinterChipBar: View {
    let printers: [PrinterStore.Record]
    let selectedName: String?
    let phases: [String: PrinterStore.PrinterPhase]
    let onSelect: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(printers, id: \.name) { printer in
                    Button {
                        onSelect(printer.name)
                    } label: {
                        HStack(spacing: 6) {
                            StatusDot(phase: phases[printer.name] ?? .checking)
                            Text(printer.name)
                                .font(.callout.weight(
                                    printer.name == selectedName ? .semibold : .regular
                                ))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            printer.name == selectedName
                                ? Color.accentColor.opacity(0.18)
                                : Color(.secondarySystemBackground),
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
        .background(.ultraThinMaterial)
    }
}

/// Reachability indicator (desktop device list online/offline dot).
private struct StatusDot: View {
    let phase: PrinterStore.PrinterPhase

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }

    private var color: Color {
        switch phase {
        case .checking: return .secondary.opacity(0.6)
        case .online: return .green
        case .offline: return .red
        }
    }
}

/// Host types OrcaPad can upload to (PrintHostService); the engine knows
/// more, which stay typed rejections until implemented.
enum PrinterHostKind {
    static let supported: [(value: String, label: String)] = [
        ("moonraker", "Moonraker (Klipper)"),
        ("octoprint", "OctoPrint"),
        ("prusalink", "PrusaLink"),
        ("duet", "Duet / RepRapFirmware"),
        ("flashair", "FlashAir SD card"),
        ("repetier", "Repetier"),
        ("astrobox", "AstroBox"),
        ("mks", "MKS"),
        ("esp3d", "ESP3D"),
        ("crealityprint", "Creality Print (LAN)"),
        ("elegoolink", "ElegooLink"),
        ("flashforge", "Flashforge"),
        ("obico", "Obico"),
        ("prusaconnect", "PrusaConnect"),
        ("simplyprint", "SimplyPrint"),
        ("3dprinteros", "3DPrinterOS"),
    ]

    static func label(_ hostType: String) -> String {
        supported.first { $0.value == hostType }?.label ?? hostType
    }

    static func symbol(_ hostType: String) -> String {
        switch hostType {
        case "moonraker": return "antenna.radiowaves.left.and.right"
        case "octoprint": return "server.rack"
        case "prusalink": return "printer.dotmatrix"
        case "duet": return "cpu"
        case "flashair": return "sdcard"
        case "repetier": return "dial.max"
        case "astrobox": return "externaldrive.connected.to.line.below"
        case "mks": return "cylinder.split.1x2"
        case "esp3d": return "wifi.router"
        case "crealityprint": return "printer.dotmatrix.fill"
        case "elegoolink": return "link"
        case "flashforge": return "cube.transparent"
        case "obico": return "cloud"
        case "prusaconnect": return "globe"
        case "simplyprint": return "cloud.fill"
        case "3dprinteros": return "network"
        default: return "printer"
        }
    }
}

/// Printer list with edit / delete (desktop physical printer combo + dialog).
private struct PrinterManagementSheet: View {
    let onAdd: () -> Void
    let onEdit: (PrinterStore.Record) -> Void
    let onDelete: (String) -> Void

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(environment.printers.printers, id: \.name) { printer in
                    VStack(alignment: .leading, spacing: 3) {
                        Label(printer.name, systemImage: PrinterHostKind.symbol(printer.hostType))
                            .font(.headline)
                        Text("\(PrinterHostKind.label(printer.hostType)) · \(printer.url)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !printer.webUI.isEmpty {
                            Text("Device UI: \(printer.webUI)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(printer.presetNames.joined(separator: ", "))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            onDelete(printer.name)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button {
                            dismiss()
                            onEdit(printer)
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        environment.printers.select(printer.name)
                        dismiss()
                    }
                }
            }
            .navigationTitle("Printers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        dismiss()
                        onAdd()
                    } label: {
                        Label("Add printer", systemImage: "plus")
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Desktop PrintHostSendDialog: upload a G-code to the selected printer,
/// optionally starting the print. Defaults to the last slice result; any
/// other G-code can be picked (Documents/G-code keeps every previous
/// result, visible in Files).
private struct SendGcodeSheet: View {
    let printer: PrinterStore.Record

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var startPrint = true
    @State private var chosen: URL?
    @State private var pickPresented = false

    private var gcode: URL? { chosen ?? environment.slicing.lastOutcome?.outputURL }

    var body: some View {
        NavigationStack {
            Form {
                if let gcode {
                    Section {
                        HStack {
                            LabeledContent("File", value: gcode.lastPathComponent)
                            Spacer()
                            Button {
                                pickPresented = true
                            } label: {
                                Image(systemName: "folder")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Choose G-code files")
                        }
                        LabeledContent("Printer", value: printer.name)
                        LabeledContent("Host", value: "\(PrinterHostKind.label(printer.hostType)) · \(printer.url)")
                        Toggle("Start print after upload", isOn: $startPrint)
                    }
                    Section {
                        Button {
                            let target = (gcode, printer, startPrint)
                            Task {
                                await environment.printHost.upload(
                                    target.0, to: target.1, startPrint: target.2)
                            }
                        } label: {
                            HStack {
                                Label("Send", systemImage: "paperplane.fill")
                                Spacer()
                                if environment.printHost.isUploading { ProgressView() }
                            }
                        }
                        .disabled(environment.printHost.isUploading)
                        // Board cycle-0.16 upload queue: park the file in the
                        // sequential queue instead of sending now (the queue
                        // section below shows per-item status and Skip).
                        Button {
                            environment.printHost.enqueue(
                                [gcode], to: printer, startPrint: startPrint)
                        } label: {
                            Label("Add to queue", systemImage: "list.bottom")
                        }
                        .disabled(environment.printHost.isUploading)
                    } footer: {
                        if let receipt = environment.printHost.lastReceipt,
                           receipt.printer == printer.name,
                           receipt.file == gcode.lastPathComponent {
                            Label(
                                receipt.startedPrint
                                    ? "Uploaded; the print is starting."
                                    : "Uploaded to the printer's file list.",
                                systemImage: "checkmark.circle.fill"
                            )
                            .foregroundStyle(.green)
                        }
                    }
                    if !environment.printHost.queue.isEmpty {
                        uploadQueueSection
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Slice a plate first, or pick an existing G-code file to send to \(printer.name).")
                            .foregroundStyle(.secondary)
                        Button {
                            pickPresented = true
                        } label: {
                            Label("Choose G-code…", systemImage: "folder")
                        }
                    }
                }
            }
            .navigationTitle("Send to printer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $pickPresented,
                allowedContentTypes: GcodeTypes.all,
                allowsMultipleSelection: true,
                onCompletion: { result in
                    if case .success(let urls) = result {
                        if urls.count <= 1 {
                            chosen = urls.first
                        } else {
                            // A multi-file pick is a queue by intent (board
                            // cycle-0.16): every picked G-code goes to the
                            // sequential queue, not just the first one.
                            environment.printHost.enqueue(
                                urls, to: printer, startPrint: startPrint)
                        }
                    }
                }
            )
        }
        .presentationDetents([.medium, .large])
    }

    /// Board cycle-0.16 upload queue: every parked upload with its phase;
    /// Skip cancels the one in flight and the queue advances, waiting items
    /// can be dropped, finished ones cleared.
    private var uploadQueueSection: some View {
        Section {
            ForEach(environment.printHost.queue) { item in
                HStack(spacing: 10) {
                    phaseIcon(item.phase)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.file.lastPathComponent)
                            .font(.callout)
                            .lineLimit(1)
                        Text("\(item.printer.name) · \(item.statusText)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if item.phase == .running {
                        Button("Skip") {
                            environment.printHost.cancelCurrentUpload()
                        }
                        .font(.caption)
                    } else if item.phase == .waiting {
                        Button {
                            environment.printHost.removeQueuedUpload(id: item.id)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove from queue")
                    }
                }
            }
            if environment.printHost.queue.contains(where: \.isFinished) {
                Button("Clear finished") {
                    environment.printHost.clearFinishedUploads()
                }
            }
        } header: {
            Text("Upload queue")
        } footer: {
            Text("Uploads run one at a time. Skip cancels the current upload and starts the next file.")
        }
    }

    @ViewBuilder
    private func phaseIcon(_ phase: PrintHostService.QueuedUpload.Phase) -> some View {
        switch phase {
        case .waiting:
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
        case .running:
            ProgressView()
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .cancelled:
            Image(systemName: "minus.circle")
                .foregroundStyle(.orange)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }
}

/// Desktop PhysicalPrinterDialog: name, host type, host URL, device UI URL,
/// API key.
private struct PhysicalPrinterEditor: View {
    let existing: PrinterStore.Record?
    let defaultPreset: String
    let onDone: (PrinterStore.Record) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var hostType = "moonraker"
    @State private var url = ""
    @State private var webUI = ""
    @State private var apiKey = ""
    /// Board cycle-0.16 Bonjour discovery (see PrinterDiscovery): browse
    /// while the section is on, resolve on tap, prefill URL + host type.
    @State private var discovery = PrinterDiscovery()

    /// Cloud hosts serve from a fixed address which the desktop dialog
    /// prefills (PhysicalPrinterDialog.cpp: app.obico.io / connect.prusa3d.
    /// com; SimplyPrint.hpp get_host; 3DPrinterOS.hpp default_host).
    private static let serviceHosts: [String: String] = [
        "obico": "https://app.obico.io",
        "prusaconnect": "https://connect.prusa3d.com",
        "simplyprint": "https://simplyprint.io",
        "3dprinteros": "https://cloud.3dprinteros.com",
    ]

    private static func isHTTP(_ value: String) -> Bool {
        value.hasPrefix("http://") || value.hasPrefix("https://")
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && Self.isHTTP(url)
            && (webUI.isEmpty || Self.isHTTP(webUI))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Printer") {
                    TextField("Name", text: $name)
                        .autocorrectionDisabled()
                        .disabled(existing != nil)
                    Picker("Host type", selection: $hostType) {
                        ForEach(PrinterHostKind.supported, id: \.value) { kind in
                            Text(kind.label).tag(kind.value)
                        }
                        // An engine host type OrcaPad cannot upload to yet is
                        // kept as-is, never silently rewritten.
                        if let existing,
                           !PrinterHostKind.supported.contains(where: { $0.value == existing.hostType }) {
                            Text("\(existing.hostType) (upload not supported yet)").tag(existing.hostType)
                        }
                    }
                }
                Section {
                    TextField("Host URL", text: $url)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Device UI URL (optional)", text: $webUI)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("API key (optional)", text: $apiKey)
                } header: {
                    Text("Connection")
                } footer: {
                    Text("Host URL receives uploads, e.g. http://192.168.1.51 (Moonraker behind Mainsail/Fluidd) or http://192.168.1.51:7125 (Moonraker directly). Cloud hosts use their fixed service address (prefilled); paste the account/token as the API key. Flashforge takes the printer's LAN address with API key \"serial:checkCode\". Device UI URL is the web page shown in this tab when it differs from the host URL, e.g. http://192.168.1.51 for Mainsail.")
                }
                discoverySection
            }
            .navigationTitle(existing == nil ? "Add printer" : "Edit printer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onDone(PrinterStore.Record(
                            name: name.trimmingCharacters(in: .whitespaces),
                            hostType: hostType,
                            url: Self.normalized(url),
                            webUI: Self.normalized(webUI),
                            apiKey: apiKey,
                            presetNames: existing?.presetNames ?? [defaultPreset]
                        ))
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
            .onChange(of: url) { _, value in
                if !value.isEmpty, !value.hasPrefix("http") { url = "http://\(value)" }
            }
            .onChange(of: hostType) { _, kind in
                // Desktop PhysicalPrinterDialog prefills each cloud host's
                // fixed service address; a URL the user typed themselves
                // is never overwritten.
                if url.isEmpty || Self.serviceHosts.values.contains(url) {
                    url = Self.serviceHosts[kind] ?? ""
                }
            }
            .onChange(of: webUI) { _, value in
                if !value.isEmpty, !value.hasPrefix("http") { webUI = "http://\(value)" }
            }
            .onAppear {
                if let existing {
                    name = existing.name
                    hostType = existing.hostType
                    url = existing.url
                    webUI = existing.webUI
                    apiKey = existing.apiKey
                }
            }
            .onDisappear {
                discovery.stop()
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: Bonjour discovery (board cycle-0.16)

    /// Scans _octoprint._tcp / _moonraker._tcp (_http._tcp fallback) while
    /// on; a tap resolves host+port and prefills the fields above (the
    /// suggestion also picks the host type for the printer services).
    private var discoverySection: some View {
        Section {
            Toggle("Browse the local network", isOn: Binding(
                get: { discovery.isBrowsing },
                set: { discovery.setBrowsing($0) }
            ))
            if discovery.isBrowsing && discovery.found.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Searching…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(discovery.found) { printer in
                Button {
                    discovery.resolve(printer, completion: applyDiscovery)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(printer.name)
                                .font(.callout)
                                .foregroundStyle(Color.primary)
                                .lineLimit(1)
                            Text(subtitle(for: printer))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if discovery.resolvingID == printer.id {
                            ProgressView()
                        } else if printer.resolvedURL != nil {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                }
                .disabled(discovery.resolvingID != nil)
            }
            if let failure = discovery.failureText {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Discovery")
        } footer: {
            Text("Scans for OctoPrint and Moonraker (Klipper) printers on this network; iOS asks for local-network permission on the first scan. Tapping a found printer fills in the host URL and type (web servers only fill the URL).")
        }
    }

    private func subtitle(for printer: PrinterDiscovery.FoundPrinter) -> String {
        if let resolved = printer.resolvedURL {
            return "\(printer.suggestion.label) · \(resolved)"
        }
        return printer.suggestion.label
    }

    /// Prefill from a resolved service (board cycle-0.16: "tap a found host
    /// to prefill URL + host type"). The host type goes first so its own
    /// cloud-prefill onChange cannot overwrite the resolved URL; a user-typed
    /// URL is replaced deliberately — the tap IS the intent.
    private func applyDiscovery(
        _ resolvedURL: String, suggestion: PrinterDiscovery.FoundPrinter.Suggestion
    ) {
        if let suggested = suggestion.hostType {
            hostType = suggested
        }
        url = resolvedURL
    }

    private static func normalized(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespaces)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }
}
