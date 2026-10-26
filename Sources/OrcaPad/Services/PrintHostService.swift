// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

import Foundation
import OrcaBridge
import Observation

/// Upload of sliced G-code to a printer host (desktop PrintHostDialog /
/// "Send" parity). The desktop implements the HTTP against each host with
/// libcurl inside its GUI layer (`src/slic3r/Utils/*PrintHost.cpp`); OrcaPad
/// mirrors that layering with URLSession. Every engine host type has a
/// native upload path (LAN HTTP or cloud REST); any other host string
/// stays a typed rejection — no silent fallbacks.
@MainActor
@Observable
final class PrintHostService {
    enum UploadError: LocalizedError, Sendable {
        case unsupportedHost(String)
        case badURL(String)
        case http(status: Int, host: String)
        case rejected(String)
        case transport(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedHost(let type):
                return "Print host type \"\(type)\" upload is not implemented on iOS."
            case .badURL(let url):
                return "Invalid print host URL: \(url)"
            case .http(let status, let host):
                return "\(host) rejected the upload (HTTP \(status))."
            case .rejected(let message):
                return message
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

    /// Digest credentials for PrusaLink (user "maker", the printer's API
    /// key as the password) — carried per upload, never in static state.
    private struct DigestCredentials: Sendable {
        let user: String
        let password: String
    }

    /// Everything one upload needs beyond its main request: the desktop
    /// hosts' surrounding calls (FlashAir prepare/setdir, Duet start-print)
    /// and optional digest credentials. Per-invocation by construction —
    /// a failed upload can never leak requests into the next one (the old
    /// static storage executed a stale Duet start command against the old
    /// host during an unrelated later upload).
    private struct UploadPlan: Sendable {
        let request: URLRequest
        let preRequests: [URLRequest]
        /// Commands run AFTER a successful upload (select/start-print);
        /// ordered. Generalizes the old single Duet start request.
        let startRequests: [URLRequest]
        let digest: DigestCredentials?
        /// Body semantics of hosts that answer inside an HTTP-200 body
        /// (cloud API result codes, follow-up links); nil = plain host.
        let bodyCheck: BodyCheck?
        /// True when the host has NO REST start call (SimplyPrint,
        /// 3DPrinterOS): the completion note replaces a false "print is
        /// starting" claim in the receipt.
        let noRemoteStart: Bool

        init(request: URLRequest, preRequests: [URLRequest], startRequests: [URLRequest],
             digest: DigestCredentials?, bodyCheck: BodyCheck? = nil,
             noRemoteStart: Bool = false) {
            self.request = request
            self.preRequests = preRequests
            self.startRequests = startRequests
            self.digest = digest
            self.bodyCheck = bodyCheck
            self.noRemoteStart = noRemoteStart
        }
    }

    /// Post-upload body semantics of hosts whose API answers inside an
    /// HTTP-200 body (the desktop host .cpp parses these in `on_complete`):
    /// a rejecting body surfaces as a typed failure instead of a silent
    /// success, and cloud hosts without a REST start produce the web-panel
    /// note (the desktop opens these URLs in a browser).
    private enum BodyCheck: Sendable {
        /// Flashforge local API: JSON `code`/`err` must be 0 when present
        /// (validate_local_api_response, Flashforge.cpp:156-186).
        case flashforgeLocalAPI
        /// SimplyPrint TempUpload: JSON `uuid`; the temp file only becomes
        /// printable by importing it in the panel (do_temp_upload,
        /// SimplyPrint.cpp:293-330) — no REST start exists.
        case simplyPrintTempUpload(filename: String)
        /// 3DPrinterOS upload: JSON `message.file_id`; printing starts in
        /// the web app only (quickprint?file_id=, 3DPrinterOS.cpp:501).
        case printerOSUpload(base: URL)

        /// Validates the body; returns the completion note when the host
        /// needs one (nil = nothing to report).
        func check(_ body: Data, startPrint: Bool) throws -> String? {
            switch self {
            case .flashforgeLocalAPI:
                try Self.checkFlashforge(body)
                return nil
            case .simplyPrintTempUpload(let filename):
                return try Self.noteSimplyPrint(body, filename: filename)
            case .printerOSUpload(let base):
                return try Self.notePrinterOS(body, base: base, startPrint: startPrint)
            }
        }

        private static func object(_ body: Data) throws -> [String: Any] {
            let parsed: Any
            do {
                parsed = try JSONSerialization.jsonObject(with: body)
            } catch {
                throw UploadError.transport(
                    "host answered with invalid JSON: \(error.localizedDescription)")
            }
            guard let dictionary = parsed as? [String: Any] else {
                throw UploadError.transport("host answered with unexpected JSON")
            }
            return dictionary
        }

        private static func checkFlashforge(_ body: Data) throws {
            let dictionary = try object(body)
            // `code` first, `err` as its alias (156-186); only a non-zero
            // value is a failure — a body without either means success,
            // exactly like the desktop check.
            let code = (dictionary["code"] as? Int) ?? (dictionary["err"] as? Int)
            if let code, code != 0 {
                let message = (dictionary["message"] as? String)
                    ?? (dictionary["msg"] as? String)
                    ?? "request failed"
                throw UploadError.rejected("Flashforge local API error \(code): \(message)")
            }
        }

        private static func noteSimplyPrint(_ body: Data, filename: String) throws -> String {
            let dictionary = try object(body)
            guard let uuid = dictionary["uuid"] as? String else {
                throw UploadError.rejected("SimplyPrint did not return the temp-file id.")
            }
            // do_temp_upload opens this panel link in a browser; the temp
            // file is unreachable without it, so the note carries it.
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            let encodedName = filename.addingPercentEncoding(withAllowedCharacters: allowed)
                ?? filename
            return "SimplyPrint: open https://simplyprint.io/panel?import=tmp:\(uuid)"
                + "&filename=\(encodedName) to import the file and start the print."
        }

        private static func notePrinterOS(
            _ body: Data, base: URL, startPrint: Bool
        ) throws -> String {
            let dictionary = try object(body)
            // on_complete (460-478): `result` + `message.file_id` on
            // success; `message` as plain text on failure.
            var fileID: String?
            if let fileMessage = dictionary["message"] as? [String: Any] {
                if let id = fileMessage["file_id"] as? String {
                    fileID = id
                } else if let id = fileMessage["file_id"] as? Int {
                    fileID = String(id)
                }
            }
            guard (dictionary["result"] as? Bool) == true, let fileID else {
                let reason = (dictionary["message"] as? String) ?? "no file id in the response"
                throw UploadError.rejected("3DPrinterOS rejected the upload: \(reason).")
            }
            var quickPrint = base
            quickPrint.append(path: "quickprint")
            quickPrint.append(queryItems: [URLQueryItem(name: "file_id", value: fileID)])
            return startPrint
                ? "3DPrinterOS: open \(quickPrint.absoluteString) to start the print."
                : "3DPrinterOS: file uploaded as \(fileID)."
        }
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
            let plan = try await Task.detached(priority: .userInitiated) {
                try Self.request(for: printer, file: gcode, startPrint: startPrint)
            }.value
            let session: URLSession
            if let digest = plan.digest {
                session = Self.digestSession(user: digest.user, password: digest.password)
            } else {
                session = .shared
            }
            // A session built for this upload is torn down when it ends —
            // credentials and connections never outlive the request.
            let createdSession = plan.digest != nil ? session : nil
            defer { createdSession?.finishTasksAndInvalidate() }
            status.report(.device, "\(printer.name): uploading \(gcode.lastPathComponent)…")
            // Desktop multi-step hosts: FlashAir prepares the card/dir
            // first (FlashAir.cpp), Duet starts the print after the upload
            // (Duet.cpp rr_gcode). Both steps surface failures loudly.
            for pre in plan.preRequests {
                let (_, preResponse) = try await session.data(for: pre)
                if let http = preResponse as? HTTPURLResponse,
                   !(200..<300).contains(http.statusCode) {
                    throw UploadError.http(status: http.statusCode, host: printer.hostType)
                }
            }
            let (data, response) = try await session.data(for: plan.request)
            if let http = response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                throw UploadError.http(status: http.statusCode, host: printer.hostType)
            }
            // Some hosts answer inside an HTTP-200 body (the desktop parses
            // these in the host .cpp on_complete): validate loudly and pick
            // up the web-only follow-up link.
            var completionNote: String?
            if let bodyCheck = plan.bodyCheck {
                completionNote = try bodyCheck.check(data, startPrint: startPrint)
            }
            if printer.hostType == "prusalink", startPrint {
                // PrusaLink start (OctoPrint.cpp select command):
                // PUT /api/files/local/<file> {"command":"select","print":true}
                var select = plan.request.url!
                select.append(path: "local/\(gcode.lastPathComponent)")
                var selectRequest = URLRequest(url: select)
                selectRequest.httpMethod = "PUT"
                selectRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                selectRequest.httpBody = Data(#"{"command":"select","print":true}"#.utf8)
                let (_, selectResponse) = try await session.data(for: selectRequest)
                if let http = selectResponse as? HTTPURLResponse,
                   !(200..<300).contains(http.statusCode) {
                    throw UploadError.http(status: http.statusCode, host: printer.hostType)
                }
            }
            for start in plan.startRequests {
                let (_, startResponse) = try await session.data(for: start)
                if let http = startResponse as? HTTPURLResponse,
                   !(200..<300).contains(http.statusCode) {
                    // The FILE is uploaded; only the start command failed.
                    throw UploadError.http(status: http.statusCode, host: printer.hostType)
                }
            }
            status.report(.device, "\(printer.name): upload complete")
            // Hosts without a REST start (SimplyPrint, 3DPrinterOS) finish
            // in their web panel: report the link instead of pretending
            // the print started.
            if let completionNote {
                status.report(.device, completionNote)
            }
            lastReceipt = Receipt(
                printer: printer.name,
                file: gcode.lastPathComponent,
                startedPrint: startPrint && !plan.noRemoteStart
            )
        } catch let error as UploadError {
            status.report(.device, failure: AppFailure.wrap(error, operation: "upload gcode"))
        } catch {
            status.report(.device, failure: AppFailure.wrap(error, operation: "upload gcode"))
        }
    }

