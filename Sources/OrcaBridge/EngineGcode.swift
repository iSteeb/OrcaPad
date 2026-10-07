import Foundation
@preconcurrency import OrcaBridgeCore
import simd

/// One preview segment in canonical engine coordinates (z-up, mm).
public struct ToolpathSegment: Sendable {
    public let start: SIMD3<Float>
    public let end: SIMD3<Float>
    public let feedrate: Float
    public let width: Float
    public let height: Float
    public let mm3PerMm: Float
    public let moveType: UInt8
    public let role: UInt8
    public let extruder: UInt8
    public let layerID: UInt16
    public let printZ: Float

    public var isExtrusion: Bool { moveType == 10 } // EMoveType::Extrude
}

public struct ToolpathLayer: Sendable {
    public let z: Float
    public let firstSegment: Int
    public let segmentCount: Int
    public let timeSeconds: Float
}

/// Compact, caller-owned copy of a parsed G-code toolpath.
public struct GcodeToolpath: Sendable {
    public let segments: [ToolpathSegment]
    public let layers: [ToolpathLayer]
    public let estimatedSeconds: Float
    public let printableHeight: Float
}

public enum EngineGcode {
    /// Loads and parses a G-code file through the upstream processor and
    /// returns the compact toolpath. Blocking and CPU-heavy: run off the main
    /// thread (the engine mutex serializes it against other engine work).
    public static func loadToolpath(path: String) throws -> GcodeToolpath {
        try BridgeResult.validateABI(operation: "load gcode")
        var handle: OpaquePointer?
        try BridgeResult.consume(
            path.withCString { pathPointer in
                orca_gcode_load(pathPointer, &handle)
            },
            operation: "load gcode"
        )
        guard let handle else {
            throw BridgeError.local(
                .internalInvariant,
                operation: "load gcode",
                diagnostic: "Bridge returned success without a gcode handle"
            )
        }
        defer { orca_gcode_free(handle) }

        var raw = orca_toolpath()
        try BridgeResult.consume(
            orca_gcode_toolpath(handle, &raw),
            operation: "extract toolpath"
        )
        defer { orca_toolpath_dispose(&raw) }

        guard raw.segment_count > 0, raw.layers != nil, raw.segments != nil,
              raw.layer_count > 0 else {
            throw BridgeError.local(
                .internalInvariant,
                operation: "extract toolpath",
                diagnostic: "Bridge returned an empty toolpath"
            )
        }

        var segments: [ToolpathSegment] = []
        segments.reserveCapacity(Int(raw.segment_count))
        for index in 0..<Int(raw.segment_count) {
            let rawSegment = raw.segments[index]
            segments.append(ToolpathSegment(
                start: SIMD3(
                    rawSegment.start.0,
                    rawSegment.start.1,
                    rawSegment.start.2
                ),
                end: SIMD3(
                    rawSegment.end.0,
                    rawSegment.end.1,
                    rawSegment.end.2
                ),
                feedrate: rawSegment.feedrate,
                width: rawSegment.width,
                height: rawSegment.height,
                mm3PerMm: rawSegment.mm3_per_mm,
                moveType: rawSegment.move_type,
                role: rawSegment.role,
                extruder: rawSegment.extruder,
                layerID: rawSegment.layer_id,
                printZ: rawSegment.print_z
            ))
        }

        var layers: [ToolpathLayer] = []
        layers.reserveCapacity(Int(raw.layer_count))
        for index in 0..<Int(raw.layer_count) {
            let rawLayer = raw.layers[index]
            layers.append(ToolpathLayer(
                z: rawLayer.z,
                firstSegment: Int(rawLayer.first_segment),
                segmentCount: Int(rawLayer.segment_count),
                timeSeconds: rawLayer.time_seconds
            ))
        }

        return GcodeToolpath(
            segments: segments,
            layers: layers,
            estimatedSeconds: raw.estimated_time_seconds,
            printableHeight: raw.printable_height
        )
    }
}
