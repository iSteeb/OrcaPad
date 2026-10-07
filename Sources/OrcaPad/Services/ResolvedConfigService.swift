import Foundation
import Observation
import OrcaBridge

struct ConfigOptionSchema: Codable, Sendable {
    let key: String
    let type: Int
    let label: String?
    let fullLabel: String?
    let category: String?
    let tooltip: String?
    let guiFlags: String?
    let defaultValue: String?
    let min: Double?
    let max: Double?
    let enumValues: [String]?
    let enumLabels: [String]?

    enum CodingKeys: String, CodingKey {
        case key
        case type
        case label
        case fullLabel = "full_label"
        case category
        case tooltip
        case guiFlags = "gui_flags"
        case defaultValue = "default"
        case min
        case max
        case enumValues = "enum_values"
        case enumLabels = "enum_labels"
    }
}

struct ResolvedConfigRow: Identifiable, Sendable {
    let key: String
    let label: String
    let category: String
    let value: String
    let isDefault: Bool
    let tooltip: String?

    var id: String { key }
}

/// Loads and merges the engine's resolved configuration (`full_config()`
/// exactly as slicing consumes it) with the pinned-engine option schema so
/// the client can present labeled, categorized, default-aware values.
@MainActor
@Observable
final class ResolvedConfigService {
    enum Phase: Sendable {
        case idle
        case loading
        case ready
        case failed(AppFailure)
    }

    private(set) var phase: Phase = .idle
    private(set) var rows: [ResolvedConfigRow] = []
    private(set) var categories: [String] = []

    private static let schema: Result<[ConfigOptionSchema], AppFailure> = {
        guard let url = Bundle.module.url(
            forResource: "config-schema",
            withExtension: "json"
        ) else {
            return .failure(.invariant(
                operation: "load config schema",
                diagnostic: "config-schema.json is missing from the bundle"
            ))
        }
        do {
            let data = try Data(contentsOf: url)
            return .success(try JSONDecoder().decode(
                [ConfigOptionSchema].self,
                from: data
            ))
        } catch {
            return .failure(.path(EnginePathError.importCopy(
                String(reflecting: error)
            )))
        }
    }()

    func load(presets: PresetStore) async {
        guard case .idle = phase else { return }
        phase = .loading
        // Capture the engine handle on the main actor; the detached closure
        // must not touch isolated store state.
        guard let engine = presets.engineForSlicing else {
            phase = .failed(.invariant(
                operation: "load resolved config",
                diagnostic: "presets are not loaded"
            ))
            return
        }
        let result = await BackgroundWork.run(operation: "load resolved config") {
            try engine.resolvedConfig().get()
        }
        switch result {
        case .success(let json):
            switch Self.schema {
            case .success(let schema):
                install(json: json, schema: schema)
            case .failure(let failure):
                phase = .failed(failure)
            }
        case .failure(let failure):
            phase = .failed(failure)
        }
    }

    private func install(json: String, schema: [ConfigOptionSchema]) {
        guard let data = json.data(using: .utf8),
              let values = try? JSONDecoder().decode(
                  [String: String].self,
                  from: data
              ) else {
            phase = .failed(.invariant(
                operation: "decode resolved config",
                diagnostic: "resolved config is not a JSON object of strings"
            ))
            return
        }

        var built: [ResolvedConfigRow] = []
        built.reserveCapacity(values.count)
        var seen = Set<String>()

        func row(
            key: String,
            label: String?,
            category: String?,
            tooltip: String?,
            defaultValue: String?
        ) {
            guard let value = values[key] else { return }
            seen.insert(key)
            built.append(ResolvedConfigRow(
                key: key,
                label: label?.isEmpty == false ? label! : key,
                category: category?.isEmpty == false ? category! : "Other",
                value: value,
                isDefault: defaultValue == nil || defaultValue == value,
                tooltip: tooltip?.isEmpty == false ? tooltip : nil
            ))
        }

        for option in schema {
            row(
                key: option.key,
                label: option.label,
                category: option.category,
                tooltip: option.tooltip,
                defaultValue: option.defaultValue
            )
        }
        // Machine/filament metadata keys that exist in the resolved config
        // but not in print_config_def — still visible, grouped apart.
        for key in values.keys.sorted() where !seen.contains(key) {
            row(key: key, label: nil, category: "Machine metadata",
                tooltip: nil, defaultValue: nil)
        }

        rows = built
        categories = Array(Set(built.map(\.category))).sorted()
        phase = .ready
    }
}
