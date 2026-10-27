// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

import Foundation
import Observation
import OrcaBridge
import simd

/// How toolpath segments are colored (desktop "color scheme" parity).
enum ToolpathColorMode: String, CaseIterable, Identifiable, Sendable {
    case feature = "Line Type"
    case speed = "Speed"
    case layerHeight = "Layer Height"
    case lineWidth = "Line Width"
    case fanSpeed = "Fan Speed"
    case temperature = "Temperature"
    case volumetricRate = "Flow"
    case actualVolumetricRate = "Actual Flow"
    case actualSpeed = "Actual Speed"
    case layerTime = "Layer Time"
    case layerTimeLog = "Layer Time (log)"
    case pressureAdvance = "Pressure Advance"
    case acceleration = "Acceleration"
    case jerk = "Jerk"
    case tool = "Tool"
    /// Desktop "ColorPrint": solid per-extruder FILAMENT colours, banding
    /// at every colour-change height (the sidebar slot colours + M600
    /// ticks), instead of a value gradient.
    case colorPrint = "ColorPrint"

    var id: String { rawValue }

    var unit: String {
        switch self {
        case .feature, .tool, .colorPrint: return ""
        case .speed, .actualSpeed: return "mm/s"
        case .layerHeight, .lineWidth: return "mm"
        case .fanSpeed: return "%"
        case .temperature: return "°C"
        case .volumetricRate: return "mm³/s"
        case .actualVolumetricRate: return "mm³/s"
        case .layerTime, .layerTimeLog, .pressureAdvance: return "s"
        case .acceleration: return "mm/s²"
        case .jerk: return "mm/s"
        }
    }
}

/// Desktop ColorPrint scheme data (GCodeViewer "filament" colour mode):
/// the per-extruder filament colour table active from each height band
/// upward. `minHeight` of the first band is -infinity (print start).
struct ColorPrintBand: Equatable, Sendable {
    let minHeight: Float
    let colours: [SIMD4<Float>]
}

/// One colour-change tick as the legend shows it.
struct ColorPrintChange: Identifiable, Sendable, Equatable {
    /// 0-based extruder index whose colour changes.
    let extruder: Int
    let height: Float
    let colour: SIMD4<Float>
    var id: String { "\(height)-\(extruder)" }
}

/// Engine ExtrusionRole display names (values are the engine's own enum —
/// see orca_bridge.h; never libvgcode's ordering).
enum ToolpathRole {
    static func name(_ role: UInt8) -> String {
        switch role {
        case 1: return "Inner wall"
        case 2: return "Outer wall"
        case 3: return "Overhang wall"
        case 4: return "Sparse infill"
        case 5: return "Internal solid infill"
        case 6: return "Top surface"
        case 7: return "Bottom surface"
        case 8: return "Ironing"
        case 9: return "Bridge"
        case 10: return "Internal bridge"
        case 11: return "Gap infill"
        case 12: return "Skirt"
        case 13: return "Brim"
        case 14: return "Support"
        case 15: return "Support interface"
        case 16: return "Support transition"
        case 17: return "Prime tower"
        case 18: return "Custom"
        case 19: return "Multiple"
        default: return "Undefined"
        }
    }
}

/// Loads and holds the parsed toolpath plus the Preview tab's view state
/// (layer range, in-layer progress, color mode, visibility filters). A
/// derived, read-only view of a sliced file — the C++ document is untouched.
@MainActor
@Observable
final class GcodePreviewStore {
    enum Phase: Equatable, Sendable {
        case idle
        case loading
        case ready
        case failed(AppFailure)
    }

    struct RoleSummary: Identifiable, Sendable {
        let role: UInt8
        let segmentCount: Int
        let timeSeconds: Float
        var id: UInt8 { role }
    }

