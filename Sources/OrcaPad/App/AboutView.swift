// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

import SwiftUI

/// About & Licenses screen (COMPLIANCE.md W3): the AGPL-3.0 text, upstream
/// attribution, the third-party license inventory, and the exact source of
/// the running binary — reachable in-app, not only on the web. Presentation
/// only; resources are bundled read-only files.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    /// Read-only license material bundled under Resources/Licenses.
    private struct LicenseResources {
        let agplText: String
        let thirdParty: String
        /// License text files (name → content), sorted by name.
        let texts: [(name: String, body: String)]

        /// Loads every bundled license resource or throws — a missing or
        /// unreadable license file is a compliance failure and must surface,
        /// never silently degrade (repo rule: fail loudly).
        init() throws {
            let base = Bundle.module.bundleURL
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent("Licenses", isDirectory: true)

            func load(_ relativePath: String) throws -> String {
                let url = base.appendingPathComponent(relativePath)
                let text: String
                do {
                    text = try String(contentsOf: url, encoding: .utf8)
                } catch let error as AboutError {
                    throw error
                } catch {
                    throw AboutError.unreadableLicenseResource(relativePath, underlying: error)
                }
                guard !text.isEmpty else {
                    throw AboutError.missingLicenseResource(relativePath)
                }
                return text
            }

            agplText = try load("AGPL-3.0.txt")
            thirdParty = try load("THIRD_PARTY.md")
            let licensesDir = base.appendingPathComponent(
                "licenses",
                isDirectory: true
            )
            let urls: [URL]
            do {
                urls = try FileManager.default.contentsOfDirectory(
                    at: licensesDir,
                    includingPropertiesForKeys: nil
                )
            } catch {
                throw AboutError.missingLicenseResource("licenses/")
            }
            guard !urls.isEmpty else {
                throw AboutError.missingLicenseResource("licenses/")
            }
            texts = try urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
                .map { url in (name: url.lastPathComponent, body: try load("licenses/\(url.lastPathComponent)")) }
        }
    }

    private enum AboutError: LocalizedError {
        case missingLicenseResource(String)
        case unreadableLicenseResource(String, underlying: Error)

        var errorDescription: String? {
            switch self {
            case let .missingLicenseResource(path),
                 let .unreadableLicenseResource(path, _):
                "Bundled license resource missing or unreadable: \(path) "
                    + "(\(self.underlyingDescription ?? "no detail")). "
                    + "This build's license bundle is incomplete — please "
                    + "report it at github.com/iSteeb/OrcaPad/issues."
            }
        }

        private var underlyingDescription: String? {
            switch self {
            case .missingLicenseResource: nil
            case let .unreadableLicenseResource(_, error): error.localizedDescription
            }
        }
    }

    @State private var resources: LicenseResources?
    @State private var loadError: String?

    private static let repositoryURL = URL(
        string: "https://github.com/iSteeb/OrcaPad"
    )!
    private static let issuesURL = URL(
        string: "https://github.com/iSteeb/OrcaPad/issues"
    )!

    var body: some View {
        NavigationStack {
            Group {
                if let resources {
                    content(resources)
                } else if let loadError {
                    ErrorView(message: loadError)
                } else {
                    ProgressView("Loading licenses…")
                        .task { load() }
                }
            }
            .navigationTitle("About & Licenses")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func load() {
        do {
            resources = try LicenseResources()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func content(_ resources: LicenseResources) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("OrcaPad")
                        .font(.title2.weight(.semibold))
                    LabeledRow(label: "Version", value: versionLine)
                    LabeledRow(label: "Source", value: sourceRef)
                    Text(
                        "OrcaPad is free software under the GNU Affero "
                            + "General Public License v3.0. You may run, "
                            + "study, modify, and redistribute it — see the "
                            + "license below."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    Link(
                        "Source code: github.com/iSteeb/OrcaPad",
                        destination: Self.repositoryURL
                    )
                    .font(.footnote.weight(.medium))
                }
                .padding(.vertical, 4)
            }

            Section("Attribution") {
                Text(
                    "OrcaPad contains and modifies OrcaSlicer, "
                        + "© SoftFever and contributors, which is based on "
                        + "Bambu Studio, PrusaSlicer, and Slic3r. Their "
                        + "copyright and license notices are retained in the "
                        + "source. OrcaPad is an independent project and is "
                        + "not affiliated with or endorsed by them."
                )
                .font(.footnote)
            }

            Section("Build your own") {
                Text(
                    "Complete instructions for building — and installing "
                        + "your own modified copy on your own device — are "
                        + "in BUILDING.md in the repository."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Section("License — GNU AGPL v3.0") {
                Text(resources.agplText)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
            }

            Section("Third-party components") {
                Text(resources.thirdParty)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
            }

            Section("Third-party license texts") {
                ForEach(resources.texts, id: \.name) { text in
                    NavigationLink {
                        ScrollView {
                            Text(text.body)
                                .font(.system(size: 10, design: .monospaced))
                                .textSelection(.enabled)
                                .padding()
                        }
                        .navigationTitle(text.name)
                        .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        Text(text.name)
                            .font(.footnote)
                    }
                }
            }

            Section {
                Link(
                    "Report an issue",
                    destination: Self.issuesURL
                )
            }
        }
    }

    private var versionLine: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(version) (build \(build))"
    }

    private var sourceRef: String {
        (Bundle.main.infoDictionary?["ORCAPAD_SOURCE_REF"] as? String)
            ?? "unknown"
    }

    private struct LabeledRow: View {
        let label: String
        let value: String

        var body: some View {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text(value)
                    .font(.footnote)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
        }
    }

    private struct ErrorView: View {
        let message: String

        var body: some View {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.yellow)
                Text(message)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
    }
}
