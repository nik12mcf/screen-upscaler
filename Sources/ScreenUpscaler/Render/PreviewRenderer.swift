import Metal
import MetalKit
import CoreVideo
import QuartzCore

/// Owns the GPU side of the pipeline:
///
///   CVPixelBuffer -> (texture cache) -> blit -> upscaler -> draw to drawable
///
/// The blit into a private texture exists because textures vended by
/// CVMetalTextureCache don't advertise the usage flags MetalFX wants. It's one
/// cheap on-GPU copy and it keeps the scalers happy.
final class PreviewRenderer: NSObject, MTKViewDelegate {

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var textureCache: CVMetalTextureCache!
    private var pipeline: MTLRenderPipelineState!
    private var sampler: MTLSamplerState!

    private var upscaler: Upscaler?
    private var inputTexture: MTLTexture?
    private var outputTexture: MTLTexture?

    /// Latest frame from the capture thread. Guarded by `frameLock`.
    private var pendingBuffer: CVPixelBuffer?
    private let frameLock = NSLock()

    /// Real-ESRGAN runs through Core ML, not a Metal command buffer, so it
    /// happens in `submit` on the capture thread and the renderer just shows
    /// its 4x output. Guarded by `frameLock`.
    private var esrganPool: CVPixelBufferPool?

    private(set) var fps: Double = 0
    private var frameCount = 0
    private var lastSample = CACurrentMediaTime()
    var onStats: ((Double, String) -> Void)?

    init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = queue
        super.init()

        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache) == kCVReturnSuccess,
              buildPipeline() else { return nil }
    }

    // MARK: Configuration

    /// Point the renderer at a new capture size / scale factor.
    func configure(inputWidth: Int, inputHeight: Int, scale: Int, mode: UpscaleMode) {
        var inputWidth = inputWidth, inputHeight = inputHeight
        var scale = scale
        var esrgan: CVPixelBufferPool?
        if mode == .realESRGAN, RealESRGAN.fast != nil {
            esrgan = RealESRGAN.makePool(width: inputWidth * RealESRGAN.scale,
                                         height: inputHeight * RealESRGAN.scale)
        }
        frameLock.lock()
        esrganPool = esrgan
        pendingBuffer = nil
        frameLock.unlock()
        if esrgan != nil {
            // Frames arrive already 4x; just display them.
            inputWidth *= RealESRGAN.scale
            inputHeight *= RealESRGAN.scale
            scale = 1
        }
        let outW = inputWidth * scale
        let outH = inputHeight * scale

        var chosen: Upscaler?
        if esrgan != nil {
            chosen = PassthroughUpscaler(name: "Real-ESRGAN 4x",
                                         width: inputWidth, height: inputHeight)
        }
        if chosen == nil, mode == .aiEnhance, #available(macOS 26.0, *) {
            chosen = AIEnhanceUpscaler(device: device,
                                       inputWidth: inputWidth, inputHeight: inputHeight,
                                       outputWidth: outW, outputHeight: outH)
        }
        if chosen == nil, mode != .bilinear {
            chosen = MetalFXUpscaler(device: device,
                                     inputWidth: inputWidth, inputHeight: inputHeight,
                                     outputWidth: outW, outputHeight: outH)
        }
        upscaler = chosen
            ?? BilinearUpscaler(inputWidth: inputWidth, inputHeight: inputHeight,
                                outputWidth: outW, outputHeight: outH)

        inputTexture = makeTexture(width: inputWidth, height: inputHeight,
                                   usage: [.shaderRead, .shaderWrite])
        outputTexture = makeTexture(width: outW, height: outH,
                                    usage: [.shaderRead, .shaderWrite, .renderTarget])
    }

    /// Called on the capture thread. With Real-ESRGAN this blocks for the
    /// model's run, so ScreenCaptureKit simply drops frames it can't keep up with.
    func submit(buffer: CVPixelBuffer) {
        frameLock.lock()
        let pool = esrganPool
        frameLock.unlock()

        var frame = buffer
        if let pool, let model = RealESRGAN.fast {
            var out: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
            guard let out, (try? model.upscale(buffer, into: out)) != nil else { return }
            frame = out
        }

        frameLock.lock()
        // Drop the result if the region/mode changed while the model ran.
        if pool == nil || esrganPool === pool { pendingBuffer = frame }
        frameLock.unlock()
    }

    private func makeTexture(width: Int, height: Int, usage: MTLTextureUsage) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.usage = usage
        d.storageMode = .private
        return device.makeTexture(descriptor: d)
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        frameLock.lock()
        let buffer = pendingBuffer
        frameLock.unlock()

        guard let buffer,
              let upscaler, let inputTexture, let outputTexture,
              let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let captured = makeTexture(from: buffer) else { return }

        // 1. captured frame -> private texture MetalFX can read
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            let w = min(captured.width, inputTexture.width)
            let h = min(captured.height, inputTexture.height)
            blit.copy(from: captured,
                      sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: w, height: h, depth: 1),
                      to: inputTexture,
                      destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding()
        }

        // 2. upscale
        upscaler.encode(commandBuffer: commandBuffer,
                        input: inputTexture, output: outputTexture)

        // 3. stretch the result across the drawable
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) {
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(outputTexture, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()

        tickStats(upscalerName: upscaler.name)
    }

    private func tickStats(upscalerName: String) {
        frameCount += 1
        let now = CACurrentMediaTime()
        let elapsed = now - lastSample
        guard elapsed >= 0.5 else { return }
        fps = Double(frameCount) / elapsed
        frameCount = 0
        lastSample = now
        let f = fps
        DispatchQueue.main.async { [weak self] in self?.onStats?(f, upscalerName) }
    }

    // MARK: Metal plumbing

    private func makeTexture(from buffer: CVPixelBuffer) -> MTLTexture? {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, buffer, nil, .bgra8Unorm, width, height, 0, &cvTexture)
        guard status == kCVReturnSuccess, let cvTexture else { return nil }
        return CVMetalTextureGetTexture(cvTexture)
    }

    private func buildPipeline() -> Bool {
        // Compiled at runtime so the package needs no .metal build rules.
        let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct VSOut {
            float4 pos [[position]];
            float2 uv;
        };

        vertex VSOut vs_main(uint vid [[vertex_id]]) {
            // One oversized triangle covers the viewport without a vertex buffer.
            const float2 corners[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
            float2 p = corners[vid];
            VSOut out;
            out.pos = float4(p, 0.0, 1.0);
            out.uv = float2((p.x + 1.0) * 0.5, 1.0 - (p.y + 1.0) * 0.5);
            return out;
        }

        fragment float4 fs_main(VSOut in [[stage_in]],
                                texture2d<float> tex [[texture(0)]],
                                sampler samp [[sampler(0)]]) {
            return tex.sample(samp, in.uv);
        }
        """

        guard let library = try? device.makeLibrary(source: source, options: nil),
              let vs = library.makeFunction(name: "vs_main"),
              let fs = library.makeFunction(name: "fs_main") else { return false }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vs
        desc.fragmentFunction = fs
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let state = try? device.makeRenderPipelineState(descriptor: desc) else { return false }
        pipeline = state

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: sd)
        return sampler != nil
    }
}