    private(set) var phase: Phase = .idle
    private(set) var toolpath: GcodeToolpath?
    /// Plate sections of a combined slice-all G-code (empty for single-plate
    /// results and external files): marker index/name + the layer range it
    /// occupies in the concatenated toolpath.
    private(set) var sections: [EngineGcode.PlateSection] = []
    private(set) var loadedPath: String?
    /// Identity of the loaded source (slice job or external open); a new
    /// identity always reloads even when the path is unchanged.
    private(set) var loadedIdentity: String?
    private(set) var loadedURL: URL?
    private(set) var boundsMin: SIMD3<Float> = .zero
    private(set) var boundsMax: SIMD3<Float> = .zero
    private(set) var roles: [RoleSummary] = []
    private(set) var feedrateRange: ClosedRange<Float> = 0...1
    private(set) var heightRange: ClosedRange<Float> = 0...1
    private(set) var widthRange: ClosedRange<Float> = 0...1
    private(set) var fanRange: ClosedRange<Float> = 0...1
    private(set) var temperatureRange: ClosedRange<Float> = 0...1
    private(set) var volumetricRange: ClosedRange<Float> = 0...1
    private(set) var actualVolumetricRange: ClosedRange<Float> = 0...1
    private(set) var actualSpeedRange: ClosedRange<Float> = 0...1
    private(set) var layerTimeRange: ClosedRange<Float> = 0...1
    private(set) var pressureAdvanceRange: ClosedRange<Float> = 0...1
    private(set) var accelerationRange: ClosedRange<Float> = 0...1
    private(set) var jerkRange: ClosedRange<Float> = 0...1
    private(set) var toolRange: ClosedRange<Float> = 0...1
    /// Total extrusion time over all roles (legend percentages).
    private(set) var extrusionSeconds: Float = 0

    // View state (desktop: vertical layer range slider + horizontal move bar)
    private(set) var lowerLayer = 0
    private(set) var upperLayer = 0
    private(set) var topLayerProgress = 0
    var colorMode: ToolpathColorMode = .feature
    var hiddenRoles: Set<UInt8> = []
    var showTravel = false
    /// Desktop visibility options: seam markers and retraction markers
    /// (point moves exported by ABI v14).
    var showSeams = true
    var showRetractions = false
    /// Desktop visibility options: wipe moves and tool-change markers.
    var showWipes = false
    var showToolChanges = true
    /// Desktop "One layer mode": the layer range collapses onto the top
    /// handle (the slider then walks single layers).
    var oneLayerMode = false {
        didSet {
            if oneLayerMode { setLayerRange(lower: upperLayer, upper: upperLayer) }
        }
    }

    // MARK: ColorPrint scheme data (preview.color-print)

    /// Per-height-band filament colour table (nil until a toolpath loads).
    /// Renderer entry point: `colorPrintColour(extruder:height:)` — one
    /// lookup per segment in ToolpathRenderer's colour switch.
    private(set) var colorPrintBands: [ColorPrintBand] = []
    /// Extruder count the table carries (max of slots and change ticks).
    private(set) var colorPrintExtruderCount = 1
    /// Legend: the slot colours at print start.
    private(set) var colorPrintBaseColours: [SIMD4<Float>] = []
    /// Legend: every colour change, ascending.
    private(set) var colorPrintChanges: [ColorPrintChange] = []

    var estimatedStealthSeconds: Float { toolpath?.estimatedStealthSeconds ?? 0 }
    var extruderStats: [ExtruderStats] { toolpath?.extruders ?? [] }

    private var isLoading = false

    var layerCount: Int { toolpath?.layers.count ?? 0 }

    var topLayerSegmentCount: Int {
        guard let toolpath, upperLayer < toolpath.layers.count else { return 0 }
        return toolpath.layers[upperLayer].segmentCount
    }

    func layer(at index: Int) -> ToolpathLayer? {
        guard let toolpath, index >= 0, index < toolpath.layers.count else { return nil }
        return toolpath.layers[index]
    }

    /// The segment the "tool head" is at (end of the in-layer progress).
    var toolSegment: ToolpathSegment? {
        guard let toolpath, let layer = layer(at: upperLayer),
              topLayerProgress > 0 else { return nil }
        let index = layer.firstSegment + topLayerProgress - 1
        guard index < toolpath.segments.count else { return nil }
        return toolpath.segments[index]
    }

    /// Estimated time remaining after the visible top layer.
    var remainingSeconds: Float {
        guard let toolpath else { return 0 }
        var remaining: Float = 0
        for index in (upperLayer + 1)..<max(upperLayer + 1, toolpath.layers.count) {
            remaining += toolpath.layers[index].timeSeconds
        }
        return remaining
    }

    /// Colour inputs for the ColorPrint scheme, supplied by the view at
    /// load time: the Prepare filament slots' configured colours and the
    /// document's colour-change ticks (the only place a change's TARGET
    /// COLOUR lives — the toolpath's own M600 markers carry the height and
    /// extruder but no colour). External G-code files pass none; the
    /// scheme then falls back to deterministic per-extruder hues.
    private var colorPrintInputs: (
        filamentColours: [String],
        changes: [EnginePlater.CustomGcodeItem]
    ) = (filamentColours: [], changes: [])

