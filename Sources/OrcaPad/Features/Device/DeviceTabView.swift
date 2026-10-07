import OrcaBridge
import SwiftUI

/// Device tab (desktop Monitor/PhysicalPrinterDialog parity, native
/// reimplementation): manage physical printers (engine-backed storage) and
/// send sliced G-code to OctoPrint/Moonraker hosts.
struct DeviceTabView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var printers: [EnginePresets.PhysicalPrinterRecord] = []
    @State private var editorPresented = false
    @State private var editing: EnginePresets.PhysicalPrinterRecord?
    @State private var startPrint = true

    private var presets: PresetStore { environment.presets }

    var body: some View {
        NavigationStack {
            Group {
                if printers.isEmpty {
                    ContentUnavailableView {
                        Label("No printers", systemImage: "printer")
                    } description: {
                        Text("Add a physical printer to send G-code straight from OrcaPad (OctoPrint, Moonraker/Klipper).")
                    } actions: {
                        Button("Add printer") {
                            editing = nil
                            editorPresented = true
                        }
                    }
                } else {
                    list
                }
            }
            .navigationTitle("Device")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        editing = nil
                        editorPresented = true
                    } label: {
                        Label("Add printer", systemImage: "plus")
                    }
                    .disabled(presets.isSelecting)
                }
            }
            .sheet(isPresented: $editorPresented) {
                PhysicalPrinterEditor(existing: editing) { record, delete in
                    Task { await apply(record, delete: delete) }
                }
            }
            .task(id: presets.isReady) { await reload() }
        }
    }

    private var list: some View {
        List {
            Section {
                ForEach(printers, id: \.name) { printer in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Label(printer.name, systemImage: iconName(printer.hostType))
                                .font(.headline)
                            Spacer()
                            Menu {
                                Button {
                                    editing = printer
                                    editorPresented = true
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                Button(role: .destructive) {
                                    Task {
                                        await apply(printer, delete: true)
                                    }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                        }
                        Text("\(Self.hostLabel(printer.hostType)) · \(printer.url)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(printer.presetNames.joined(separator: ", "))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        if let gcode = environment.slicing.lastOutcome?.outputURL {
                            Toggle("Start print after upload", isOn: $startPrint)
                                .font(.caption)
                            Button {
                                let upload = (gcode, printer, startPrint)
                                Task {
                                    await environment.printHost.upload(
                                        upload.0, to: upload.1, startPrint: upload.2
                                    )
                                }
                            } label: {
                                Label(
                                    "Send \(gcode.lastPathComponent)",
                                    systemImage: "paperplane"
                                )
                                .font(.subheadline.weight(.semibold))
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(environment.printHost.isUploading)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Physical printers")
            } footer: {
                if environment.slicing.lastOutcome == nil {
                    Text("Slice a plate first — its G-code can be sent to any printer here.")
                }
            }
        }
    }

    private func iconName(_ hostType: String) -> String {
        switch hostType {
        case "moonraker": return "antenna.radiowaves.left.and.right"
        case "octoprint": return "server.rack"
        default: return "printer"
        }
    }

    static func hostLabel(_ hostType: String) -> String {
        switch hostType {
        case "moonraker": return "Moonraker (Klipper)"
        case "octoprint": return "OctoPrint"
        default: return hostType
        }
    }

    private func reload() async {
        guard let engine = presets.engineForSlicing else { return }
        let result = await BackgroundWork.run(operation: "load physical printers") {
            try engine.physicalPrinters().get()
        }
        switch result {
        case .success(let records):
            printers = records
        case .failure(let failure):
            environment.status.report(.device, failure: failure)
        }
    }

    private func apply(
        _ record: EnginePresets.PhysicalPrinterRecord,
        delete: Bool
    ) async {
        guard let engine = presets.engineForSlicing else {
            environment.status.report(.device, "presets are not loaded")
            return
        }
        let result = await BackgroundWork.run(operation: "save physical printer") {
            if delete {
                return try engine.deletePhysicalPrinter(name: record.name).get()
            }
            return try engine.upsertPhysicalPrinter(
                name: record.name,
                hostType: record.hostType,
                url: record.url,
                apiKey: record.apiKey,
                presetName: record.presetNames.first ?? presets.selection.machine
            ).get()
        }
        switch result {
        case .success:
            await reload()
        case .failure(let failure):
            environment.status.report(.device, failure: failure)
        }
    }
}

/// Desktop PhysicalPrinterDialog: name, host type, URL, API key.
private struct PhysicalPrinterEditor: View {
    let existing: EnginePresets.PhysicalPrinterRecord?
    let onDone: (EnginePresets.PhysicalPrinterRecord, _ delete: Bool) -> Void

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var hostType = "octoprint"
    @State private var url = ""
    @State private var apiKey = ""

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
            (url.hasPrefix("http://") || url.hasPrefix("https://"))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Printer") {
                    TextField("Name", text: $name)
                        .autocorrectionDisabled()
                    Picker("Host type", selection: $hostType) {
                        Text("OctoPrint").tag("octoprint")
                        Text("Moonraker (Klipper)").tag("moonraker")
                    }
                }
                Section {
                    TextField("URL", text: $url)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: url) { _, value in
                            if !value.hasPrefix("http") { url = "http://\(value)" }
                        }
                    SecureField("API key (optional)", text: $apiKey)
                } header: {
                    Text("Connection")
                } footer: {
                    Text("Example: http://192.168.1.50 (OctoPrint) or http://192.168.1.51 (Moonraker).")
                }
            }
            .navigationTitle(existing == nil ? "Add printer" : "Edit printer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onDone(EnginePresets.PhysicalPrinterRecord(
                            name: name.trimmingCharacters(in: .whitespaces),
                            hostType: hostType,
                            url: url,
                            apiKey: apiKey,
                            presetNames: [environment.presets.selection.machine]
                        ), false)
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
            .onAppear {
                if let existing {
                    name = existing.name
                    hostType = existing.hostType == "moonraker" ? "moonraker" : "octoprint"
                    url = existing.url
                    apiKey = existing.apiKey
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
