import Foundation
import Observation

/// Client model of the generated config schema (pinned-engine
/// print_config_def). Single shared decode; loaded once per process.
enum ConfigSchema {
    static let shared: Result<[ConfigOptionSchema], AppFailure> = {
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
            return .failure(.invariant(
                operation: "decode config schema",
                diagnostic: String(reflecting: error)
            ))
        }
    }()

    /// Desktop-parity visibility: Simple shows comSimple only; Advanced adds
    /// comAdvanced; Expert adds comExpert (comDevelop stays engine-internal).
    static func isVisible(mode: Int, filter: SettingsModeFilter) -> Bool {
        switch filter {
        case .simple: return mode <= 0
        case .advanced: return mode <= 1
        case .expert: return mode <= 2
        }
    }
}

enum SettingsModeFilter: String, CaseIterable, Identifiable, Sendable {
    case simple = "Simple"
    case advanced = "Advanced"
    case expert = "Expert"

    var id: String { rawValue }
}

/// One editable option merged from the schema and the engine's edited config.
struct SettingsEditorRow: Identifiable, Sendable {
    let key: String
    let label: String
    let category: String
    let tooltip: String?
    let mode: Int
    let type: Int
    let defaultValue: String?
    let enumValues: [String]
    let enumLabels: [String]
    let value: String
    let isModified: Bool

    var id: String { key }

    var isVector: Bool { type & 0x4000 != 0 }
    var scalarType: Int { type & ~0x4000 }

    var editorKind: SettingsEditorKind {
        if !enumValues.isEmpty && (scalarType == 9 || scalarType == 2) {
            return .picker
        }
        switch scalarType {
        case 8: return .toggle
        case 1, 2, 4, 5: return .numeric
        default: return .text
        }
    }

    var boolValue: Bool {
        value == "1" || value.lowercased() == "true"
    }
}

enum SettingsEditorKind: Sendable {
    case toggle
    case picker
    case numeric
    case text
}
