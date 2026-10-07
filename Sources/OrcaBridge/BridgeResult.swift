import Foundation
import OrcaBridgeCore

/// Stable status taxonomy shared with `orca_bridge.h`.
public enum BridgeStatus: Int32, Sendable {
    case ok = 0
    case invalidArgument = 1
    case invalidHandle = 2
    case notFound = 3
    case unsupportedCapability = 4
    case cancelled = 5
    case ioFailure = 6
    case invalidModel = 7
    case invalidConfiguration = 8
    case engineFailure = 9
    case outOfMemory = 10
    case internalInvariant = 11
}

/// Typed Bridge failure. Human-readable diagnostics are context, never control
/// flow; callers branch on `status`.
public struct BridgeError: Error, Sendable, LocalizedError {
    public let status: BridgeStatus
    public let operation: String
    public let diagnostic: String
    public let rawStatus: Int32

    public var message: String {
        diagnostic.isEmpty
            ? "\(operation) failed with status \(status)"
            : diagnostic
    }

    public var errorDescription: String? { message }

    static func local(
        _ status: BridgeStatus,
        operation: String,
        diagnostic: String
    ) -> BridgeError {
        BridgeError(
            status: status,
            operation: operation,
            diagnostic: diagnostic,
            rawStatus: status.rawValue
        )
    }
}

private let expectedBridgeABIVersion: UInt32 = 5

func bridgeABIFailure(operation: String) -> BridgeError? {
    let actual = orca_bridge_abi_version()
    guard actual == expectedBridgeABIVersion else {
        return .local(
            .internalInvariant,
            operation: operation,
            diagnostic: "\(operation): Bridge ABI \(actual) does not match client ABI \(expectedBridgeABIVersion)"
        )
    }
    return nil
}

/// Executes one C Bridge call and always releases its owned diagnostic.
func bridgeFailure(
    operation: String,
    call: () -> orca_result
) -> BridgeError? {
    var result = call()
    defer { orca_result_dispose(&result) }

    let rawStatus = result.code
    if rawStatus == BridgeStatus.ok.rawValue {
        guard result.diagnostic.data == nil, result.diagnostic.length == 0 else {
            return .local(
                .internalInvariant,
                operation: operation,
                diagnostic: "\(operation): successful Bridge result contained a diagnostic"
            )
        }
        return nil
    }

    guard let status = BridgeStatus(rawValue: rawStatus), status != .ok else {
        return BridgeError(
            status: .internalInvariant,
            operation: operation,
            diagnostic: "\(operation): Bridge returned unknown status \(rawStatus)",
            rawStatus: rawStatus
        )
    }

    let diagnostic: String
    if let data = result.diagnostic.data {
        guard let decoded = String(validatingCString: data) else {
            return BridgeError(
                status: .internalInvariant,
                operation: operation,
                diagnostic: "\(operation): Bridge returned a non-UTF-8 diagnostic",
                rawStatus: rawStatus
            )
        }
        diagnostic = decoded
    } else if result.diagnostic.length == 0 {
        diagnostic = "\(operation) failed with status \(status)"
    } else {
        return BridgeError(
            status: .internalInvariant,
            operation: operation,
            diagnostic: "\(operation): Bridge returned an invalid diagnostic buffer",
            rawStatus: rawStatus
        )
    }

    return BridgeError(
        status: status,
        operation: operation,
        diagnostic: diagnostic,
        rawStatus: rawStatus
    )
}

enum BridgeResult {
    static func validateABI(operation: String = "validate Bridge ABI") throws {
        if let error = bridgeABIFailure(operation: operation) { throw error }
    }

    static func consume(_ result: orca_result, operation: String) throws {
        if let error = bridgeFailure(operation: operation, call: { result }) {
            throw error
        }
    }
}

/// Copies and releases a caller-owned C Bridge string.
func consumeBridgeString(
    _ owned: inout orca_owned_string,
    operation: String
) -> Result<String, BridgeError> {
    defer { orca_owned_string_dispose(&owned) }
    guard owned.length <= UInt64(Int.max) else {
        return .failure(.local(
            .internalInvariant,
            operation: operation,
            diagnostic: "\(operation): Bridge string exceeds the client size range"
        ))
    }
    guard let data = owned.data else {
        if owned.length == 0 { return .success("") }
        return .failure(.local(
            .internalInvariant,
            operation: operation,
            diagnostic: "\(operation): Bridge returned an invalid string buffer"
        ))
    }
    guard let decoded = String(validatingCString: data),
          decoded.utf8.count == Int(owned.length) else {
        return .failure(.local(
            .internalInvariant,
            operation: operation,
            diagnostic: "\(operation): Bridge returned a non-UTF-8 or malformed string"
        ))
    }
    return .success(decoded)
}
