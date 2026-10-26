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
    /// `origin` shifts X/Y/Z of every segment (plate-relative slice output
    /// is placed back at its world position for the viewer).
    public static func loadToolpath(
        path: String,
        origin: SIMD3<Float> = .zero
    ) throws -> GcodeToolpath {
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
                    rawSegment.start.0 + origin.x,
                    rawSegment.start.1 + origin.y,
                    rawSegment.start.2 + origin.z
                ),
                end: SIMD3(
                    rawSegment.end.0 + origin.x,
                    rawSegment.end.1 + origin.y,
                    rawSegment.end.2 + origin.z
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

    // MARK: Combined slice-all G-code (plate sections)

    /// One `; ORCA_PLATE` section of a combined slice-all G-code: the
    /// document plate it was sliced from and the layer range it occupies in
    /// the concatenated toolpath.
    public struct PlateSection: Sendable, Equatable {
        /// Document plate index, 0-based (the marker line writes it 1-based).
        public let plateIndex: Int
        public let name: String
        public let layerRange: Range<Int>
        public let estimatedSeconds: Float
    }

    /// Loads a combined slice-all G-code: splits it at the `; ORCA_PLATE
    /// ... begin/end` markers, parses every section through the engine
    /// processor (each section is a complete, self-contained per-plate
    /// G-code), shifts it back to world coordinates with `origins` (document
    /// plate index -> plate origin), and concatenates the toolpaths. Without
    /// this, every plate's plate-relative coordinates would stack onto the
    /// bed origin in the viewer. Section temp files land in the system temp
    /// directory (OS-managed) and are not tracked.
    public static func loadPlateSections(
        path: String,
        origins: [Int: SIMD3<Float>]
    ) throws -> (toolpath: GcodeToolpath, sections: [PlateSection]) {
        let operation = "load gcode plate sections"
        let url = URL(fileURLWithPath: path)
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw BridgeError.local(
                .ioFailure, operation: operation,
                diagnostic: "could not read the combined G-code: \(error.localizedDescription)"
            )
        }

        // 1) split at the marker lines (marker-safe names: no quotes/newlines)
        struct RawSection {
            let plateIndex: Int
            let name: String
            var lines: [String]
        }
        var open: RawSection?
        var parsed: [RawSection] = []
        for lineSubsequence in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(lineSubsequence)
            if line.hasSuffix("\r") { line.removeLast() }
            guard line.hasPrefix("; ORCA_PLATE") else {
                open?.lines.append(line)
                continue
            }
            if line.hasSuffix(" begin"), let begin = parsePlateBeginMarker(line) {
                guard open == nil else {
                    throw BridgeError.local(
                        .invalidModel, operation: operation,
                        diagnostic: "plate marker begins inside a plate section")
                }
                open = RawSection(plateIndex: begin.index, name: begin.name, lines: [])
            } else if line.hasSuffix(" end") {
                guard let section = open else {
                    throw BridgeError.local(
                        .invalidModel, operation: operation,
                        diagnostic: "plate marker ends without a begin")
                }
                parsed.append(section)
                open = nil
            } else {
                open?.lines.append(line)
            }
        }
        guard open == nil else {
            throw BridgeError.local(
                .invalidModel, operation: operation,
                diagnostic: "the last plate section has no end marker")
        }
        guard !parsed.isEmpty else {
            throw BridgeError.local(
                .invalidModel, operation: operation,
                diagnostic: "the combined G-code contains no plate markers")
        }

        // 2) parse every section through the processor and concatenate
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gcode-sections", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        } catch {
            throw BridgeError.local(
                .ioFailure, operation: operation,
                diagnostic: "could not create the gcode section temp dir: \(error.localizedDescription)"
            )
        }

        var segments: [ToolpathSegment] = []
        var layers: [ToolpathLayer] = []
        var seconds: Float = 0
        var stealthSeconds: Float = 0
        var printableHeight: Float = 0
        var extruders: [ExtruderStats] = []
        var sections: [PlateSection] = []
        for raw in parsed {
            let sectionURL = directory.appendingPathComponent(
                "plate-\(raw.plateIndex)-\(UUID().uuidString).gcode")
            do {
                try Data(raw.lines.joined(separator: "\n").utf8).write(to: sectionURL)
            } catch {
                throw BridgeError.local(
                    .ioFailure, operation: operation,
                    diagnostic: "could not write a gcode section: \(error.localizedDescription)"
                )
            }
            let origin = origins[raw.plateIndex] ?? .zero
            let toolpath = try loadToolpath(path: sectionURL.path, origin: origin)
            let layerBase = layers.count
            layers.append(contentsOf: toolpath.layers.map { layer in
                ToolpathLayer(
                    z: layer.z,
                    firstSegment: layer.firstSegment + segments.count,
                    segmentCount: layer.segmentCount,
                    timeSeconds: layer.timeSeconds
                )
            })
            segments.append(contentsOf: toolpath.segments)
            seconds += toolpath.estimatedSeconds
            stealthSeconds += toolpath.estimatedStealthSeconds
            printableHeight = max(printableHeight, toolpath.printableHeight)
            extruders = Self.mergeExtruders(extruders, toolpath.extruders)
            sections.append(PlateSection(
                plateIndex: raw.plateIndex,
                name: raw.name,
                layerRange: layerBase..<(layerBase + toolpath.layers.count),
                estimatedSeconds: toolpath.estimatedSeconds
            ))
        }
        return (
            GcodeToolpath(
                segments: segments,
                layers: layers,
                estimatedSeconds: seconds,
                estimatedStealthSeconds: stealthSeconds,
                printableHeight: printableHeight,
                extruders: extruders
            ),
            sections
        )
    }

    /// Combines per-extruder legend stats of concatenated plate sections:
    /// volumes sum; diameter/density/cost come from a section that actually
    /// extruded with that tool (the first with a non-zero volume).
    private static func mergeExtruders(
        _ base: [ExtruderStats], _ more: [ExtruderStats]
    ) -> [ExtruderStats] {
        guard !base.isEmpty else { return more }
        guard !more.isEmpty else { return base }
        var merged = base
        for index in more.indices {
            guard index < merged.count else {
                merged.append(more[index])
                continue
            }
            let a = merged[index]
            let b = more[index]
            let pick: ExtruderStats = b.volumeMM3 > 0 ? b : a
            merged[index] = ExtruderStats(
                filamentDiameterMM: pick.filamentDiameterMM,
                densityGCm3: pick.densityGCm3,
                costPerKG: pick.costPerKG,
                volumeMM3: a.volumeMM3 + b.volumeMM3
            )
        }
        return merged
    }

    /// `; ORCA_PLATE index=2 total=3 name="Benchy plate" begin` →
    /// (document plate index 0-based, plate name).
    private static func parsePlateBeginMarker(_ line: String) -> (index: Int, name: String)? {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        var index: Int?
        var name = ""
        for field in fields {
            if field.hasPrefix("index="),
               let value = Int(field.dropFirst("index=".count)) {
                index = value - 1  // marker is 1-based
            }
            if field.hasPrefix("name=\"") {
                var value = String(field.dropFirst("name=\"".count))
                if value.hasSuffix("\"") { value.removeLast() }
                name = value
            }
        }
        guard let index, index >= 0 else { return nil }
        return (index, name)
    }
}
