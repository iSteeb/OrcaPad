// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

import Observation
import os
import SwiftUI
import WebKit

/// The connected printer's OWN web interface (Mainsail / Fluidd /
/// OctoPrint / ...), desktop `PrinterWebView` parity. This is the scoped
/// AGENTS.md exception: only the printer's page is web content; every
/// OrcaPad control around it stays native.
///
/// Main-actor confined: one WKWebView per session, kept alive across tab
/// switches so the printer UI does not reload every time the tab appears.
@MainActor
@Observable
final class PrinterWebSession: NSObject {
    /// A page load that failed, shown over the web view with a retry.
    struct LoadFailure: Equatable, Sendable {
        let url: URL
        let message: String
    }

    private static let logger = Logger(subsystem: "ie.duz.OrcaPad", category: "device-web")

    let webView: WKWebView
    private(set) var isLoading = false
    private(set) var failure: LoadFailure?
    private(set) var currentRequest: URLRequest?

    override init() {
        let configuration = WKWebViewConfiguration()
        // Printer UIs stream webcams (MJPEG / WebRTC / HLS) inline.
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        // Persistent store: Mainsail / Fluidd keep their settings in
        // localStorage, desktop's wxWebView does the same.
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
    }

    /// Loads `request` unless it is already the page being shown.
    func show(_ request: URLRequest) {
        if currentRequest?.url == request.url, failure == nil, webView.url != nil { return }
        load(request)
    }

    func reload() {
        guard let currentRequest else { return }
        if webView.url == nil || failure != nil {
            load(currentRequest)
        } else {
            failure = nil
            webView.reload()
        }
    }

    private func load(_ request: URLRequest) {
        currentRequest = request
        failure = nil
        Self.logger.notice("load \(request.url?.absoluteString ?? "-", privacy: .public)")
        webView.load(request)
    }

    fileprivate func fail(_ error: any Error) {
        let nsError = error as NSError
        // A navigation superseded by a newer one (reload, link tap) reports
        // NSURLErrorCancelled; that load was replaced, not failed.
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
        isLoading = false
        let url = currentRequest?.url ?? webView.url ?? URL(fileURLWithPath: "/")
        let message = "\(nsError.localizedDescription) (\(nsError.domain) \(nsError.code))"
        failure = LoadFailure(url: url, message: message)
        Self.logger.error("load failed \(url.absoluteString, privacy: .public): \(message, privacy: .public)")
    }
}

extension PrinterWebSession: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        failure = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        fail(error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        fail(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // WebKit killed the page (memory pressure): reload rather than
        // leave a blank view.
        Self.logger.error("web content process terminated; reloading")
        reload()
    }
}

/// SwiftUI host for a session's WKWebView.
struct PrinterWebView: UIViewRepresentable {
    let session: PrinterWebSession

    func makeUIView(context: Context) -> WKWebView {
        session.webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
