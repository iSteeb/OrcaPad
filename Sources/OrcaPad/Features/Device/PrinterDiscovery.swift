// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

import Network
import Observation

/// Bonjour printer discovery for the printer editor (board cycle-0.16):
/// NWBrowser over `_octoprint._tcp` and `_moonraker._tcp`, with
/// `_http._tcp` as a fallback when the specific services find nothing on
/// the LAN. Tapping a found service resolves its host+port over a throwaway
/// TCP connection (Bonjour endpoints do not carry an address until
/// connected) and hands `http://host:port` plus a host-type suggestion back
/// to the editor.
///
/// Browsing needs the local-network permission: `NSLocalNetworkUsageDescription`
/// (present since the Device tab shipped) and `NSBonjourServices` listing the
/// browsed types (added with this feature) — iOS prompts on the first scan.
///
/// Main-actor confined model: browsers and connections run on the main
/// dispatch queue and hop into the actor with `MainActor.assumeIsolated`
/// (the handlers fire on the queue the browser was started on).
@MainActor
@Observable
final class PrinterDiscovery {
    /// One browsed Bonjour service. `endpoint` is the unresolved service
    /// endpoint kept for on-demand resolution (NWEndpoint is an immutable
    /// value; resolution happens on tap, never for the whole list).
    struct FoundPrinter: Identifiable, Equatable {
        enum Suggestion: Equatable {
            case octoprint
            case moonraker
            /// `_http._tcp` fallback: any web server on the LAN — prefill
            /// the URL only, never the host type.
            case genericWeb

            /// `PrinterHostKind` value to prefill, nil for the generic case.
            var hostType: String? {
                switch self {
                case .octoprint: return "octoprint"
                case .moonraker: return "moonraker"
                case .genericWeb: return nil
                }
            }

            var label: String {
                switch self {
                case .octoprint: return "OctoPrint"
                case .moonraker: return "Moonraker (Klipper)"
                case .genericWeb: return "Web server"
                }
            }
        }

        let id: String
        /// Bonjour instance name (e.g. "OctoPrint on raspberrypi").
        let name: String
        let suggestion: Suggestion
        let endpoint: NWEndpoint
        /// `http://host:port` once the user tapped and the address resolved.
        var resolvedURL: String?

        static func == (lhs: FoundPrinter, rhs: FoundPrinter) -> Bool {
            lhs.id == rhs.id && lhs.resolvedURL == rhs.resolvedURL
        }

        init(id: String, name: String, suggestion: Suggestion, endpoint: NWEndpoint) {
            self.id = id
            self.name = name
            self.suggestion = suggestion
            self.endpoint = endpoint
        }

    }


    /// Browsers stop silently on some NIC changes; the failure text keeps
    /// that visible instead of looking like an empty LAN.
    private(set) var found: [FoundPrinter] = []
    private(set) var isBrowsing = false
    private(set) var failureText: String?
    private(set) var resolvingID: String?

    private var browsers: [NWBrowser] = []
    private var connections: [NWConnection] = []
    /// Fired with the resolved URL + suggestion when a tap succeeds.
    private var resolveCompletion: ((String, FoundPrinter.Suggestion) -> Void)?
    /// Started when the specific types stay silent (delayed fallback).
    private var fallbackStarted = false

    private static let octoprintType = "_octoprint._tcp"
    private static let moonrakerType = "_moonraker._tcp"
    private static let fallbackType = "_http._tcp"
    private static let fallbackDelay: Duration = .seconds(4)
    private static let resolveTimeout: Duration = .seconds(6)

    // MARK: Browsing

    func setBrowsing(_ on: Bool) {
        if on {
            start()
        } else {
            stop()
        }
    }

    func start() {
        guard !isBrowsing else { return }
        isBrowsing = true
        failureText = nil
        found = []
        fallbackStarted = false
        browse(type: Self.octoprintType, suggestion: .octoprint)
        browse(type: Self.moonrakerType, suggestion: .moonraker)
        // Fallback (task spec): only when the specific services stay silent
        // — `_http._tcp` matches every web server on the LAN, so it must
        // not flood the list while the printer types are still answering.
        Task { [weak self] in
            do {
                try await Task.sleep(for: Self.fallbackDelay)
            } catch {
                // Task cancelled (browsing stopped): the fallback must not
                // start — the guard below re-checks isBrowsing anyway.
                return
            }
            guard let self, self.isBrowsing, !self.fallbackStarted,
                  self.found.isEmpty
            else { return }
            self.fallbackStarted = true
            self.browse(type: Self.fallbackType, suggestion: .genericWeb)
        }
    }

    func stop() {
        isBrowsing = false
        for browser in browsers { browser.cancel() }
        browsers.removeAll()
        for connection in connections { connection.cancel() }
        connections.removeAll()
        resolvingID = nil
        resolveCompletion = nil
    }

    /// Browsers/connections cancel silently on some NIC changes; the
    /// failure text keeps that visible instead of an empty LAN.
    /// Cancel closures registered at browser/connection creation; cancel()
    /// is thread-safe, so a nonisolated deinit can run them without an
    /// actor hop (the sheet disappearing mid-scan must stop hardware).
    private nonisolated(unsafe) var cancellables: [() -> Void] = []