    /// Desktop request shapes (slic3r/Utils/*.cpp):
    /// - OctoPrint: `POST /api/files/local`, `X-Api-Key`, multipart fields
    ///   `select`/`print` (OctoPrint.cpp put).
    /// - Moonraker: `POST /server/files/upload`, multipart `print`
    ///   (Moonraker.cpp put).
    /// - Duet (RepRapFirmware): `POST /rr_upload?name=0:/gcodes/<file>`
    ///   with the raw file body; start = `POST /rr_gcode?gcode=M32...`
    ///   (Duet.cpp put).
    /// - FlashAir: the three upload.cgi calls — WRITEPROTECT=ON&FTIME,
    ///   UPDIR, then the multipart upload (FlashAir.cpp put).
    nonisolated private static func request(
        for printer: EnginePresets.PhysicalPrinterRecord,
        file: URL,
        startPrint: Bool
    ) throws -> UploadPlan {
        guard let base = URL(string: printer.url), let scheme = base.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw UploadError.badURL(printer.url)
        }

        // Raw-body hosts (Duet): plain file POST, no multipart.
        if printer.hostType == "duet" {
            let fileData: Data
            do {
                fileData = try Data(contentsOf: file)
            } catch {
                throw UploadError.transport("cannot read \(file.lastPathComponent)")
            }
            var url = base
            url.append(path: "rr_upload")
            // Duet.cpp: name=0:/gcodes/<file>&<timestamp>
            url.append(
                queryItems: [
                    URLQueryItem(
                        name: "name",
                        value: "0:/gcodes/" + file.lastPathComponent
                    ),
                    URLQueryItem(name: "time", value: String(Int(Date().timeIntervalSince1970))),
                ]
            )
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = fileData
            request.timeoutInterval = 120
            // Desktop sends the start command as a second request after a
            // successful upload; carried on the plan, never in statics.
            return UploadPlan(
                request: request,
                preRequests: [],
                startRequests: startPrint
                    ? [Self.duetStart(base: base, file: file.lastPathComponent)] : [],
                digest: nil
            )
        }

