// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

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
    /// The engine's EMoveType values. Lines are Extrude(10)/Travel(8)/Wipe(9);
    /// everything else is a POINT marker (start == end).
    public enum MoveType: UInt8, Sendable {
        case retract = 1
        case unretract = 2
        case seam = 3
        case toolChange = 4
        case colorChange = 5
        case pausePrint = 6
        case customGCode = 7
        case travel = 8
        case wipe = 9
        case extrude = 10

        public var isMarker: Bool {
            switch self {
            case .extrude, .travel, .wipe: return false
            default: return true
            }
        }
    }

    public let mm3PerMm: Float
    public let moveType: MoveType
    public let role: UInt8
    public let extruder: UInt8
    public let layerID: UInt16
    public let printZ: Float
    public let timeSeconds: Float
    public let fanSpeed: Float
    public let temperature: Float
    public let actualFeedrate: Float
    public let volumetricRate: Float
    public let actualVolumetricRate: Float
    public let pressureAdvance: Float
    public let acceleration: Float
    public let jerk: Float
    public let layerDuration: Float
    public let timeStealth: Float

    public var isExtrusion: Bool { moveType == .extrude }
    public var isPoint: Bool { moveType.isMarker }
}

public struct ToolpathLayer: Sendable {
    public let z: Float
    public let firstSegment: Int
    public let segmentCount: Int
    public let timeSeconds: Float
}

/// Per-extruder legend totals (desktop Total Estimation).
public struct ExtruderStats: Sendable {
    public let filamentDiameterMM: Float
    public let densityGCm3: Float
    public let costPerKG: Float
    public let volumeMM3: Double

    /// Consumed filament length in metres.
    public var lengthM: Double {
        let crossSection = Double(filamentDiameterMM * filamentDiameterMM) * .pi / 4
        guard crossSection > 0 else { return 0 }
        return volumeMM3 / crossSection / 1000
    }

    public var weightG: Double { Double(densityGCm3) * volumeMM3 / 1000 }
}

/// Compact, caller-owned copy of a parsed G-code toolpath.
public struct GcodeToolpath: Sendable {
    public let segments: [ToolpathSegment]
    public let layers: [ToolpathLayer]
    public let estimatedSeconds: Float
    /// Silent-mode time; 0 when identical to normal (single-mode machines).
    public let estimatedStealthSeconds: Float
    public let printableHeight: Float
    public let extruders: [ExtruderStats]
}

private func moveType(_ raw: UInt8) throws -> ToolpathSegment.MoveType {
    guard let type = ToolpathSegment.MoveType(rawValue: raw) else {
        throw BridgeError.local(
            .internalInvariant,
            operation: "load gcode",
            diagnostic: "unknown EMoveType \(raw)"
        )
    }
    return type
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
                moveType: try moveType(rawSegment.move_type),
                role: rawSegment.role,
                extruder: rawSegment.extruder,
                layerID: rawSegment.layer_id,
                printZ: rawSegment.print_z,
                timeSeconds: rawSegment.time_seconds,
                fanSpeed: rawSegment.fan_speed,
                temperature: rawSegment.temperature,
                actualFeedrate: rawSegment.actual_feedrate,
                volumetricRate: rawSegment.volumetric_rate,
                actualVolumetricRate: rawSegment.actual_volumetric_rate,
                pressureAdvance: rawSegment.pressure_advance,
                acceleration: rawSegment.acceleration,
                jerk: rawSegment.jerk,
                layerDuration: rawSegment.layer_duration,
                timeStealth: rawSegment.time_stealth
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

        // C fixed-size arrays import as 16-tuples; imported C array layout
        // is contiguous homogeneous, so byte-offset reads are exact.
        func tuple16(_ tuple: (Float, Float, Float, Float, Float, Float, Float, Float,
                               Float, Float, Float, Float, Float, Float, Float, Float),
                     _ index: Int) -> Float {
            withUnsafeBytes(of: tuple) {
                $0.loadUnaligned(fromByteOffset: index * MemoryLayout<Float>.stride, as: Float.self)
            }
        }
        func tuple16d(_ tuple: (Double, Double, Double, Double, Double, Double, Double, Double,
                                Double, Double, Double, Double, Double, Double, Double, Double),
                      _ index: Int) -> Double {
            withUnsafeBytes(of: tuple) {
                $0.loadUnaligned(fromByteOffset: index * MemoryLayout<Double>.stride, as: Double.self)
            }
        }
        var extruders: [ExtruderStats] = []
        extruders.reserveCapacity(Int(raw.extruder_count))
        precondition(raw.extruder_count <= 16)
        for index in 0..<Int(raw.extruder_count) {
            extruders.append(ExtruderStats(
                filamentDiameterMM: tuple16(raw.filament_diameters, index),
                densityGCm3: tuple16(raw.filament_densities, index),
                costPerKG: tuple16(raw.filament_costs, index),
                volumeMM3: tuple16d(raw.total_volumes, index)
            ))
        }

        return GcodeToolpath(
            segments: segments,
            layers: layers,
            estimatedSeconds: raw.estimated_time_seconds,
            estimatedStealthSeconds: raw.estimated_stealth_seconds,
            printableHeight: raw.printable_height,
            extruders: extruders
        )
    }
}
