// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

import Foundation
import Observation
import OrcaBridge

/// Physical printers (desktop PhysicalPrinterCollection, engine-persisted)
/// and the Device tab's selection. Main-actor state owner: views borrow it,
/// engine calls cross the single `BackgroundWork` boundary.
@MainActor
@Observable
final class PrinterStore {
    typealias Record = EnginePresets.PhysicalPrinterRecord

    /// Why a printer's web interface cannot be shown (desktop
    /// PrintHost::get_print_host_webui yields no usable URL).
    enum WebUIError: LocalizedError, Equatable, Sendable {
        case noAddress(printer: String)
        case invalidURL(printer: String, value: String)

        var errorDescription: String? {
            switch self {
            case .noAddress(let printer):
                return "\(printer) has no host or device UI address."
            case .invalidURL(let printer, let value):
                return "\(printer): \"\(value)\" is not a valid web address."
            }
        }
    }

    private let status: StatusCenter
    private static let selectionKey = "device.selectedPrinter"

    private(set) var printers: [Record] = []
    private(set) var isLoaded = false
    private(set) var isSaving = false
    private(set) var selectedName: String?

    init(status: StatusCenter) {
        self.status = status
        selectedName = UserDefaults.standard.string(forKey: Self.selectionKey)
    }

    /// The printer the Device tab shows: the explicit choice when it still
    /// exists, else (desktop rule) the physical printer of the selected
    /// printer preset, else the first one.
    func selectedPrinter(machinePreset: String) -> Record? {
        if let selectedName, let chosen = printers.first(where: { $0.name == selectedName }) {
            return chosen
        }
        return printers.first { $0.presetNames.contains(machinePreset) } ?? printers.first
    }

    func select(_ name: String) {
        selectedName = name
        UserDefaults.standard.set(name, forKey: Self.selectionKey)
    }

    func reload(presets engine: EnginePresets) async {
        let result = await BackgroundWork.run(operation: "load physical printers") {
            try engine.physicalPrinters().get()
        }
        switch result {
        case .success(let records):
            printers = records
            isLoaded = true
        case .failure(let failure):
            status.report(.device, failure: failure)
        }
    }

    /// Creates or updates `record` (keyed by name). Returns whether the
    /// engine stored it.
    @discardableResult
    func save(_ record: Record, presets engine: EnginePresets) async -> Bool {
        guard !isSaving else {
            status.report(.device, "save printer blocked: another save is running")
            return false
        }
        isSaving = true
        let result = await BackgroundWork.run(operation: "save physical printer") {
            try engine.upsertPhysicalPrinter(
                name: record.name,
                hostType: record.hostType,
                url: record.url,
                webUI: record.webUI,
                apiKey: record.apiKey,
                presetName: record.presetNames.first ?? ""
            ).get()
        }
        isSaving = false
        switch result {
        case .success:
            select(record.name)
            await reload(presets: engine)
            status.report(.device, "\(record.name): saved")
            return true
        case .failure(let failure):
            status.report(.device, failure: failure)
            return false
        }
    }

    func delete(_ name: String, presets engine: EnginePresets) async {
        guard !isSaving else {
            status.report(.device, "delete printer blocked: another save is running")
            return
        }
        isSaving = true
        let result = await BackgroundWork.run(operation: "delete physical printer") {
            try engine.deletePhysicalPrinter(name: name).get()
        }
        isSaving = false
        switch result {
        case .success:
            await reload(presets: engine)
            status.report(.device, "\(name): deleted")
        case .failure(let failure):
            status.report(.device, failure: failure)
        }
    }

    /// Desktop `PrintHost::get_print_host_webui`: the device UI address when
    /// set, else the host address; a missing scheme means http.
    static func webUIURL(for printer: Record) -> Result<URL, WebUIError> {
        let webUI = printer.webUI.trimmingCharacters(in: .whitespaces)
        let host = printer.url.trimmingCharacters(in: .whitespaces)
        var address = webUI.isEmpty ? host : webUI
        guard !address.isEmpty else { return .failure(.noAddress(printer: printer.name)) }
        let lowered = address.lowercased()
        if !lowered.hasPrefix("http") && !lowered.hasPrefix("file:") {
            address = "http://" + address
        }
        guard let url = URL(string: address), url.host() != nil else {
            return .failure(.invalidURL(printer: printer.name, value: address))
        }
        return .success(url)
    }

    /// Desktop MainFrame::load_printer_url passes the API key only for
    /// PrusaLink / Prusa Connect.
    static func webUIRequest(for printer: Record, url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        if ["prusalink", "prusaconnect"].contains(printer.hostType), !printer.apiKey.isEmpty {
            request.setValue(printer.apiKey, forHTTPHeaderField: "X-Api-Key")
        }
        return request
    }
}