        var digest: DigestCredentials?
        if printer.hostType == "prusalink" {
            // PrusaLink (PrusaLink.cpp): OctoPrint-shaped multipart POST to
            // api/files/local over HTTP DIGEST auth (user "maker", the
            // printer's API key as the password).
            digest = DigestCredentials(user: "maker", password: printer.apiKey)
        }

        // --- Simple LAN hosts (upstream Repetier/AstroBox/MKS/ESP3D/
        // CrealityPrint/ElegooLink .cpp request shapes) ---
        if let plan = try lanHostPlan(printer: printer, file: file, startPrint: startPrint) {
            return plan
        }

        var preRequests: [URLRequest] = []
        if printer.hostType == "flashair" {
            // FlashAir.cpp: prepare (WRITEPROTECT=ON&FTIME), set dir, upload.
            let timestamp = String(Int(Date().timeIntervalSince1970))
            var prepare = base
            prepare.append(path: "upload.cgi")
            prepare.append(queryItems: [
                URLQueryItem(name: "WRITEPROTECT", value: "ON"),
                URLQueryItem(name: "FTIME", value: timestamp),
            ])
            var setDir = base
            setDir.append(path: "upload.cgi")
            setDir.append(queryItems: [URLQueryItem(name: "UPDIR", value: "/gcodes")])
            preRequests = [prepare, setDir].map { url in
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.timeoutInterval = 30
                return request
            }
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
        case "prusalink", "flashair":
            break  // raw multipart file only
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
        case "octoprint", "prusalink": url.append(path: "api/files/local")
        case "moonraker": url.append(path: "server/files/upload")
        case "flashair": url.append(path: "upload.cgi")
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
        return UploadPlan(
            request: request,
            preRequests: preRequests,
            startRequests: [],
            digest: digest
        )
    }

