// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

import Foundation
import Observation
import os

/// Online system-profile updates (0.19 flagship, desktop PresetUpdater
/// `sync_vendor_config`, PresetUpdater.cpp:655-752): OrcaPad asks
/// `https://check-version.orcaslicer.com/profile?vendor=<id>&orca_version=<v>`
/// for every INSTALLED vendor; a `{vendor_version, download_url}` answer is
/// an available update whose zip is downloaded, extracted with the shared
/// ZipImport reader and imported through the engine's bundle import (the
/// same path the "Import config bundle…" picker uses).
///
/// Honest scope differences vs the desktop, documented here and in the UI:
/// - the desktop extracts into an OTA cache and swaps the files under
///   `<data>/system` at startup; OrcaSlicer's vendor-id check endpoint is
///   honoured, but the INSTALL is the Bridge's non-destructive session
///   bundle import (`orca_presets_import_bundle`) — presets load into the
///   session and persist when saved as user presets, exactly like a picked
///   bundle folder.
/// - the desktop signature-verifies the archive when built with
///   ORCA_UPDATER_SIG_KEY; OrcaSlicer ships releases without it, and the
///   endpoint is the same one the desktop app itself trusts.
@MainActor
@Observable
final class ProfileUpdates {
    /// One vendor the check endpoint offered an update for.
    struct VendorUpdate: Identifiable, Equatable, Sendable {
        /// The vendor id used with the endpoint (the `<Vendor>.json` stem,
        /// e.g. "BBL" — NOT the display name "Bambulab").
        let vendorID: String
        let displayName: String
        let version: String
        let downloadURL: String
        /// Version already installed through OrcaPad (nil = never updated
        /// here; the bundled system version lives in VendorProfile).
        var installedVersion: String?

        var id: String { vendorID }
    }

    /// One installed vendor found in the system profile tree.
    struct InstalledVendor: Equatable, Sendable {
        let vendorID: String
        let displayName: String
        /// The bundled `<Vendor>.json` top-level `version` (nil when the
        /// file is unreadable — treated as "unknown, offer the update").
        let bundledVersion: String?
    }

    enum ProfileUpdateError: LocalizedError, Sendable {
        case http(status: Int, vendor: String)
        case badResponse(vendor: String, detail: String)
        case download(String)
        case extraction(String)
        case noVendorJSON(String)
        case importRejected(String)

        var errorDescription: String? {
            switch self {
            case .http(let status, let vendor):
                return "profile check for \(vendor) failed (HTTP \(status))"
            case .badResponse(let vendor, let detail):
                return "profile check for \(vendor) returned an unusable answer — \(detail)"
            case .download(let detail):
                return "profile update download failed — \(detail)"
            case .extraction(let detail):
                return "profile update archive could not be extracted — \(detail)"
            case .noVendorJSON(let detail):
                return "profile update archive has no vendor json — \(detail)"
            case .importRejected(let detail):
                return "profile update was not imported — \(detail)"
            }
        }
    }

