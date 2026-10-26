// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

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
        let startRequest: URLRequest?
        let digest: DigestCredentials?
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
            if let start = plan.startRequest {
                let (_, startResponse) = try await session.data(for: start)
                if let http = startResponse as? HTTPURLResponse,
                   !(200..<300).contains(http.statusCode) {
                    // The FILE is uploaded; only the start command failed.
                    throw UploadError.http(status: http.statusCode, host: printer.hostType)
                }
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
                startRequest: startPrint
                    ? Self.duetStart(base: base, file: file.lastPathComponent) : nil,
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
            startRequest: nil,
            digest: digest
        )
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
