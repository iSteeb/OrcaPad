import Foundation
import OrcaBridge
import Observation

/// Upload of sliced G-code to a printer host (desktop PrintHostDialog /
/// "Send" parity). The desktop implements the HTTP against each host with
/// libcurl inside its GUI layer (`src/slic3r/Utils/*PrintHost.cpp`); OrcaPad
/// mirrors that layering with URLSession. Only the two hosts OrcaPad can
/// reach natively are enabled; every other engine host type is a typed
/// rejection — no silent fallbacks.
@MainActor
@Observable
final class PrintHostService {
    enum UploadError: LocalizedError, Sendable {
        case unsupportedHost(String)
        case badURL(String)
        case http(status: Int, host: String)
        case transport(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedHost(let type):
                return "Print host type \"\(type)\" upload is not implemented on iOS yet (OctoPrint and Moonraker/Klipper are)."
            case .badURL(let url):
                return "Invalid print host URL: \(url)"
            case .http(let status, let host):
                return "\(host) rejected the upload (HTTP \(status))."
            case .transport(let message):
                return "Upload failed: \(message)"
            }
        }
    }

    /// A completed upload (shown by the send sheet).
    struct Receipt: Equatable, Sendable {
        let printer: String
        let file: String
        let startedPrint: Bool
    }

    private let status: StatusCenter
    private(set) var isUploading = false
    private(set) var lastReceipt: Receipt?

    init(status: StatusCenter) {
        self.status = status
    }

    /// Uploads `gcode` to `printer`. `startPrint` mirrors the desktop
    /// checkbox (select-and-print / Moonraker print flag).
    func upload(
        _ gcode: URL,
        to printer: EnginePresets.PhysicalPrinterRecord,
        startPrint: Bool
    ) async {
        guard !isUploading else {
            status.report(.device, "upload blocked: another upload is running")
            return
        }
        isUploading = true
        lastReceipt = nil
        defer { isUploading = false }
        do {
            // Reading a multi-megabyte G-code file must not block the main
            // actor; the request builder is pure and nonisolated.
            let request = try await Task.detached(priority: .userInitiated) {
                try Self.request(for: printer, file: gcode, startPrint: startPrint)
            }.value
            status.report(.device, "\(printer.name): uploading \(gcode.lastPathComponent)…")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                throw UploadError.http(status: http.statusCode, host: printer.hostType)
            }
            status.report(.device, "\(printer.name): upload complete")
            _ = data // OctoPrint/Moonraker return JSON status; nothing to show yet
            lastReceipt = Receipt(
                printer: printer.name, file: gcode.lastPathComponent, startedPrint: startPrint
            )
        } catch let error as UploadError {
            status.report(.device, failure: AppFailure.wrap(error, operation: "upload gcode"))
        } catch {
            status.report(.device, failure: AppFailure.wrap(error, operation: "upload gcode"))
        }
    }

    /// Desktop request shapes:
    /// - OctoPrint: `POST /api/files/local`, `X-Api-Key`, multipart fields
    ///   `select`/`print` (OctoPrint.cpp put).
    /// - Moonraker: `POST /server/files/upload`, multipart `print`
    ///   (Moonraker.cpp put).
    nonisolated private static func request(
        for printer: EnginePresets.PhysicalPrinterRecord,
        file: URL,
        startPrint: Bool
    ) throws -> URLRequest {
        guard let base = URL(string: printer.url), let scheme = base.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw UploadError.badURL(printer.url)
        }
        let boundary = "OrcaPad-\(UUID().uuidString)"
        func field(_ name: String, _ value: String) -> Data {
            Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8)
        }
        var body = Data()
        switch printer.hostType {
        case "octoprint":
            body.append(field("select", "true"))
            body.append(field("print", startPrint ? "true" : "false"))
        case "moonraker":
            body.append(field("root", "gcodes"))
            body.append(field("print", startPrint ? "true" : "false"))
        default:
            throw UploadError.unsupportedHost(printer.hostType)
        }
        let fileData: Data
        do {
            fileData = try Data(contentsOf: file)
        } catch {
            throw UploadError.transport("cannot read \(file.lastPathComponent)")
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(file.lastPathComponent)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(fileData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var url = base
        switch printer.hostType {
        case "octoprint": url.append(path: "api/files/local")
        case "moonraker": url.append(path: "server/files/upload")
        default: throw UploadError.unsupportedHost(printer.hostType)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if !printer.apiKey.isEmpty {
            request.setValue(printer.apiKey, forHTTPHeaderField: "X-Api-Key")
        }
        request.httpBody = body
        request.timeoutInterval = 120
        return request
    }
}