    private let status: StatusCenter
    private let logger = Logger(subsystem: "ie.duz.OrcaPad", category: "profiles")

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 120
        return URLSession(configuration: configuration)
    }()

    private(set) var isChecking = false
    private(set) var isInstalling = false
    /// Updates the last completed check found (superseded by the next one).
    private(set) var available: [VendorUpdate] = []
    /// Per-vendor failures of the last check (logged + typed, never fatal:
    /// one unreachable vendor must not hide the others' updates).
    private(set) var lastCheckFailures: [(vendor: String, message: String)] = []

    private static let endpoint = URL(
        string: "https://check-version.orcaslicer.com/profile"
    )!
    /// The pinned engine's own version string (upstream version.inc
    /// SoftFever_VERSION — what the desktop sends as `orca_version`).
    private static let orcaVersion = "2.4.2"

    private static let lastCheckKey = "profiles.lastCheck"
    private static let installedVersionKey = "profiles.installedVersion"

    init(status: StatusCenter) {
        self.status = status
    }

    var lastCheckDate: Date? {
        let interval = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        return interval > 0 ? Date(timeIntervalSince1970: interval) : nil
    }

    /// The version OrcaPad last installed for a vendor (nil = never).
    func installedVersion(vendorID: String) -> String? {
        UserDefaults.standard.dictionary(forKey: Self.installedVersionKey)?[vendorID] as? String
    }

    // MARK: Installed vendors (system profile tree)

    /// Every installed vendor: the engine lists per-preset `vendor` display
    /// names (VendorProfile::name), while the check endpoint wants the
    /// vendor ID (the `<Vendor>.json` stem). The bundled system tree maps
    /// one to the other (`name` field → file stem), so the id resolution
    /// reads exactly what the engine itself loaded. The tree scan runs
    /// off the main actor (1.5 MB of JSON headers); the matching is cheap.
    func installedVendors(from presets: PresetStore) async -> [InstalledVendor] {
        let displayNames = Set(
            presets.machines
                .filter { $0.origin == .system }
                .map(\.vendor)
                .filter { !$0.isEmpty }
        )
        guard !displayNames.isEmpty else { return [] }
        let profiles = await BackgroundWork.run(operation: "scan vendor profiles") {
            Self.systemVendorProfiles()
        }
        let scanned: [SystemVendorProfile]
        switch profiles {
        case .success(let found): scanned = found
        case .failure(let failure):
            status.report(.presets, failure: failure)
            scanned = []
        }
        var resolved: [InstalledVendor] = []
        for profile in scanned {
            guard displayNames.contains(profile.name) || displayNames.contains(profile.id)
            else { continue }
            resolved.append(InstalledVendor(
                vendorID: profile.id,
                displayName: profile.name.isEmpty ? profile.id : profile.name,
                bundledVersion: profile.version
            ))
        }
        // A preset vendor with no resolvable profile json still gets a
        // check under its own name (best-effort id, same as the display
        // name) — an unknown id answers "no update" server-side.
        let resolvedIDs = Set(resolved.map(\.vendorID))
        let resolvedNames = Set(resolved.map(\.displayName))
        for name in displayNames where !resolvedIDs.contains(name) && !resolvedNames.contains(name) {
            resolved.append(InstalledVendor(
                vendorID: name, displayName: name, bundledVersion: nil))
        }
        return resolved.sorted { $0.displayName < $1.displayName }
    }

    /// One bundled vendor profile: file stem (id), display `name`, `version`.
    private struct SystemVendorProfile {
        let id: String
        let name: String
        let version: String?
    }

    /// Parses `<dataDir>/system/*.json` headers (name + version only).
    /// A single unreadable json is skipped with a log line — the tree is
    /// engine-owned input, and one malformed file must not kill updates
    /// for every other vendor. (An unreadable data dir itself already
    /// failed loudly in PresetStore.load.)
    private nonisolated static func systemVendorProfiles() -> [SystemVendorProfile] {
        let systemDirectory: URL
        do {
            systemDirectory = try EnginePaths.preparePresetDataDirectory()
                .appendingPathComponent("system", isDirectory: true)
        } catch {
            Logger(subsystem: "ie.duz.OrcaPad", category: "profiles")
                .warning("vendor scan skipped: data directory unavailable")
            return []
        }
        let jsons: [URL]
        do {
            jsons = try FileManager.default.contentsOfDirectory(
                at: systemDirectory, includingPropertiesForKeys: nil
            ).filter { $0.pathExtension.lowercased() == "json" }
        } catch {
            Logger(subsystem: "ie.duz.OrcaPad", category: "profiles")
                .warning("vendor scan skipped: cannot list the system tree")
            return []
        }
        var profiles: [SystemVendorProfile] = []
        for json in jsons {
            let profile: SystemVendorProfile?
            do {
                let data = try Data(contentsOf: json)
                let object = (try JSONSerialization.jsonObject(with: data)) as? [String: Any]
                profile = object.map { dictionary in
                    SystemVendorProfile(
                        id: json.deletingPathExtension().lastPathComponent,
                        name: dictionary["name"] as? String ?? "",
                        version: dictionary["version"] as? String
                    )
                }
            } catch {
                Logger(subsystem: "ie.duz.OrcaPad", category: "profiles")
                    .warning("vendor profile \(json.lastPathComponent, privacy: .public) is unreadable; skipping")
                profile = nil
            }
            if let profile { profiles.append(profile) }
        }
        return profiles
    }

    // MARK: Check

    /// Asks the endpoint for every installed vendor. Network/parse failures
    /// are collected per vendor (typed + logged, not fatal); `available`
    /// holds the updates the endpoint actually offered.
    func check(vendors: [InstalledVendor]) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        var updates: [VendorUpdate] = []
        var failures: [(vendor: String, message: String)] = []
        for vendor in vendors {
            do {
                if let update = try await checkVendor(vendor) {
                    updates.append(update)
                }
            } catch {
                let message = (error as? ProfileUpdateError)?
                    .errorDescription ?? error.localizedDescription
                failures.append((vendor: vendor.displayName, message: message))
                logger.warning("profile check failed: \(message, privacy: .public)")
            }
        }
        available = updates
        lastCheckFailures = failures
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
        if failures.isEmpty {
            status.report(
                .presets,
                updates.isEmpty
                    ? "profiles: no updates available (\(vendors.count) vendor(s) checked)"
                    : "profile updates available: \(updates.map(\.displayName).joined(separator: ", "))"
            )
        } else {
            status.report(.presets, failure: .invariant(
                operation: "check profile updates",
                diagnostic: failures.map { "\($0.vendor): \($0.message)" }
                    .joined(separator: "; ")
            ))
        }
    }

    /// One vendor check (desktop sync_vendor_config: HTTP 200 + both JSON
    /// fields, else "no update"). Version comparison: the bundled json's
    /// `version` (and the version OrcaPad last installed) against the
    /// online `vendor_version`, numeric component-wise with a string
    /// fallback — the same 4-part "02.01.00.19" format both sides use.
    private func checkVendor(_ vendor: InstalledVendor) async throws -> VendorUpdate? {
        var components = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "vendor", value: vendor.vendorID),
            URLQueryItem(name: "orca_version", value: Self.orcaVersion),
        ]
        guard let url = components.url else {
            throw ProfileUpdateError.badResponse(vendor: vendor.vendorID, detail: "bad request URL")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            throw ProfileUpdateError.badResponse(
                vendor: vendor.vendorID, detail: error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ProfileUpdateError.http(status: http.statusCode, vendor: vendor.vendorID)
        }
        // Desktop parity: a 200 whose body is not a usable JSON object with
        // BOTH fields logs a warning and means "no update" — never a crash
        // of the whole check.
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            logger.warning(
                "profile check for \(vendor.vendorID, privacy: .public) returned non-JSON; treating as no update"
            )
            return nil
        }
        guard let object = parsed as? [String: Any],
              let version = object["vendor_version"] as? String,
              let download = object["download_url"] as? String,
              !version.isEmpty, !download.isEmpty
        else {
            return nil
        }
        let installedHere = installedVersion(vendorID: vendor.vendorID)
        if let current = installedHere ?? vendor.bundledVersion,
           Self.version(version, isNotNewerThan: current) {
            return nil
        }
        return VendorUpdate(
            vendorID: vendor.vendorID,
            displayName: vendor.displayName,
            version: version,
            downloadURL: download,
            installedVersion: installedHere
        )
    }

    /// "01.02.00.03" ≤ "01.02.00.03": numeric component-wise (missing
    /// components count as 0), non-numeric parts fall back to a numeric
    /// string compare; equal ⇒ not newer.
    private static func version(_ candidate: String, isNotNewerThan current: String) -> Bool {
        let left = candidate.split(separator: ".").map(String.init)
        let right = current.split(separator: ".").map(String.init)
        guard !left.isEmpty, !right.isEmpty else {
            return candidate.compare(current, options: .numeric) != .orderedDescending
        }
        let count = max(left.count, right.count)
        for index in 0..<count {
            let a = index < left.count ? left[index] : "0"
            let b = index < right.count ? right[index] : "0"
            if let aNumber = Int(a), let bNumber = Int(b) {
                if aNumber != bNumber { return aNumber < bNumber }
            } else if a.compare(b, options: .numeric) != .orderedSame {
                return a.compare(b, options: .numeric) == .orderedAscending
            }
        }
        return true
    }

    // MARK: Install

    /// Downloads `update`'s zip, extracts it (ZipImport reader) and imports
    /// the vendor folder through the engine bundle import (the exact flow
    /// the "Import config bundle…" picker drives). Records the installed
    /// version so the same update is not offered again.
    func install(_ update: VendorUpdate, presets: PresetStore) async {
        guard !isInstalling else {
            status.report(.presets, "profile install blocked: another install is running")
            return
        }
        isInstalling = true
        defer { isInstalling = false }
        guard let url = URL(string: update.downloadURL) else {
            status.report(.presets, failure: .invariant(
                operation: "install profile update",
                diagnostic: "invalid download URL for \(update.displayName)"))
            return
        }
        status.report(.presets, "\(update.displayName): downloading profile update…")
        do {
            let (zipData, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw ProfileUpdateError.download("HTTP \(code) from \(update.downloadURL)")
            }
            // Scratch directory: the archive is fully extracted, the vendor
            // json located, then the engine reads the folder; removed after.
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("profile-updates", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { Self.removeScratch(scratch) }
            let zipURL = scratch.appendingPathComponent("\(update.vendorID).zip")
            try zipData.write(to: zipURL, options: .atomic)
            let extracted = try await BackgroundWork.run(
                operation: "extract profile update"
            ) {
                try ZipImport.extractAll(from: zipURL, into: scratch)
            }.get()
            guard let vendorJSON = Self.locateVendorJSON(
                in: scratch, extracted: extracted, vendorID: update.vendorID
            ) else {
                throw ProfileUpdateError.noVendorJSON(
                    "expected \(update.vendorID).json near the archive root")
            }
            await presets.importBundle(at: vendorJSON)
            var installed = UserDefaults.standard.dictionary(
                forKey: Self.installedVersionKey) ?? [:]
            installed[update.vendorID] = update.version
            UserDefaults.standard.set(installed, forKey: Self.installedVersionKey)
            available.removeAll { $0.vendorID == update.vendorID }
            logger.notice(
                "profile update installed: \(update.vendorID, privacy: .public) \(update.version, privacy: .public)"
            )
        } catch {
            let failure = AppFailure.wrap(error, operation: "install profile update")
            status.report(.presets, failure: failure)
        }
    }

    /// The downloaded zip "contains the vendor json/folder at its root"
    /// (upstream comment at the desktop extraction). Accepts the json at
    /// the archive root, or one directory deep (a wrapping folder), first
    /// by vendor-id match (case-insensitive), else the only top-level json.
    private static func locateVendorJSON(
        in scratch: URL, extracted: [URL], vendorID: String
    ) -> URL? {
        let candidates = extracted.filter { $0.pathExtension.lowercased() == "json" }
        let byID = candidates.filter {
            $0.deletingLastPathComponent() == scratch ||
            $0.deletingLastPathComponent().deletingLastPathComponent() == scratch
        }
        if let match = byID.first(where: {
            $0.deletingPathExtension().lastPathComponent.lowercased()
                == vendorID.lowercased()
        }) {
            return match
        }
        return byID.count == 1 ? byID.first : nil
    }

    /// Best-effort scratch cleanup after the install finished (success or
    /// failure): the extracted tree is temp state the engine already read
    /// or rejected — a leftover tmp directory must never mask the real
    /// result, so the (unlikely) failed removal is logged, not thrown.
    nonisolated private static func removeScratch(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            Logger(subsystem: "ie.duz.OrcaPad", category: "profiles")
                .warning("could not remove profile-update scratch \(url.lastPathComponent, privacy: .public)")
        }
    }
}