    /// The simple one-request hosts, as one shape table (upstream .cpp
    /// parity) — six LAN hosts, Flashforge's local HTTP API, and the four
    /// cloud services:
    /// - Repetier: POST /printer/model/default, a=upload multipart, X-Api-Key
    /// - AstroBox: POST api/files/local, print+path+file multipart, X-Api-Key
    /// - MKS: POST /upload?X-Filename=<urlenc> RAW body (no multipart)
    /// - ESP3D: POST /upload_serial multipart "file"; start = GET
    ///   /command?plain=M23%20<file> then M24
    /// - Creality Print (LAN): POST /upload/<urlenc> Bearer auth, file
    ///   multipart (path field when not multi-color)
    /// - ElegooLink (legacy): POST uploadFile/upload, "File" multipart with
    ///   an explicit Host header
    /// - Flashforge (HTTP mode): POST :8898/uploadGcode, "gcodeFile"
    ///   multipart, serialNumber/checkCode/printNow headers (printNow IS
    ///   the start flag; no second call)
    /// - Obico: POST api/v1/g_code_files/ (Bearer), print+path+filename+file
    ///   multipart; GET api/v1/version/ preflight (Obico.cpp upload)
    /// - PrusaConnect: POST api/files/local (X-Api-Key), path+to_print
    ///   multipart ("True" — Connect spelling) + Accept-Language
    ///   (OctoPrint.cpp PrusaConnect::set_http_post_header_args)
    /// - SimplyPrint: POST simplyprint.io/api/files/TempUpload (Bearer) —
    ///   temp file; importing/queueing is web-only (no REST start)
    /// - 3DPrinterOS: POST apiglobal/upload multipart session token; the
    ///   print starts on the web only (quickprint?file_id=)
    nonisolated private static func lanHostPlan(
        printer: EnginePresets.PhysicalPrinterRecord,
        file: URL,
        startPrint: Bool
    ) throws -> UploadPlan? {
        let fileData: Data
        do {
            fileData = try Data(contentsOf: file)
        } catch {
            throw UploadError.transport("cannot read \(file.lastPathComponent)")
        }
        func formBody(_ boundary: String, fields: [(String, String)], fileName: String,
                      fieldName: String, contentType: String = "application/octet-stream") -> Data {
            var body = Data()
            for (name, value) in fields {
                body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
            }
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(fileName)\"\r\nContent-Type: \(contentType)\r\n\r\n".utf8))
            body.append(fileData)
            body.append(Data("\r\n--\(boundary)--\r\n".utf8))
            return body
        }
        func post(_ url: URL, body: Data, timeout: TimeInterval = 120) -> URLRequest {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = body
            request.timeoutInterval = timeout
            return request
        }
        let boundary = "OrcaPad-\(UUID().uuidString)"

