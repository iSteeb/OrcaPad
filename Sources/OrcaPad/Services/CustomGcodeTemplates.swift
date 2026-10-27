// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

import Foundation
import Observation
import os

/// Desktop custom G-code templates (app-config snippets reusable as layer
/// ticks): a small UserDefaults-backed JSON store. Seeded once with three
/// useful defaults; every later change (add / rename / edit / delete) is
/// persisted immediately.
@MainActor
@Observable
final class CustomGcodeTemplatesStore {
    struct Template: Identifiable, Codable, Sendable, Equatable {
        var id = UUID()
        var name: String
        var gcode: String
    }

    private static let storageKey = "customGcode.templates"
    private static let logger = Logger(
        subsystem: "ie.duz.OrcaPad", category: "gcode-templates")

    private(set) var templates: [Template] = []
    /// Non-nil when the stored JSON could not be decoded: surfaced in the
    /// manage sheet (never silently ignored), with the seed defaults active.
    private(set) var loadError: String?

    init(defaults: UserDefaults = .standard) {
        guard let data = defaults.data(forKey: Self.storageKey) else {
            templates = Self.seedTemplates()
            return
        }
        do {
            templates = try JSONDecoder().decode([Template].self, from: data)
        } catch {
            let detail = error.localizedDescription
            loadError = detail
            Self.logger.error(
                "custom G-code templates unreadable: \(detail, privacy: .public)"
            )
            templates = Self.seedTemplates()
        }
    }

    func add(name: String, gcode: String, defaults: UserDefaults = .standard) {
        templates.append(Template(name: name, gcode: gcode))
        persist(to: defaults)
    }

    /// Returns false when `id` is unknown (the list and the UI share one
    /// in-memory source, so that is an invariant break the caller reports).
    @discardableResult
    func update(
        id: UUID, name: String, gcode: String, defaults: UserDefaults = .standard
    ) -> Bool {
        guard let index = templates.firstIndex(where: { $0.id == id }) else {
            return false
        }
        templates[index].name = name
        templates[index].gcode = gcode
        persist(to: defaults)
        return true
    }

    func delete(id: UUID, defaults: UserDefaults = .standard) {
        templates.removeAll { $0.id == id }
        persist(to: defaults)
    }

    private func persist(to defaults: UserDefaults) {
        do {
            let data = try JSONEncoder().encode(templates)
            defaults.set(data, forKey: Self.storageKey)
            loadError = nil
        } catch {
            // Persisting user data is required work: surface the failure
            // through the same field the manage sheet shows.
            let detail = error.localizedDescription
            loadError = detail
            Self.logger.error(
                "custom G-code templates not saved: \(detail, privacy: .public)"
            )
        }
    }

    /// Seed defaults (desktop's first-run template snippets): a beep, a
    /// manual filament-change pause, and a short dwell.
    private static func seedTemplates() -> [Template] {
        [
            Template(
                name: "Beep",
                gcode: "M300 S880 P200"),
            Template(
                name: "Filament change pause",
                gcode: "; PAUSE_PRINT — pause the print\nM600 ; load the new filament, then resume"),
            Template(
                name: "Layer dwell",
                gcode: "G4 P500"),
        ]
    }
}
