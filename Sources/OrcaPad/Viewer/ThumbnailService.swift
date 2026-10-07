import MetalKit
import OrcaBridge

/// Renders a scene snapshot to a square plate image off-screen — the
/// desktop's thumbnail render (Plater generate_thumbnails) for G-code and
/// 3MF projects. Drives a headless `Renderer` configured exactly like the
/// canvas (BGRA8 / depth32 / 4× MSAA), so geometry and shading match the
/// Plate view. Main-thread confined like the renderer.
@MainActor
enum ThumbnailService {
    static let size = 512

    static func render(scene: SceneSnapshot, bed: EngineBed) throws -> [UInt8] {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.sampleCount = 4
        var renderFailure: String?
        guard let renderer = Renderer(view: view, onStatus: { message in
            if message.contains("ERROR") { renderFailure = message }
        }) else {
            throw Renderer.ThumbnailError.resource("renderer (\(renderFailure ?? "init failed"))")
        }
        try renderer.applyScene(
            scene, bed: bed,
            selectedObjectID: nil, selectedInstanceID: nil, previewMatrix: nil
        )
        return try renderer.renderThumbnail(size: size, colorFormat: view.colorPixelFormat)
    }
}