    func load(
        url: URL,
        identity: String,
        origin: SIMD3<Float> = .zero,
        filamentColours: [String] = [],
        colourChanges: [EnginePlater.CustomGcodeItem] = []
    ) async {
        guard !isLoading, loadedIdentity != identity else { return }
        isLoading = true
        phase = .loading
        colorPrintInputs = (filamentColours: filamentColours, changes: colourChanges)
        let result = await BackgroundWork.run(operation: "load gcode preview") {
            try EngineGcode.loadToolpath(path: url.path, origin: origin)
        }
        isLoading = false
        switch result {
        case .success(let toolpath):
            loadedIdentity = identity
            loadedURL = url
            sections = []
            install(toolpath, path: "\(identity)|\(url.path)")
        case .failure(let failure):
            phase = .failed(failure)
        }
    }

    /// Loads a combined slice-all G-code: every `; ORCA_PLATE` marker
    /// section is parsed through the engine processor and shifted back to
    /// its plate's world origin, then concatenated — all plates render side
    /// by side instead of stacked on the bed origin.
    func loadPlateSections(
        url: URL,
        identity: String,
        origins: [Int: SIMD3<Float>],
        filamentColours: [String] = [],
        colourChanges: [EnginePlater.CustomGcodeItem] = []
    ) async {
        guard !isLoading, loadedIdentity != identity else { return }
        isLoading = true
        phase = .loading
        colorPrintInputs = (filamentColours: filamentColours, changes: colourChanges)
        let result = await BackgroundWork.run(operation: "load gcode plate sections") {
            try EngineGcode.loadPlateSections(path: url.path, origins: origins)
        }
        isLoading = false
        switch result {
        case .success(let loaded):
            loadedIdentity = identity
            loadedURL = url
            sections = loaded.sections
            install(loaded.toolpath, path: "\(identity)|\(url.path)|plates")
        case .failure(let failure):
            sections = []
            phase = .failed(failure)
        }
    }

    private func install(_ toolpath: GcodeToolpath, path: String) {
        var minimum = SIMD3<Float>(repeating: .infinity)
        var maximum = SIMD3<Float>(repeating: -.infinity)
        var roleCounts: [UInt8: Int] = [:]
        var roleTimes: [UInt8: Float] = [:]
        var fan = (Float.infinity, -Float.infinity)
        var temperature = (Float.infinity, -Float.infinity)
        var feed = (Float.infinity, -Float.infinity)
        var height = (Float.infinity, -Float.infinity)
        var width = (Float.infinity, -Float.infinity)
        var volumetric = (Float.infinity, -Float.infinity)
        var actualVolumetric = (Float.infinity, -Float.infinity)
        var actualSpeed = (Float.infinity, -Float.infinity)
        var layerTime = (Float.infinity, -Float.infinity)
        var pressureAdvance = (Float.infinity, -Float.infinity)
        var acceleration = (Float.infinity, -Float.infinity)
        var jerk = (Float.infinity, -Float.infinity)
        var tool = (Float.infinity, -Float.infinity)
        for segment in toolpath.segments {
            minimum = simd_min(minimum, simd_min(segment.start, segment.end))
            maximum = simd_max(maximum, simd_max(segment.start, segment.end))
            guard segment.isExtrusion else { continue }
            roleCounts[segment.role, default: 0] += 1
            roleTimes[segment.role, default: 0] += segment.timeSeconds
            fan = (min(fan.0, segment.fanSpeed), max(fan.1, segment.fanSpeed))
            temperature = (min(temperature.0, segment.temperature), max(temperature.1, segment.temperature))
            feed = (min(feed.0, segment.feedrate), max(feed.1, segment.feedrate))
            height = (min(height.0, segment.height), max(height.1, segment.height))
            width = (min(width.0, segment.width), max(width.1, segment.width))
            volumetric = (min(volumetric.0, segment.volumetricRate), max(volumetric.1, segment.volumetricRate))
            actualVolumetric = (min(actualVolumetric.0, segment.actualVolumetricRate), max(actualVolumetric.1, segment.actualVolumetricRate))
            actualSpeed = (min(actualSpeed.0, segment.actualFeedrate), max(actualSpeed.1, segment.actualFeedrate))
            layerTime = (min(layerTime.0, segment.layerDuration), max(layerTime.1, segment.layerDuration))
            pressureAdvance = (min(pressureAdvance.0, segment.pressureAdvance), max(pressureAdvance.1, segment.pressureAdvance))
            acceleration = (min(acceleration.0, segment.acceleration), max(acceleration.1, segment.acceleration))
            jerk = (min(jerk.0, segment.jerk), max(jerk.1, segment.jerk))
            tool = (min(tool.0, Float(segment.extruder)), max(tool.1, Float(segment.extruder)))
        }
        func range(_ pair: (Float, Float)) -> ClosedRange<Float> {
            guard pair.0.isFinite, pair.1.isFinite, pair.1 >= pair.0 else { return 0...1 }
            return pair.0...max(pair.1, pair.0 + 0.0001)
        }
        self.toolpath = toolpath
        loadedPath = path
        boundsMin = minimum
        boundsMax = maximum
        roles = roleCounts
            .map { RoleSummary(role: $0.key, segmentCount: $0.value, timeSeconds: roleTimes[$0.key] ?? 0) }
            .sorted { $0.role < $1.role }
        feedrateRange = range(feed)
        heightRange = range(height)
        widthRange = range(width)
        fanRange = range(fan)
        temperatureRange = range(temperature)
        volumetricRange = range(volumetric)
        actualVolumetricRange = range(actualVolumetric)
        actualSpeedRange = range(actualSpeed)
        layerTimeRange = range(layerTime)
        pressureAdvanceRange = range(pressureAdvance)
        accelerationRange = range(acceleration)
        jerkRange = range(jerk)
        toolRange = range(tool)
        extrusionSeconds = roleTimes.values.reduce(0, +)
        hiddenRoles = []
        lowerLayer = 0
        upperLayer = max(toolpath.layers.count - 1, 0)
        topLayerProgress = topLayerSegmentCount
        installColorPrintData()
        phase = .ready
    }

