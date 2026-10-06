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
    private(set) var isBootstrapping = false

    init() {
        let status = StatusCenter()
        self.status = status
        document = DocumentStore(status: status)
        presets = PresetStore(status: status)
        slicing = SliceService(status: status)
    }

    func bootstrap() async {
        guard !isBootstrapping else { return }
        isBootstrapping = true
        defer { isBootstrapping = false }
        await document.bootstrap()
        await presets.load()
    }
}
