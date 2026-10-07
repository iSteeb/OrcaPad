import Foundation
import Observation

/// Process-lifetime owner for client stores and their Bridge sessions.
/// Presentation views borrow these references; they never own engine handles.
@MainActor
@Observable
final class AppEnvironment {
    let status: StatusCenter
    let document: DocumentStore
    let presets: PresetStore
    let slicing: SliceService
    let printHost: PrintHostService
    let printers: PrinterStore
    private(set) var isBootstrapping = false

    init() {
        let status = StatusCenter()
        self.status = status
        document = DocumentStore(status: status)
        presets = PresetStore(status: status)
        slicing = SliceService(status: status)
        printHost = PrintHostService(status: status)
        printers = PrinterStore(status: status)
    }

    /// Desktop "Open project": the document AND the preset session change
    /// together, so the preset store is held exclusive for the duration.
    func openProject(_ url: URL) async {
        if !document.isReady || !presets.isReady { await bootstrap() }
        guard let engine = presets.engineForSlicing, presets.isReady, document.isReady else {
            status.report(.document, "open project blocked: engine is not ready")
            return
        }
        await presets.withExclusiveSession {
            if await document.openProject(from: url, presets: engine) {
                await presets.reloadFromEngine()
            }
        }
    }

    func saveProject(named name: String) async {
        guard let engine = presets.engineForSlicing, presets.isReady else {
            status.report(.document, "save project blocked: presets are not ready")
            return
        }
        let bed = presets.printVolume.map(EngineBed.init) ?? EngineBed.fallback
        await presets.withExclusiveSession {
            await document.saveProject(named: name, presets: engine, bed: bed)
        }
    }

    func bootstrap() async {
        guard !isBootstrapping else { return }
        isBootstrapping = true
        defer { isBootstrapping = false }
        await document.bootstrap()
        await presets.load()
    }
}
