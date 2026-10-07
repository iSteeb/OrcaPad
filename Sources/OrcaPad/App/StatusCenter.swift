import Foundation
import Observation
import OrcaBridge
import os

enum StatusSubsystem: String, CaseIterable, Hashable, Sendable {
    case renderer = "renderer"
    case document = "document"
    case presets = "presets"
    case slice = "slice"
    case preview = "preview"
}

enum AppFailure: Error, LocalizedError, Sendable {
    case bridge(BridgeError)
    case path(EnginePathError)
    case invariant(operation: String, diagnostic: String)
    case unexpected(operation: String, diagnostic: String)

    var errorDescription: String? {
        switch self {
        case .bridge(let error):
            return error.message
        case .path(let error):
            return error.localizedDescription
        case .invariant(let operation, let diagnostic),
             .unexpected(let operation, let diagnostic):
            return "\(operation): \(diagnostic)"
        }
    }

    static func wrap(_ error: any Error, operation: String) -> AppFailure {
        if let failure = error as? AppFailure { return failure }
        if let bridge = error as? BridgeError { return .bridge(bridge) }
        if let path = error as? EnginePathError { return .path(path) }
        return .unexpected(
            operation: operation,
            diagnostic: String(reflecting: error)
        )
    }
}

struct StatusEntry: Identifiable, Sendable {
    let subsystem: StatusSubsystem
    let text: String

    var id: StatusSubsystem { subsystem }
}

@MainActor
@Observable
final class StatusCenter {
    private let logger = Logger(
        subsystem: "ie.duz.OrcaPad",
        category: "status"
    )
    private var entries: [StatusSubsystem: String] = [
        .renderer: "Metal: starting…",
        .document: "engine: starting…"
    ]

    var visibleEntries: [StatusEntry] {
        StatusSubsystem.allCases.compactMap { subsystem in
            entries[subsystem].map {
                StatusEntry(subsystem: subsystem, text: $0)
            }
        }
    }

    func report(_ subsystem: StatusSubsystem, _ text: String) {
        entries[subsystem] = text
        logger.notice("[\(subsystem.rawValue, privacy: .public)] \(text, privacy: .public)")
    }

    /// Updates high-frequency transient UI state without emitting one os_log
    /// record per progress tick. Lifecycle and failure reports remain logged.
    func update(_ subsystem: StatusSubsystem, _ text: String) {
        entries[subsystem] = text
    }

    func report(_ subsystem: StatusSubsystem, failure: AppFailure) {
        let message = failure.localizedDescription
        entries[subsystem] = message
        logger.error("[\(subsystem.rawValue, privacy: .public)] \(message, privacy: .public)")
    }
}

enum BackgroundWork {
    static func run<Value: Sendable>(
        operation: String,
        priority: TaskPriority = .userInitiated,
        _ work: @escaping @Sendable () throws -> Value
    ) async -> Result<Value, AppFailure> {
        await Task.detached(priority: priority) {
            do {
                return .success(try work())
            } catch {
                return .failure(AppFailure.wrap(error, operation: operation))
            }
        }.value
    }
}
