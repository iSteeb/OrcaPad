// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

import AuthenticationServices
import CryptoKit
import Foundation
import Network
import OrcaBridge
import Observation
import Security
import UIKit
import os

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
        /// Raw TCP console failure (MKS M23/M24 start): the file IS uploaded,
        /// only the start command failed (same semantics as a failed Duet
        /// start request).
        case console(String)

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
            case .console(let message):
                return "Upload succeeded but the start command failed: \(message)"
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

    // MARK: Upload queue (board cycle-0.16)

    /// One queued send (desktop has no queue; OrcaPad batches multi-file
    /// sends and repeated "send later" picks into a sequential list — the
    /// one-at-a-time rule the single upload already enforces, made visible).
    struct QueuedUpload: Identifiable, Equatable, Sendable {
        enum Phase: Equatable, Sendable {
            case waiting
            case running
            case done
            case cancelled
            case failed(String)
        }

        let id: UUID
        let file: URL
        let printer: EnginePresets.PhysicalPrinterRecord
        let startPrint: Bool
        var phase: Phase = .waiting

        var isFinished: Bool {
            switch phase {
            case .waiting, .running: return false
            case .done, .cancelled, .failed: return true
            }
        }

        var statusText: String {
            switch phase {
            case .waiting: return "waiting"
            case .running: return "uploading…"
            case .done: return "sent"
            case .cancelled: return "skipped"
            case .failed(let message): return message
            }
        }
    }

    /// Queue order is execution order; items are appended and consumed
    /// front-first, never reordered behind the user's back.
    private(set) var queue: [QueuedUpload] = []
    /// The sequential consumer. Non-nil while an item is executing or is
    /// about to be; `isUploading` stays true across the whole drain so a
    /// direct Send can never interleave with a queued item.
    private var pumpTask: Task<Void, Never>?

    /// Result of one upload attempt — shared by the direct send and the
    /// queue so both report and receipt identically.
    private enum UploadOutcome: Sendable {
        case success(Receipt)
        case cancelled
        case failure(AppFailure)
    }

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

        /// What a validated body reports back to the upload flow.
        struct Outcome: Sendable {
            /// Status-line note when the host needs one (nil = nothing).
            let note: String?
            /// A URL the DESKTOP opens in the system browser
            /// (wxLaunchDefaultBrowser); OrcaPad opens it through
            /// UIApplication (nil = none).
            let launchURL: URL?
        }

        /// Validates the body; returns what the host still needs from the
        /// user (nil note and nil URL = nothing to report).
        func check(_ body: Data, startPrint: Bool) throws -> Outcome {
            switch self {
            case .flashforgeLocalAPI:
                try Self.checkFlashforge(body)
                return Outcome(note: nil, launchURL: nil)
            case .simplyPrintTempUpload(let filename):
                return try Self.outcomeSimplyPrint(
                    body, filename: filename, startPrint: startPrint)
            case .printerOSUpload(let base):
                return try Self.outcomePrinterOS(body, base: base, startPrint: startPrint)
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

        private static func outcomeSimplyPrint(
            _ body: Data, filename: String, startPrint: Bool
        ) throws -> Outcome {
            let dictionary = try object(body)
            guard let uuid = dictionary["uuid"] as? String else {
                throw UploadError.rejected("SimplyPrint did not return the temp-file id.")
            }
            // do_temp_upload opens this panel link in a browser; the temp
            // file is unreachable without it, so the note carries it.
            var panel = URLComponents(string: "https://simplyprint.io/panel")!
            panel.queryItems = [
                URLQueryItem(name: "import", value: "tmp:\(uuid)"),
                URLQueryItem(name: "filename", value: filename),
            ]
            return Outcome(
                note: "SimplyPrint: temp file uploaded — import it in the panel to print.",
                launchURL: startPrint ? panel.url : nil)
        }

        private static func outcomePrinterOS(
            _ body: Data, base: URL, startPrint: Bool
        ) throws -> Outcome {
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
            // 3DPrinterOS.cpp:501: the desktop has no REST start — the
            // quickprint page IS the start action, opened in the browser.
            return Outcome(
                note: startPrint
                    ? "3DPrinterOS: opening the quick-print page for file \(fileID)."
                    : "3DPrinterOS: file uploaded as \(fileID).",
                launchURL: startPrint ? quickPrint : nil)
        }
    }

    /// Uploads `gcode` to `printer`. `startPrint` mirrors the desktop
    /// checkbox (select-and-print / Moonraker print flag). One at a time:
    /// a second call while any upload (direct or queued) runs is refused.
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
        _ = await performUpload(gcode, to: printer, startPrint: startPrint)
    }

    // MARK: Upload queue (board cycle-0.16)

    /// Appends files (a multi-file pick, or the last slice result) for the
    /// given printer and starts the sequential consumer if it is idle.
    func enqueue(
        _ files: [URL],
        to printer: EnginePresets.PhysicalPrinterRecord,
        startPrint: Bool
    ) {
        guard !files.isEmpty else { return }
        queue.append(
            contentsOf: files.map {
                QueuedUpload(id: UUID(), file: $0, printer: printer, startPrint: startPrint)
            }
        )
        let noun = files.count == 1
            ? files[0].lastPathComponent : "\(files.count) uploads"
        status.report(.device, "\(printer.name): queued \(noun)")
        pumpQueue()
    }

    /// Cancels the upload IN FLIGHT (task spec: cancel-current advances) —
    /// the current item is marked skipped and the queue continues with the
    /// next one. It never touches waiting items.
    func cancelCurrentUpload() {
        guard pumpTask != nil else { return }
        pumpTask?.cancel()
    }

    /// Removes a still-waiting item (running items can only be skipped).
    func removeQueuedUpload(id: UUID) {
        guard let index = queue.firstIndex(where: { $0.id == id }),
              queue[index].phase == .waiting
        else { return }
        queue.remove(at: index)
    }

    func clearFinishedUploads() {
        queue.removeAll(where: \.isFinished)
    }

    /// Starts the sequential consumer when idle and work exists. `isUploading`
    /// spans the whole drain (raised here, lowered only when nothing is
    /// waiting) so the direct-send guard and the UI disable state cannot
    /// flicker between items.
    private func pumpQueue() {
        guard pumpTask == nil, queue.contains(where: { $0.phase == .waiting })
        else { return }
        isUploading = true
        pumpTask = Task {
            await consumeQueue()
            pumpTask = nil
            if queue.contains(where: { $0.phase == .waiting }) {
                // Either a cancel-current skipped an item or new files were
                // enqueued while the pump was winding down: keep draining.
                pumpQueue()
            } else {
                isUploading = false
            }
        }
    }

    /// Runs the queue strictly one item at a time. Cancellation targets the
    /// CURRENT item: its outcome is recorded as skipped, the loop stops, and
    /// `pumpQueue` restarts a fresh consumer for the remaining items.
    private func consumeQueue() async {
        while let index = queue.firstIndex(where: { $0.phase == .waiting }) {
            if Task.isCancelled { break }
            var item = queue[index]
            item.phase = .running
            queue[index] = item
            let outcome = await performUpload(
                item.file, to: item.printer, startPrint: item.startPrint
            )
            // Re-locate by identity: the user may have removed other items
            // (or this waiting one was replaced) while the upload ran.
            guard let current = queue.firstIndex(where: { $0.id == item.id })
            else { continue }
            var updated = queue[current]
            switch outcome {
            case .success:
                updated.phase = .done
            case .cancelled:
                updated.phase = .cancelled
            case .failure(let failure):
                updated.phase = .failed(failure.localizedDescription)
            }
            queue[current] = updated
            if Task.isCancelled { break }
        }
    }

    /// The one upload flow (request plan, transport, host body checks,
    /// receipt, status reporting) — the direct send and every queued item
    /// execute exactly this. Reports go through StatusCenter for both
    /// callers; the queue maps the returned outcome onto its item phase.
    private func performUpload(
        _ gcode: URL,
        to printer: EnginePresets.PhysicalPrinterRecord,
        startPrint: Bool
    ) async -> UploadOutcome {
        do {
            // Reading a multi-megabyte G-code file must not block the main
            // actor; the request builder is pure and nonisolated.
            var plan = try await Task.detached(priority: .userInitiated) {
                try Self.request(for: printer, file: gcode, startPrint: startPrint)
            }.value
            if Task.isCancelled { return .cancelled }
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
            var (data, response) = try await session.data(for: plan.request)
            // SimplyPrint do_api_call (SimplyPrint.cpp:206-241): an HTTP
            // 401 means the stored access token expired — refresh once
            // with the saved refresh token, rebuild the request with the
            // new Bearer and retry; a second 401 fails loudly.
            if printer.hostType == "simplyprint",
               let http = response as? HTTPURLResponse, http.statusCode == 401 {
                let token = try await refreshSimplyPrintAccessToken()
                onSimplyPrintTokenRefreshed?(token)
                let refreshed = EnginePresets.PhysicalPrinterRecord(
                    name: printer.name,
                    hostType: printer.hostType,
                    url: printer.url,
                    webUI: printer.webUI,
                    apiKey: token,
                    presetNames: printer.presetNames
                )
                plan = try await Task.detached(priority: .userInitiated) {
                    try Self.request(for: refreshed, file: gcode, startPrint: startPrint)
                }.value
                (data, response) = try await session.data(for: plan.request)
            }
            if let http = response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                throw UploadError.http(status: http.statusCode, host: printer.hostType)
            }
            // Some hosts answer inside an HTTP-200 body (the desktop parses
            // these in the host .cpp on_complete): validate loudly, pick up
            // the web-only follow-up link, and OPEN it like the desktop's
            // wxLaunchDefaultBrowser does.
            var completionNote: String?
            if let bodyCheck = plan.bodyCheck {
                let outcome = try bodyCheck.check(data, startPrint: startPrint)
                completionNote = outcome.note
                if let launch = outcome.launchURL {
                    guard await UIApplication.shared.open(launch) else {
                        throw UploadError.rejected(
                            "\(printer.name): could not open \(launch.absoluteString)")
                    }
                }
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
            // MKS start-print (MKS.cpp start_print): the M23/M24 console
            // protocol over raw TCP — see mksStartPrint for the endpoint
            // details. Runs after the HTTP upload, like the desktop.
            if printer.hostType == "mks", startPrint {
                do {
                    try await Self.mksStartPrint(
                        printerURL: printer.url, file: gcode.lastPathComponent)
                } catch {
                    throw UploadError.console(
                        "MKS M23/M24 console — \(error.localizedDescription)")
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
            let receipt = Receipt(
                printer: printer.name,
                file: gcode.lastPathComponent,
                startedPrint: startPrint && !plan.noRemoteStart
            )
            lastReceipt = receipt
            return .success(receipt)
        } catch {
            // A cancel (Skip) surfaces as CancellationError from the
            // URLSession await — it is a skip, not a failure.
            if Task.isCancelled || error is CancellationError { return .cancelled }
            let failure = AppFailure.wrap(error, operation: "upload gcode")
            status.report(.device, failure: failure)
            return .failure(failure)
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

    // MARK: MKS start-print (raw TCP console, MKS.cpp start_print)

    /// MKS console start (MKS.cpp:122-137): connect to the print host on
    /// the HARDCODED console port 8080 (MKS.cpp:37 `m_console_port("8080")`
    /// — not the HTTP port, and not a setting), wait out the firmware's
    /// post-upload dead time (1.5 s, MKS.cpp:124-128), then send
    /// "M23 <file>\n" and "M24\n" — each command acknowledged by an "ok"
    /// line (desktop Utils::TCPConsole done-string, newline framing,
    /// 5 s connect / 10 s read timeouts). Typed failures: connect,
    /// timeout, closed, non-ok.
    nonisolated private static func mksStartPrint(
        printerURL: String, file: String
    ) async throws {
        guard let url = URL(string: printerURL), let host = url.host(), !host.isEmpty else {
            throw UploadError.badURL(printerURL)
        }
        let console = try TCPConsole(host: host, port: 8080)
        defer { console.close() }
        try await console.connect(timeout: 5)
        // "For some reason printer firmware does not want to respond on
        // gcode commands immediately after file upload" (MKS.cpp comment).
        try await Task.sleep(for: .seconds(1.5))
        for command in ["M23 \(file)", "M24"] {
            try await console.run(command: command, readTimeout: 10)
        }
    }

    // MARK: Browser account linking (desktop OAuthDialog / 3DPrinterOS login)

    /// What a completed "Link account" flow produced: the API key the
    /// printer record stores (SimplyPrint OAuth access token / 3DPrinterOS
    /// session) plus a short account label for the status line.
    struct LinkedAccount: Sendable, Equatable {
        let apiKey: String
        let account: String
    }

    /// Typed failures of the browser account-linking flows (typed like
    /// UploadError: callers branch on the case, never message text).
    enum AccountLinkError: LocalizedError, Sendable {
        case cancelled
        case badURL(String)
        case malformedCallback(String)
        case stateMismatch
        case missingCode(String)
        case tokenExchange(String)
        case http(status: Int, host: String)
        case rejected(String)
        case transport(String)

        var errorDescription: String? {
            switch self {
            case .cancelled:
                return "Sign-in was cancelled."
            case .badURL(let url):
                return "Invalid account-linking URL: \(url)"
            case .malformedCallback(let detail):
                return "The sign-in callback was unusable — \(detail)"
            case .stateMismatch:
                return "The sign-in answer carried a wrong state (possible interference); try again."
            case .missingCode(let detail):
                return "The sign-in did not return an authorization code — \(detail)"
            case .tokenExchange(let detail):
                return "Exchanging the sign-in for a token failed — \(detail)"
            case .http(let status, let host):
                return "\(host) rejected the request (HTTP \(status))."
            case .rejected(let message):
                return message
            case .transport(let message):
                return "Account linking failed: \(message)"
            }
        }
    }

    private let linkLogger = Logger(subsystem: "ie.duz.OrcaPad", category: "printhost")

    /// Fired when an expired SimplyPrint token was refreshed mid-upload;
    /// AppEnvironment persists the new token onto the engine's printer
    /// records (desktop save_oauth_credential parity).
    var onSimplyPrintTokenRefreshed: ((String) -> Void)?

    /// Stored refresh token (one SimplyPrint account per app, like the
    /// desktop's single simplyprint_oauth.json).
    nonisolated private static let simplyPrintRefreshKey = "simplyprint.refreshToken"

    /// SimplyPrint "Link account" (desktop SimplyPrint::get_oauth_params +
    /// GUI::OAuthJob): OAuth2 authorization-code with PKCE S256, the same
    /// client id and scopes the desktop ships ("simplyprintorcaslicer",
    /// "user.read files.temp_upload"), the token exchanged against
    /// api.simplyprint.io/oauth2/Token. The desktop receives the code on a
    /// localhost callback server; iOS replaces it with an
    /// ASWebAuthenticationSession callback on the app's `orcapad` scheme
    /// (registered in App-Info.plist CFBundleURLTypes).
    func linkSimplyPrintAccount() async throws -> LinkedAccount {
        let verifier = Self.randomHex(bytes: 32)
        let state = Self.randomHex(bytes: 32)
        let challenge = Self.pkceChallenge(verifier)
        let callback = "orcapad://simplyprint/callback"
        var components = URLComponents(
            string: "https://simplyprint.io/panel/oauth2/authorize"
        )!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: "simplyprintorcaslicer"),
            URLQueryItem(name: "redirect_uri", value: callback),
            URLQueryItem(name: "scope", value: "user.read files.temp_upload"),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        guard let authorizeURL = components.url else {
            throw AccountLinkError.badURL(components.description)
        }
        let answered = try await webSession(url: authorizeURL, callbackScheme: "orcapad")
        guard let answer = URLComponents(url: answered, resolvingAgainstBaseURL: false)?
            .queryItems
        else {
            throw AccountLinkError.malformedCallback(answered.absoluteString)
        }
        func parameter(_ name: String) -> String? {
            answer.first { $0.name == name }?.value
        }
        // OAuthJob::process: state must match, and a missing code is a
        // user denial or a server error — both typed.
        guard parameter("state") == state else { throw AccountLinkError.stateMismatch }
        guard let code = parameter("code"), !code.isEmpty else {
            let reason = parameter("error_code") ?? parameter("error") ?? "no code returned"
            throw AccountLinkError.missingCode(reason)
        }
        let token = try await simplyPrintToken(
            grant: [
                ("client_id", "simplyprintorcaslicer"),
                ("redirect_uri", callback),
                ("grant_type", "authorization_code"),
                ("code", code),
                ("code_verifier", verifier),
                ("scope", "user.read files.temp_upload"),
            ]
        )
        linkLogger.notice("SimplyPrint account linked")
        return LinkedAccount(apiKey: token.access, account: "SimplyPrint")
    }

    /// One OAuth2 token request against api.simplyprint.io/oauth2/Token
    /// (form-encoded, desktop OAuthJob http.form_add shape). Persists a
    /// returned refresh token for the upload-time refresh path.
    private func simplyPrintToken(
        grant: [(String, String)]
    ) async throws -> (access: String, refresh: String?) {
        guard let url = URL(string: "https://api.simplyprint.io/oauth2/Token") else {
            throw AccountLinkError.badURL("https://api.simplyprint.io/oauth2/Token")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        request.httpBody = grant.map { pair in
            "\(pair.0)=\(pair.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? pair.1)"
        }.joined(separator: "&").data(using: .utf8)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AccountLinkError.http(status: http.statusCode, host: "api.simplyprint.io")
        }
        // parse_token_response: the body must be a JSON object with an
        // access_token; anything else carries error_description when the
        // server bothered to say why.
        let object: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                throw AccountLinkError.tokenExchange(
                    String(decoding: data.prefix(160), as: UTF8.self))
            }
            object = parsed
        } catch let error as AccountLinkError {
            throw error
        } catch {
            throw AccountLinkError.tokenExchange(error.localizedDescription)
        }
        guard let access = object["access_token"] as? String, !access.isEmpty
        else {
            let detail = (object["error_description"] as? String)
                ?? String(decoding: data.prefix(160), as: UTF8.self)
            throw AccountLinkError.tokenExchange(detail)
        }
        let refresh = object["refresh_token"] as? String
        if let refresh, !refresh.isEmpty {
            UserDefaults.standard.set(refresh, forKey: Self.simplyPrintRefreshKey)
        }
        return (access, refresh)
    }

    /// Refreshes an expired SimplyPrint access token (desktop do_api_call
    /// 401 path: grant_type=refresh_token). A missing/failed refresh is a
    /// typed error — the caller fails the upload loudly instead of
    /// silently sending a stale token forever.
    func refreshSimplyPrintAccessToken() async throws -> String {
        guard let refresh = UserDefaults.standard.string(forKey: Self.simplyPrintRefreshKey),
              !refresh.isEmpty
        else {
            throw AccountLinkError.tokenExchange(
                "no stored refresh token — link the account again")
        }
        let token = try await simplyPrintToken(grant: [
            ("grant_type", "refresh_token"),
            ("client_id", "simplyprintorcaslicer"),
            ("refresh_token", refresh),
        ])
        linkLogger.notice("SimplyPrint access token refreshed")
        return token.access
    }

    /// 3DPrinterOS "Link account" (desktop C3DPrinterOS::login,
    /// 3DPrinterOS.cpp:320-350): ask the cloud for a one-time login token
    /// (apiglobal/generate_login_token, app_type=plugin), sign in through
    /// that token in the browser (noauth/apiglobal_login_with_token/<t>),
    /// then exchange the token for a session (apiglobal/login_with_token,
    /// result/message.session/message.email). The desktop polls the
    /// exchange while its dialog is open (TokenAuthDialog, 10 × 500 ms);
    /// OrcaPad opens the browser through ASWebAuthenticationSession and
    /// polls after it returns (or was dismissed — the exchange still
    /// succeeds once the user finished signing in).
    func link3DPrinterOSAccount(
        record: EnginePresets.PhysicalPrinterRecord
    ) async throws -> LinkedAccount {
        guard let base = URL(string: record.url),
              let scheme = base.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = base.host()
        else {
            throw AccountLinkError.badURL(record.url)
        }
        func endpoint(_ path: String) throws -> URLRequest {
            var url = base
            url.append(path: path)
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue(
                "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 15
            return request
        }
        // 1. One-time login token (get_api_auth_token, app_name carries
        // the calling app — the desktop sends "OrcaSlicer").
        var tokenRequest = try endpoint("apiglobal/generate_login_token")
        tokenRequest.httpBody = Data("app_type=plugin&app_name=OrcaPad".utf8)
        let (tokenData, tokenResponse) = try await URLSession.shared.data(for: tokenRequest)
        if let http = tokenResponse as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AccountLinkError.http(status: http.statusCode, host: host)
        }
        let tokenObject: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: tokenData) as? [String: Any]
            else {
                throw AccountLinkError.rejected(
                    "3DPrinterOS answered with unusable JSON: \(String(decoding: tokenData.prefix(160), as: UTF8.self))")
            }
            tokenObject = parsed
        } catch let error as AccountLinkError {
            throw error
        } catch {
            throw AccountLinkError.transport(error.localizedDescription)
        }
        guard (tokenObject["result"] as? Bool) == true,
              let loginToken = tokenObject["message"] as? String, !loginToken.isEmpty
        else {
            let reason = (tokenObject["message"] as? String)
                ?? String(decoding: tokenData.prefix(160), as: UTF8.self)
            throw AccountLinkError.rejected("3DPrinterOS rejected the login-token request: \(reason)")
        }
        // 2. Browser sign-in. Cancelling the browser sheet is EXPLICITLY
        // tolerated here: the desktop keeps polling its own dialog, and a
        // user who finished signing in but dismissed the sheet should
        // still get the session — the exchange below is the truth.
        var loginURL = base
        loginURL.append(path: "noauth/apiglobal_login_with_token/\(loginToken)")
        do {
            _ = try await webSession(url: loginURL, callbackScheme: "orcapad")
        } catch AccountLinkError.cancelled {
            // Explicit recovery, desktop parity: the desktop keeps polling
            // its own dialog — a user who finished signing in but dismissed
            // the sheet still gets the session; the exchange below decides.
            linkLogger.notice("3DPrinterOS browser sheet dismissed; polling the login exchange")
        }
        // 3. Exchange (login_with_token): result/message.session/email.
        var loginRequest = try endpoint("apiglobal/login_with_token")
        loginRequest.httpBody = Data("token=\(loginToken)".utf8)
        for attempt in 0..<10 {
            let (data, response) = try await URLSession.shared.data(for: loginRequest)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw AccountLinkError.http(status: http.statusCode, host: host)
            }
            // result=false answers "not signed in yet" (the poll keeps
            // going); unusable bodies fail the flow loudly.
            let object: [String: Any]
            do {
                object = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            } catch {
                throw AccountLinkError.rejected(
                    "3DPrinterOS answered with unusable JSON: \(String(decoding: data.prefix(160), as: UTF8.self))")
            }
            if (object["result"] as? Bool) == true,
               let message = object["message"] as? [String: Any],
               let session = message["session"] as? String, !session.isEmpty
            {
                let email = (message["email"] as? String) ?? host
                linkLogger.notice("3DPrinterOS account linked")
                return LinkedAccount(apiKey: session, account: email)
            }
            guard attempt < 9 else { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw AccountLinkError.rejected(
            "3DPrinterOS did not confirm the sign-in in time — try again")
    }

    // MARK: Browser session + OAuth helpers

    /// Presents `url` in the system web-authentication sheet and resolves
    /// with the first URL that comes back on `callbackScheme`. The desktop
    /// hosts a localhost callback server (OAuthJob); on iOS the sheet IS
    /// the callback receiver, so the scheme must be registered in the app
    /// (App-Info.plist CFBundleURLTypes "orcapad").
    @MainActor
    private func webSession(url: URL, callbackScheme: String) async throws -> URL {
        // The anchor must be produced ON the main actor (UIApplication is
        // MainActor-isolated); the holder then only hands the stored window
        // back to the framework.
        let anchor: ASPresentationAnchor = await MainActor.run {
            UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                .first ?? ASPresentationAnchor()
        }
        final class Holder: NSObject, ASWebAuthenticationPresentationContextProviding {
            let anchor: ASPresentationAnchor
            var session: ASWebAuthenticationSession?
            init(anchor: ASPresentationAnchor) {
                self.anchor = anchor
            }
            func presentationAnchor(
                for session: ASWebAuthenticationSession
            ) -> ASPresentationAnchor {
                anchor
            }
        }
        let holder = Holder(anchor: anchor)
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme
            ) { callbackURL, error in
                // Referencing the holder keeps it (and through it the
                // session) alive until this callback fires — the sheet must
                // not deallocate out from under the user.
                _ = holder
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else if let error {
                    let code = (error as? ASWebAuthenticationSessionError)?.code
                    if code == .canceledLogin {
                        continuation.resume(throwing: AccountLinkError.cancelled)
                    } else {
                        continuation.resume(
                            throwing: AccountLinkError.transport(error.localizedDescription))
                    }
                } else {
                    continuation.resume(
                        throwing: AccountLinkError.transport("no callback from the sign-in sheet"))
                }
            }
            holder.session = session
            session.presentationContextProvider = holder
            session.start()
        }
    }

    /// Desktop generate_verification_code: random hex string of `bytes`*2
    /// characters.
    nonisolated private static func randomHex(bytes: Int) -> String {
        var random = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &random)
        return random.map { String(format: "%02x", $0) }.joined()
    }

    /// Desktop sha256b64: base64url(SHA-256(input)) with '+'→'-', '/'→'_',
    /// '=' stripped — RFC 7636 S256 (SimplyPrint.cpp:49-68).
    nonisolated private static func pkceChallenge(_ verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Raw line-oriented TCP console (desktop Slic3r::Utils::TCPConsole over
/// boost::asio, reimplemented on Network.framework for the MKS M23/M24
/// start-print). Protocol parity with TCPConsole.cpp: commands are sent
/// with a trailing "\n", answers are read line-by-line until an "ok"
/// (case-insensitive) line; connect timeout 5 s, per-read/write timeout
/// 10 s. Every failure is typed (connect / failed / timeout / closed) —
/// no silent partial exchanges.
///
/// Concurrency: one console serves one async call chain; awaits serialize
/// the buffer access, and the Network callbacks only resume continuations
/// (one-shot guarded), so `@unchecked Sendable` is sound.
private final class TCPConsole: @unchecked Sendable {
    enum ConsoleError: LocalizedError, Sendable {
        case connectFailed(host: String, port: UInt16, detail: String)
        case connectTimeout(host: String, port: UInt16)
        case writeFailed(String)
        case readFailed(String)
        case timeout(String)
        case closed(String)

        var errorDescription: String? {
            switch self {
            case .connectFailed(let host, let port, let detail):
                return "could not connect to \(host):\(port) — \(detail)"
            case .connectTimeout(let host, let port):
                return "connecting to \(host):\(port) timed out"
            case .writeFailed(let detail):
                return "sending the command failed — \(detail)"
            case .readFailed(let detail):
                return "reading the answer failed — \(detail)"
            case .timeout(let detail):
                return "timed out waiting for the printer's answer — \(detail)"
            case .closed(let detail):
                return "the printer closed the connection — \(detail)"
            }
        }
    }

    private let connection: NWConnection
    private let host: String
    private let port: UInt16
    private let queue = DispatchQueue(label: "ie.duz.OrcaPad.tcp-console")
    private var lineBuffer = Data()

    init(host: String, port: UInt16) throws {
        self.host = host
        self.port = port
        guard let endpoint = NWEndpoint.Port(rawValue: port) else {
            throw ConsoleError.connectFailed(host: host, port: port, detail: "invalid port")
        }
        connection = NWConnection(
            to: NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: endpoint),
            using: .tcp
        )
    }

    func close() {
        connection.cancel()
    }

    /// Waits for the TCP connection to become ready (desktop connect
    /// deadline; a timeout cancels the socket, which also resumes any
    /// pending handler exactly once).
    func connect(timeout: TimeInterval) async throws {
        let resumed = ResumeOnce()
        let host = self.host
        let port = self.port
        try await Self.withDeadline(
            ConsoleError.connectTimeout(host: host, port: port),
            seconds: timeout,
            onCancel: { [self] in connection.cancel() }
        ) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.connection.stateUpdateHandler = { [resumed, host, port] state in
                    switch state {
                    case .ready:
                        if resumed.claim() { continuation.resume(returning: ()) }
                    case .failed(let error):
                        if resumed.claim() {
                            continuation.resume(throwing: ConsoleError.connectFailed(
                                host: host, port: port, detail: error.localizedDescription))
                        }
                    case .cancelled:
                        if resumed.claim() {
                            continuation.resume(throwing: ConsoleError.connectFailed(
                                host: host, port: port, detail: "cancelled"))
                        }
                    case .preparing, .setup, .waiting:
                        break
                    @unknown default:
                        break
                    }
                }
                self.connection.start(queue: self.queue)
            }
        }
    }

    /// Sends `command` + "\n" and reads lines until the printer answers
    /// "ok" (TCPConsole done-string; other lines are ignored, exactly like
    /// wait_next_line). A non-ok line after `readTimeout` is a timeout.
    func run(command: String, readTimeout: TimeInterval) async throws {
        try await send("\(command)\n", timeout: readTimeout)
        while true {
            let line = try await readLine(timeout: readTimeout)
            if line.lowercased() == "ok" { return }
        }
    }

    private func send(_ text: String, timeout: TimeInterval) async throws {
        let resumed = ResumeOnce()
        try await Self.withDeadline(
            ConsoleError.timeout("writing \(text.trimmingCharacters(in: .whitespacesAndNewlines))"),
            seconds: timeout,
            onCancel: { [self] in connection.cancel() }
        ) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.connection.send(
                    content: Data(text.utf8),
                    completion: .contentProcessed { [resumed] error in
                        if let error {
                            if resumed.claim() {
                                continuation.resume(throwing: ConsoleError.writeFailed(
                                    error.localizedDescription))
                            }
                        } else if resumed.claim() {
                            continuation.resume(returning: ())
                        }
                    }
                )
            }
        }
    }

    /// Next "\n"-terminated line (trimmed); throws on EOF/transport error.
    private func readLine(timeout: TimeInterval) async throws -> String {
        while true {
            if let index = lineBuffer.firstIndex(of: 0x0A) {
                let lineData = lineBuffer[..<index]
                lineBuffer = Data(lineBuffer[lineBuffer.index(after: index)...])
                return String(decoding: lineData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespaces)
            }
            let chunk = try await receive(timeout: timeout)
            guard !chunk.isEmpty else {
                throw ConsoleError.closed("no newline before end of stream")
            }
            lineBuffer.append(chunk)
        }
    }

    private func receive(timeout: TimeInterval) async throws -> Data {
        let resumed = ResumeOnce()
        return try await Self.withDeadline(
            ConsoleError.timeout("reading a line"),
            seconds: timeout,
            onCancel: { [self] in connection.cancel() }
        ) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                self.connection.receive(
                    minimumIncompleteLength: 1,
                    maximumLength: 65_536
                ) { [resumed] data, _, isComplete, error in
                    if let error {
                        if resumed.claim() {
                            continuation.resume(throwing: ConsoleError.readFailed(
                                error.localizedDescription))
                        }
                    } else if isComplete, data == nil || data?.isEmpty == true {
                        if resumed.claim() { continuation.resume(returning: Data()) }
                    } else if let data {
                        if resumed.claim() { continuation.resume(returning: data) }
                    } else if resumed.claim() {
                        continuation.resume(throwing: ConsoleError.readFailed(
                            "no data and no completion"))
                    }
                }
            }
        }
    }

    // MARK: Timeout plumbing

    /// Races `body` against a deadline: on expiry `onCancel` runs (which
    /// must make `body` fail so its continuation resumes exactly once) and
    /// the deadline error is thrown. Task cancellation takes the same path
    /// — the group cancel triggers `onCancel` through
    /// withTaskCancellationHandler.
    private static func withDeadline<Value: Sendable>(
        _ deadlineError: ConsoleError,
        seconds: TimeInterval,
        onCancel: @escaping @Sendable () -> Void,
        _ body: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask {
                try await withTaskCancellationHandler(operation: body, onCancel: onCancel)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                onCancel()
                throw deadlineError
            }
            guard let first = try await group.next() else {
                throw ConsoleError.readFailed("no outcome from the console race")
            }
            group.cancelAll()
            return first
        }
    }

    /// One-shot claim for continuation resumes (Network handlers can fire
    /// twice: e.g. cancel() delivers both a failed receive and a failed
    /// state transition) — only the first claim wins.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }
}