    deinit {
        for cancel in cancellables { cancel() }
    }

    private func browse(type: String, suggestion: FoundPrinter.Suggestion) {
        let browser = NWBrowser(
            for: .bonjour(type: type, domain: nil), using: NWParameters())
        cancellables.append { browser.cancel() }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated {
                self?.merge(results: results, suggestion: suggestion)
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                if case .failed(let error) = state {
                    self.failureText =
                        "Network scan failed: \(error.localizedDescription)"
                }
            }
        }
        browser.start(queue: .main)
        browsers.append(browser)
    }

    private func merge(results: Set<NWBrowser.Result>, suggestion: FoundPrinter.Suggestion) {
        var refreshed: [FoundPrinter] = []
        for result in results {
            // NWBrowser.Result on iOS: if case .service(...) exists it has
            // name/type/domain/interface; the exact arity differs by SDK,
            // so extract through the endpoint description instead.
            let endpointDescription = result.endpoint.debugDescription
            let name: String
            let type: String
            if case let .service(serviceName, serviceType, _, _)? = Optional(result.endpoint) {
                name = serviceName
                type = serviceType
            } else {
                // Fallback: parse "serviceName._type._tcp." markers.
                let parts = endpointDescription.split(separator: ".")
                guard parts.count >= 3 else { continue }
                name = String(parts[0])
                type = String(parts[1])
            }
            let id = "\(type)|\(name)"
            // Keep an already-resolved address when the service re-appears
            // (the endpoint identity is stable across browse updates).
            let resolved = found.first { $0.id == id }?.resolvedURL
            var printer = FoundPrinter(
                id: id, name: name, suggestion: suggestion, endpoint: result.endpoint)
            if let resolved { printer.resolvedURL = resolved }
            refreshed.append(printer)
        }
        // Replace only this suggestion's rows: browsers for different
        // service types contribute disjoint sets, and a stale browser must
        // not wipe the other type's results.
        found = found.filter { $0.suggestion != suggestion }
            + refreshed
        found.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: Resolution (tap to prefill)

    /// Resolves the tapped service to `http://host:port` and calls
    /// `completion` on the main actor; on failure the model's
    /// `failureText` carries the reason and the completion is not called.
    func resolve(
        _ printer: FoundPrinter,
        completion: @escaping (String, FoundPrinter.Suggestion) -> Void
    ) {
        guard resolvingID == nil else { return }  // one resolution at a time
        resolvingID = printer.id
        failureText = nil
        resolveCompletion = completion
        // A throwaway TCP connection is the only way to turn a Bonjour
        // service endpoint into host+port on iOS (NWEndpoint resolves on
        // connect; NetService resolution is legacy).
        let connection = NWConnection(to: printer.endpoint, using: .tcp)
        cancellables.append { connection.cancel() }
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .ready:
                    let remote = connection.currentPath?.remoteEndpoint
                    connection.cancel()
                    self.finishResolution(id: printer.id, endpoint: remote)
                case .failed(let error):
                    connection.cancel()
                    self.finishResolution(
                        id: printer.id, endpoint: nil,
                        reason: error.localizedDescription)
                case .cancelled:
                    break
                case .setup, .preparing, .waiting:
                    break  // .waiting keeps retrying; the timeout gives up
                @unknown default:
                    break
                }
            }
        }
        connection.start(queue: .main)
        connections.append(connection)
        Task { [weak self] in
            do {
                try await Task.sleep(for: Self.resolveTimeout)
            } catch {
                // Task cancelled: a resolution already finished elsewhere.
                return
            }
            guard let self, self.resolvingID == printer.id else { return }
            self.finishResolution(
                id: printer.id, endpoint: nil,
                reason: "the printer did not answer in time")
        }
    }

    private func finishResolution(
        id: String, endpoint: NWEndpoint?, reason: String? = nil
    ) {
        connections.removeAll { $0.state == .cancelled }
        guard resolvingID == id else { return }
        resolvingID = nil
        guard let endpoint, case .hostPort(let host, let port) = endpoint else {
            failureText = reason.map { "Could not resolve the printer's address: \($0)." }
                ?? "Could not resolve the printer's address."
            resolveCompletion = nil
            return
        }
        let url = Self.httpURL(host: host, port: port)
        if let index = found.firstIndex(where: { $0.id == id }) {
            found[index]
        }
        let completion = resolveCompletion
        resolveCompletion = nil
        completion?(url, found.first { $0.id == id }?.suggestion ?? .genericWeb)
    }

    /// `http://[v6-host]:port` / `http://host:port` — LAN printers are plain
    /// HTTP (App-Info.plist ATS allows the local ranges).
    nonisolated private static func httpURL(
        host: NWEndpoint.Host, port: NWEndpoint.Port
    ) -> String {
        let text = "\(host)"
        let wrapped = text.contains(":") && !text.hasPrefix("[")
            ? "[\(text)]" : text
        return "http://\(wrapped):\(port.rawValue)"
    }
}