    // MARK: ColorPrint band building (desktop: solid extruder colours per
    // layer band, switching at every colour-change tick)

    /// Rebuilds the per-height colour table from the load-time inputs.
    /// Base = the filament slot colours; each colour-change tick (M600)
    /// replaces one extruder's colour from its height upward. Tool changes
    /// need no entry — segments already carry the active extruder.
    private func installColorPrintData() {
        let inputs = colorPrintInputs
        let changes = inputs.changes
            .filter { $0.kind == .colorChange && !$0.color.isEmpty }
            .sorted { $0.printZ < $1.printZ }
        let highestTickExtruder = changes.map(\.extruder).max() ?? 0
        let count = max(
            max(inputs.filamentColours.count, 1),
            highestTickExtruder
        )
        var base: [SIMD4<Float>] = []
        for index in 0..<count {
            let configured = index < inputs.filamentColours.count
                ? Self.parseColour(inputs.filamentColours[index])
                : nil
            base.append(configured ?? Self.defaultExtruderColour(index))
        }
        var bands = [ColorPrintBand(minHeight: -Float.infinity, colours: base)]
        var legend: [ColorPrintChange] = []
        var current = base
        for tick in changes {
            // Colour-change extruder is 1-based; 0 means "the (single)
            // extruder" — both map to index 0.
            let index = max(tick.extruder - 1, 0)
            let colour = Self.parseColour(tick.color) ?? Self.defaultExtruderColour(index)
            if index < current.count {
                current[index] = colour
            } else {
                // A tick naming an extruder beyond the slots still colors:
                // grow the table deterministically.
                while current.count < index { current.append(Self.defaultExtruderColour(current.count)) }
                current.append(colour)
            }
            bands.append(ColorPrintBand(minHeight: Float(tick.printZ), colours: current))
            legend.append(ColorPrintChange(
                extruder: index, height: Float(tick.printZ), colour: colour))
        }
        colorPrintBands = bands
        colorPrintExtruderCount = current.count
        colorPrintBaseColours = base
        colorPrintChanges = legend
    }

