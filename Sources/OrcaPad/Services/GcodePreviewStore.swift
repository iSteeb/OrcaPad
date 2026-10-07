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
    case actualSpeed = "Actual Speed"
    case layerTime = "Layer Time"
    case layerTimeLog = "Layer Time (log)"
    case pressureAdvance = "Pressure Advance"
    case acceleration = "Acceleration"
    case jerk = "Jerk"
    case tool = "Tool"

    var id: String { rawValue }

    var unit: String {
        switch self {
        case .feature, .tool: return ""
        case .speed, .actualSpeed: return "mm/s"
        case .layerHeight, .lineWidth: return "mm"
        case .fanSpeed: return "%"
        case .temperature: return "°C"
        case .volumetricRate: return "mm³/s"
        case .layerTime, .layerTimeLog, .pressureAdvance: return "s"
        case .acceleration: return "mm/s²"
        case .jerk: return "mm/s"
        }
    }
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

    func load(url: URL, identity: String) async {
        guard !isLoading, loadedIdentity != identity else { return }
        isLoading = true
        phase = .loading
        let result = await BackgroundWork.run(operation: "load gcode preview") {
            try EngineGcode.loadToolpath(path: url.path)
        }
        isLoading = false
        switch result {
        case .success(let toolpath):
            loadedIdentity = identity
            loadedURL = url
            install(toolpath, path: "\(identity)|\(url.path)")
        case .failure(let failure):
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
        phase = .ready
    }

    func setLayerRange(lower: Int, upper: Int) {
        let last = max(layerCount - 1, 0)
        let clampedUpper = min(max(upper, 0), last)
        let clampedLower = min(max(lower, 0), clampedUpper)
        let upperChanged = clampedUpper != upperLayer
        lowerLayer = clampedLower
        upperLayer = clampedUpper
        if upperChanged { topLayerProgress = topLayerSegmentCount }
    }

    func setTopLayerProgress(_ progress: Int) {
        topLayerProgress = min(max(progress, 0), topLayerSegmentCount)
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
