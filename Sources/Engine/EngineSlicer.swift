import Foundation
import OrcaCore

/// Full slice orchestration over the engine pipeline.
public enum EngineSlicer {

    public struct Outcome: Sendable {
        public let timeEstimateSeconds: Double
        public let gcodeBytes: Int
    }

    /// Blocking — call off the main thread. Progress fires on the calling
    /// thread; hop to main in the consumer.
    public static func sliceToGcode(
        stlPath: String,
        gcodePath: String,
        progress: @escaping @Sendable (Int, String) -> Void
    ) -> Result<Outcome, EngineError> {
        final class ProgressBox: @unchecked Sendable {
            let cb: @Sendable (Int, String) -> Void
            init(_ cb: @escaping @Sendable (Int, String) -> Void) { self.cb = cb }
        }
        let box = ProgressBox(progress)
        let cCallback: orca_progress_fn? = { percent, message, raw in
            guard let raw else { return }
            let box = Unmanaged<ProgressBox>.fromOpaque(raw).takeUnretainedValue()
            box.cb(Int(percent), message.map { String(cString: $0) } ?? "")
        }

        var timeEstimate: Double = 0
        var gcodeBytes = 0  // C long imports as Int
        let status = stlPath.withCString { sp in
            gcodePath.withCString { gp in
                String(cString: orca_slice_to_gcode(
                    sp, gp, cCallback,
                    Unmanaged.passUnretained(box).toOpaque(),
                    &timeEstimate, &gcodeBytes))
            }
        }
        guard status.contains("slice ok") else {
            return .failure(EngineError(message: status))
        }
        return .success(Outcome(timeEstimateSeconds: timeEstimate, gcodeBytes: gcodeBytes))
    }
}