    /// The ColorPrint colour of one segment — the public lookup the
    /// renderer's colour switch calls:
    /// `case .colorPrint: return store.colorPrintColour(
    ///     extruder: segment.extruder, height: segment.printZ)`.
    /// Height epsilon 0.001 mm: a change set exactly at a layer's z applies
    /// from that layer upward (the tick editor snaps to layer z's).
    func colorPrintColour(extruder: UInt8, height: Float) -> SIMD4<Float> {
        let index = Int(extruder)
        var band = colorPrintBands.first ?? ColorPrintBand(
            minHeight: -Float.infinity,
            colours: [Self.defaultExtruderColour(0)])
        for candidate in colorPrintBands
        where candidate.minHeight <= height + 0.001 {
            band = candidate
        }
        guard !band.colours.isEmpty else {
            return Self.defaultExtruderColour(index)
        }
        let clamped = min(max(index, 0), band.colours.count - 1)
        return band.colours[clamped]
    }

    /// "#rrggbb" / "#rgb" → linear-ish display RGB (0…1). Named colours
    /// ("red") return nil — the caller substitutes the deterministic
    /// per-extruder default rather than guessing.
    nonisolated private static func parseColour(_ text: String) -> SIMD4<Float>? {
        let hex = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hex.hasPrefix("#") else { return nil }
        let digits = String(hex.dropFirst())
        var values: [Int]
        switch digits.count {
        case 3:
            values = (0..<3).compactMap { index in
                Int(String(digits[digits.index(digits.startIndex, offsetBy: index)]), radix: 16)
                    .map { $0 * 17 }  // 0xf → 0xff
            }
        case 6:
            values = (0..<3).compactMap { part in
                let start = digits.index(digits.startIndex, offsetBy: part * 2)
                let end = digits.index(start, offsetBy: 2)
                return Int(digits[start..<end], radix: 16)
            }
        default:
            return nil
        }
        guard values.count == 3 else { return nil }
        return SIMD4(
            Float(values[0]) / 255,
            Float(values[1]) / 255,
            Float(values[2]) / 255,
            1
        )
    }

    /// Deterministic distinct hue per extruder (golden-ratio rotation) —
    /// used when no slot colour exists (e.g. an external G-code file with
    /// no project colours).
    nonisolated private static func defaultExtruderColour(_ index: Int) -> SIMD4<Float> {
        let hue = Float((Double(index) * 0.618033988749895).truncatingRemainder(dividingBy: 1))
        let saturation: Float = 0.85
        let brightness: Float = 0.95
        // HSV → RGB (h in 0…6)
        let h = hue * 6
        let chroma = brightness * saturation
        let second = chroma * (1 - abs((h.truncatingRemainder(dividingBy: 2)) - 1))
        let offset = brightness - chroma
        let rgb: (Float, Float, Float)
        switch h {
        case ..<1: rgb = (chroma, second, 0)
        case ..<2: rgb = (second, chroma, 0)
        case ..<3: rgb = (0, chroma, second)
        case ..<4: rgb = (0, second, chroma)
        case ..<5: rgb = (second, 0, chroma)
        default: rgb = (chroma, 0, second)
        }
        return SIMD4(rgb.0 + offset, rgb.1 + offset, rgb.2 + offset, 1)
    }

    func setLayerRange(lower: Int, upper: Int) {
        let last = max(layerCount - 1, 0)
        let clampedUpper = min(max(upper, 0), last)
        var clampedLower = min(max(lower, 0), clampedUpper)
        if oneLayerMode { clampedLower = clampedUpper }
        let upperChanged = clampedUpper != upperLayer
        lowerLayer = clampedLower
        upperLayer = clampedUpper
        if upperChanged { topLayerProgress = topLayerSegmentCount }
    }

    func setTopLayerProgress(_ progress: Int) {
        topLayerProgress = min(max(progress, 0), topLayerSegmentCount)
    }

    /// Slice-all results: jumps the visible layer range onto one plate's
    /// layers, so the scrubber walks that plate only.
    func focus(section: EngineGcode.PlateSection) {
        let last = max(layerCount - 1, 0)
        let upper = min(max(section.layerRange.upperBound - 1, 0), last)
        setLayerRange(lower: min(section.layerRange.lowerBound, upper), upper: upper)
    }

    func toggleRole(_ role: UInt8) {
        if hiddenRoles.contains(role) {
            hiddenRoles.remove(role)
        } else {
            hiddenRoles.insert(role)
        }
    }
}

extension AppFailure: Equatable {
    static func == (lhs: AppFailure, rhs: AppFailure) -> Bool {
        lhs.localizedDescription == rhs.localizedDescription
    }
}
