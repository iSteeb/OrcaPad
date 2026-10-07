import Foundation
import Observation
import OrcaBridge
import simd

/// Loads and holds the parsed toolpath for the Preview tab. The C++ document
/// stays untouched: this is a derived, read-only view of a sliced file.
@MainActor
@Observable
final class GcodePreviewStore {
    enum Phase: Equatable, Sendable {
        case idle
        case loading
        case ready
        case failed(AppFailure)
    }

    private(set) var phase: Phase = .idle
    private(set) var toolpath: GcodeToolpath?
    /// Number of layers currently visible (slider-driven, 0...layerCount).
    private(set) var visibleLayers: Int = 0
    /// Bounds of the whole toolpath in engine coordinates.
    private(set) var boundsMin: SIMD3<Float> = .zero
    private(set) var boundsMax: SIMD3<Float> = .zero

    private var isLoading = false
    private var loadedPath: String?

    var layerCount: Int { toolpath?.layers.count ?? 0 }

    var visibleSegmentCount: Int {
        guard let toolpath, visibleLayers > 0,
              visibleLayers <= toolpath.layers.count else { return 0 }
        let layer = toolpath.layers[visibleLayers - 1]
        return layer.firstSegment + layer.segmentCount
    }

    var currentLayer: ToolpathLayer? {
        guard let toolpath, visibleLayers > 0,
              visibleLayers <= toolpath.layers.count else { return nil }
        return toolpath.layers[visibleLayers - 1]
    }

    var remainingSeconds: Float {
        guard let toolpath, visibleLayers > 0,
              visibleLayers <= toolpath.layers.count else {
            return toolpath?.estimatedSeconds ?? 0
        }
        var remaining: Float = 0
        for index in visibleLayers..<toolpath.layers.count {
            remaining += toolpath.layers[index].timeSeconds
        }
        return remaining
    }

    func load(url: URL) async {
        guard !isLoading, loadedPath != url.path else { return }
        isLoading = true
        phase = .loading
        let result = await BackgroundWork.run(operation: "load gcode preview") {
            try EngineGcode.loadToolpath(path: url.path)
        }
        isLoading = false
        switch result {
        case .success(let toolpath):
            self.toolpath = toolpath
            loadedPath = url.path
            var minimum = SIMD3<Float>(repeating: .infinity)
            var maximum = SIMD3<Float>(repeating: -.infinity)
            for segment in toolpath.segments {
                minimum = simd_min(minimum, segment.start)
                minimum = simd_min(minimum, segment.end)
                maximum = simd_max(maximum, segment.start)
                maximum = simd_max(maximum, segment.end)
            }
            boundsMin = minimum
            boundsMax = maximum
            visibleLayers = toolpath.layers.count
            phase = .ready
        case .failure(let failure):
            phase = .failed(failure)
        }
    }

    func setVisibleLayers(_ count: Int) {
        guard let toolpath else { return }
        visibleLayers = min(max(count, 0), toolpath.layers.count)
    }
}

extension AppFailure: Equatable {
    static func == (lhs: AppFailure, rhs: AppFailure) -> Bool {
        lhs.localizedDescription == rhs.localizedDescription
    }
}