        switch printer.hostType {
        case "repetier":
            var url = try base(printer)
            url.append(path: "printer/model/default")
            var fields = [("a", "upload")]
            if startPrint {
                fields.append(("name", file.lastPathComponent))
                fields.append(("autostart", "true"))
            }
            var request = post(
                url, body: formBody(boundary, fields: fields,
                                    fileName: file.lastPathComponent, fieldName: "filename"))
            if !printer.apiKey.isEmpty {
                request.setValue(printer.apiKey, forHTTPHeaderField: "X-Api-Key")
            }
            request.setValue("multipart/form-data; boundary=\(boundary)",
                             forHTTPHeaderField: "Content-Type")
            return UploadPlan(request: request, preRequests: [], startRequests: [], digest: nil)
        case "astrobox":
            var url = try base(printer)
            url.append(path: "api/files/local")
            var request = post(
                url, body: formBody(
                    boundary,
                    fields: [("print", startPrint ? "true" : "false"), ("path", "")],
                    fileName: file.lastPathComponent, fieldName: "file"))
            if !printer.apiKey.isEmpty {
                request.setValue(printer.apiKey, forHTTPHeaderField: "X-Api-Key")
            }
            request.setValue("multipart/form-data; boundary=\(boundary)",
                             forHTTPHeaderField: "Content-Type")
            return UploadPlan(request: request, preRequests: [], startRequests: [], digest: nil)
        case "mks":
            // MKS wants the RAW file body with the name in a query header.
            var url = try base(printer)
            url.append(path: "upload")
            url.append(queryItems: [
                URLQueryItem(name: "X-Filename", value: file.lastPathComponent),
            ])
            var request = post(url, body: fileData)
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            // Start-print is the M23/M24 console protocol over raw TCP —
            // shipped with the Flashforge socket work (device.sockets).
            return UploadPlan(request: request, preRequests: [], startRequests: [], digest: nil)
        case "esp3d":
            var url = try base(printer)
            url.append(path: "upload_serial")
            var request = post(
                url, body: formBody(boundary, fields: [],
                                    fileName: file.lastPathComponent, fieldName: "file"))
            request.setValue("keep-alive", forHTTPHeaderField: "Connection")
            request.setValue("multipart/form-data; boundary=\(boundary)",
                             forHTTPHeaderField: "Content-Type")
            var starts: [URLRequest] = []
            if startPrint {
                // ESP3D.cpp start_print: M23 then M24 via /command?plain=
                for command in ["M23 \(file.lastPathComponent)", "M24"] {
                    var select = try base(printer)
                    select.append(path: "command")
                    let encoded = command
                        .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? command
                    select.append(queryItems: [
                        URLQueryItem(name: "plain", value: encoded),
                    ])
                    var getRequest = URLRequest(url: select)
                    getRequest.httpMethod = "GET"
                    getRequest.timeoutInterval = 30
                    starts.append(getRequest)
                }
            }
            return UploadPlan(request: request, preRequests: [], startRequests: starts, digest: nil)
        case "crealityprint":
            var url = try base(printer)
            let safeName = file.lastPathComponent.replacingOccurrences(of: " ", with: "_")
            url.append(path: "upload/\(safeName)")
            var request = post(
                url, body: formBody(boundary, fields: [("path", "")],
                                    fileName: safeName, fieldName: "file"))
            if !printer.apiKey.isEmpty {
                request.setValue("Bearer \(printer.apiKey)", forHTTPHeaderField: "Authorization")
            }
            request.setValue("multipart/form-data; boundary=\(boundary)",
                             forHTTPHeaderField: "Content-Type")
            return UploadPlan(request: request, preRequests: [], startRequests: [], digest: nil)
        case "elegoolink":
            var url = try base(printer)
            url.append(path: "uploadFile/upload")
            var request = post(
                url, body: formBody(boundary, fields: [],
                                    fileName: file.lastPathComponent, fieldName: "File"))
            if let host = url.host {
                var hostValue = host
                if let port = url.port { hostValue += ":\(port)" }
                request.setValue(hostValue, forHTTPHeaderField: "Host")
                request.setValue("application/json, text/plain, */*",
                                 forHTTPHeaderField: "Accept")
            }
            request.setValue("multipart/form-data; boundary=\(boundary)",
                             forHTTPHeaderField: "Content-Type")
            return UploadPlan(request: request, preRequests: [], startRequests: [], digest: nil)
        case "flashforge":
            // Flashforge.cpp upload_local_api (572-601): the printer's local
            // HTTP API — always port 8898 (make_http_url 640-643 rebuilds
            // scheme/port from the print host), multipart field `gcodeFile`,
            // credentials + start flag as HEADERS (583-593): printNow is
            // the start command, there is no second call. OrcaPad's single
            // API-key field carries the desktop's two keys
            // (flashforge_serial_number + printhost_apikey, ctor 210-217)
            // as "serial:checkCode", or the same value in both.
            guard let host = try base(printer).host() else {
                throw UploadError.badURL(printer.url)
            }
            var api = URLComponents()
            api.scheme = "http"
            api.host = host
            api.port = 8898
            guard var url = api.url else { throw UploadError.badURL(printer.url) }
            url.append(path: "uploadGcode")
            // sanitize_flashforge_filename (189-206): the local API only
            // accepts [A-Za-z0-9._-].
            let safeName = Self.flashforgeSafeName(file.lastPathComponent)
            var request = post(
                url, body: formBody(boundary, fields: [],
                                    fileName: safeName, fieldName: "gcodeFile"))
            let credentials = Self.flashforgeCredentials(printer.apiKey)
            request.setValue(credentials.serial, forHTTPHeaderField: "serialNumber")
            request.setValue(credentials.code, forHTTPHeaderField: "checkCode")
            request.setValue(String(fileData.count), forHTTPHeaderField: "fileSize")
            request.setValue(startPrint ? "true" : "false", forHTTPHeaderField: "printNow")
            // Desktop defaults for the optional print-quality headers
            // (583-593): leveling/calibration/timelapse off, one toolhead,
            // empty material mapping (base64 "[]").
            request.setValue("false", forHTTPHeaderField: "levelingBeforePrint")
            request.setValue("false", forHTTPHeaderField: "flowCalibration")
            request.setValue("false", forHTTPHeaderField: "firstLayerInspection")
            request.setValue("false", forHTTPHeaderField: "timeLapseVideo")
            request.setValue("false", forHTTPHeaderField: "useMatlStation")
            request.setValue("1", forHTTPHeaderField: "gcodeToolCnt")
            request.setValue("W10=", forHTTPHeaderField: "materialMappings")
            request.setValue("multipart/form-data; boundary=\(boundary)",
                             forHTTPHeaderField: "Content-Type")
            return UploadPlan(
                request: request, preRequests: [], startRequests: [], digest: nil,
                bodyCheck: .flashforgeLocalAPI)
        case "obico":
            // Obico.cpp upload (163-185): test() gates the upload (GET
            // api/v1/version/, 63-97), then ONE multipart POST carries the
            // file and the start flag (field `print`; no second call).
            // Desktop picks the printer via printhost_port (printer_id,
            // 99-148); OrcaPad has no such field, so printer_id is omitted
            // and Obico applies the account's default printer.
            var preflightURL = try base(printer)
            preflightURL.append(path: "api/v1/version/")
            var preflight = URLRequest(url: preflightURL)
            preflight.httpMethod = "GET"
            preflight.timeoutInterval = 30
            var url = try base(printer)
            url.append(path: "api/v1/g_code_files/")
            var request = post(
                url, body: formBody(
                    boundary,
                    fields: [
                        ("print", startPrint ? "true" : "false"),
                        ("path", ""),
                        ("filename", file.lastPathComponent),
                    ],
                    fileName: file.lastPathComponent, fieldName: "file"))
            if !printer.apiKey.isEmpty {
                // set_auth (47-52): every call carries the Bearer token.
                let bearer = "Bearer \(printer.apiKey)"
                request.setValue(bearer, forHTTPHeaderField: "Authorization")
                preflight.setValue(bearer, forHTTPHeaderField: "Authorization")
            }
            request.setValue("multipart/form-data; boundary=\(boundary)",
                             forHTTPHeaderField: "Content-Type")
            return UploadPlan(
                request: request, preRequests: [preflight], startRequests: [], digest: nil)
        case "prusaconnect":
            // OctoPrint.cpp PrusaConnect (543-551,
            // set_http_post_header_args 1131-1142): OctoPrint-shaped POST
            // api/files/local with the Connect token (X-Api-Key); the start
            // flag is the `to_print` FORM field ("True" — Connect
            // spelling), plus the 2-letter Accept-Language header.
            var url = try base(printer)
            url.append(path: "api/files/local")
            var fields = [("path", "")]
            if startPrint { fields.append(("to_print", "True")) }
            var request = post(
                url, body: formBody(boundary, fields: fields,
                                    fileName: file.lastPathComponent, fieldName: "file"))
            if !printer.apiKey.isEmpty {
                request.setValue(printer.apiKey, forHTTPHeaderField: "X-Api-Key")
            }
            if let code = Locale.current.language.languageCode?.identifier,
               code.count >= 2 {
                request.setValue(String(code.prefix(2)), forHTTPHeaderField: "Accept-Language")
            }
            request.setValue("multipart/form-data; boundary=\(boundary)",
                             forHTTPHeaderField: "Content-Type")
            return UploadPlan(request: request, preRequests: [], startRequests: [], digest: nil)
        case "simplyprint":
            // SimplyPrint.cpp do_temp_upload (293-318): TempUpload to the
            // FIXED simplyprint.io base (URL_BASE_HOME, 25-26 — the printer
            // URL is never the API endpoint). The desktop's OAuth flow is
            // not on iOS: the access token from the SimplyPrint dashboard
            // is pasted as the API key (all calls send Bearer, 88).
            // Importing and queueing the temp file is web-only (322-330) —
            // no REST start exists.
            guard let url = URL(string: "https://simplyprint.io/api/files/TempUpload") else {
                throw UploadError.badURL("https://simplyprint.io/api/files/TempUpload")
            }
            var request = post(
                url, body: formBody(boundary, fields: [],
                                    fileName: file.lastPathComponent, fieldName: "file"))
            if !printer.apiKey.isEmpty {
                request.setValue("Bearer \(printer.apiKey)", forHTTPHeaderField: "Authorization")
            }
            request.setValue("multipart/form-data; boundary=\(boundary)",
                             forHTTPHeaderField: "Content-Type")
            return UploadPlan(
                request: request, preRequests: [], startRequests: [], digest: nil,
                bodyCheck: .simplyPrintTempUpload(filename: file.lastPathComponent),
                noRemoteStart: true)
        case "3dprinteros":
            // 3DPrinterOS.cpp upload (436-466): multipart session-token
            // upload (project picked on the web side when not sent);
            // printing starts in the web app only (quickprint?file_id=,
            // 501) — no REST start.
            var url = try base(printer)
            url.append(path: "apiglobal/upload")
            var request = post(
                url, body: formBody(
                    boundary,
                    fields: [
                        ("session", printer.apiKey),
                        ("upload_type_id", "7"),
                        ("upload_soft_name", "OrcaPad"),
                        ("zip", "false"),
                    ],
                    fileName: file.lastPathComponent, fieldName: "file"))
            request.setValue("multipart/form-data; boundary=\(boundary)",
                             forHTTPHeaderField: "Content-Type")
            return UploadPlan(
                request: request, preRequests: [], startRequests: [], digest: nil,
                bodyCheck: .printerOSUpload(base: try base(printer)),
                noRemoteStart: true)
        default:
            return nil
        }
    }

    /// The printer's base URL (validated http/https).
    nonisolated private static func base(
        _ printer: EnginePresets.PhysicalPrinterRecord
    ) throws -> URL {
        guard let url = URL(string: printer.url),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw UploadError.badURL(printer.url)
        }
        return url
    }

    /// The Flashforge local API wants BOTH the printer's serial number and
    /// its access code as separate headers (desktop config keys
    /// flashforge_serial_number + printhost_apikey, Flashforge.cpp ctor
    /// 210-217). OrcaPad has one API-key field: "serial:code" when it
    /// contains a colon, else the same value fills both.
    nonisolated private static func flashforgeCredentials(
        _ apiKey: String
    ) -> (serial: String, code: String) {
        guard let separator = apiKey.firstIndex(of: ":") else {
            return (serial: apiKey, code: apiKey)
        }
        return (
            serial: String(apiKey[..<separator]),
            code: String(apiKey[apiKey.index(after: separator)...])
        )
    }

    /// sanitize_flashforge_filename (Flashforge.cpp:189-206): the local
    /// API rejects filenames outside [A-Za-z0-9._-]; offending characters
    /// become underscores.
    nonisolated private static func flashforgeSafeName(_ name: String) -> String {
        String(name.map { character in
            let allowed = character == "." || character == "_" || character == "-"
                || (character.isASCII && (character.isLetter || character.isNumber))
            return allowed ? character : "_"
        })
    }

    /// Session whose delegate answers HTTP digest challenges (PrusaLink).
    /// Built per upload with that upload's credentials — no shared
    /// mutable auth state outlives the request.
    private static func digestSession(user: String, password: String) -> URLSession {
        final class DigestDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
            let user: String
            let password: String
            init(user: String, password: String) {
                self.user = user
                self.password = password
            }
            func urlSession(
                _ session: URLSession,
                didReceive challenge: URLAuthenticationChallenge
            ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
                guard challenge.protectionSpace.authenticationMethod ==
                        NSURLAuthenticationMethodHTTPDigest,
                      let prior = challenge.proposedCredential,
                      prior.user != nil  // answering once; URLSession loops otherwise
                else {
                    return (.performDefaultHandling, nil)
                }
                return (.useCredential, URLCredential(user: user, password: password, persistence: .none))
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        return URLSession(configuration: configuration, delegate: DigestDelegate(user: user, password: password), delegateQueue: nil)
    }

    private nonisolated static func duetStart(base: URL, file: String) -> URLRequest {
        var url = base
        url.append(path: "rr_gcode")
        url.append(queryItems: [
            URLQueryItem(name: "gcode", value: "M32 \"0:/gcodes/\(file)\"")
        ])
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        return request
    }
}
