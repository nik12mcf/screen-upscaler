import Metal
import MetalFX
import VideoToolbox

/// An upscaler turns a small input texture into a larger output texture on the
/// GPU. Everything here is encoded into a caller-supplied command buffer so a
/// whole frame stays in one GPU submission.
protocol Upscaler: AnyObject {
    var name: String { get }
    var inputSize: MTLSize { get }
    var outputSize: MTLSize { get }
    func encode(commandBuffer: MTLCommandBuffer, input: MTLTexture, output: MTLTexture)
}

/// MetalFX spatial upscaling - Apple's built-in, single-frame scaler.
/// Costs roughly 1-2 ms at 1080p -> 4K on Apple silicon, which is what makes
/// 60 fps realistic.
final class MetalFXUpscaler: Upscaler {
    let name = "MetalFX Spatial"
    let inputSize: MTLSize
    let outputSize: MTLSize
    private let scaler: MTLFXSpatialScaler

    init?(device: MTLDevice,
          inputWidth: Int, inputHeight: Int,
          outputWidth: Int, outputHeight: Int,
          pixelFormat: MTLPixelFormat = .bgra8Unorm) {
        let desc = MTLFXSpatialScalerDescriptor()
        desc.inputWidth = inputWidth
        desc.inputHeight = inputHeight
        desc.outputWidth = outputWidth
        desc.outputHeight = outputHeight
        desc.colorTextureFormat = pixelFormat
        desc.outputTextureFormat = pixelFormat
        // Screen content is already in a display colour space, so tell MetalFX
        // to treat it perceptually rather than as linear HDR.
        desc.colorProcessingMode = .perceptual

        guard let scaler = desc.makeSpatialScaler(device: device) else { return nil }
        self.scaler = scaler
        self.inputSize = MTLSize(width: inputWidth, height: inputHeight, depth: 1)
        self.outputSize = MTLSize(width: outputWidth, height: outputHeight, depth: 1)
    }

    func encode(commandBuffer: MTLCommandBuffer, input: MTLTexture, output: MTLTexture) {
        scaler.colorTexture = input
        scaler.outputTexture = output
        scaler.encode(commandBuffer: commandBuffer)
    }
}

/// Plain bilinear scaling via a blit. Useful as an A/B baseline - run this next
/// to MetalFX to see what the fancy scaler is actually buying you.
final class BilinearUpscaler: Upscaler {
    let name = "Bilinear (baseline)"
    let inputSize: MTLSize
    let outputSize: MTLSize

    init(inputWidth: Int, inputHeight: Int, outputWidth: Int, outputHeight: Int) {
        inputSize = MTLSize(width: inputWidth, height: inputHeight, depth: 1)
        outputSize = MTLSize(width: outputWidth, height: outputHeight, depth: 1)
    }

    func encode(commandBuffer: MTLCommandBuffer, input: MTLTexture, output: MTLTexture) {
        // The renderer's sampler is already linear, so "bilinear" here just
        // means: hand the small texture through untouched and let the final
        // draw stretch it.
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        let w = min(input.width, output.width)
        let h = min(input.height, output.height)
        blit.copy(from: input,
                  sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: w, height: h, depth: 1),
                  to: output,
                  destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
    }
}

/// For frames that were already upscaled before reaching the renderer.
final class PassthroughUpscaler: Upscaler {
    let name: String
    let inputSize: MTLSize
    let outputSize: MTLSize
    private let copy: BilinearUpscaler

    init(name: String, width: Int, height: Int) {
        self.name = name
        inputSize = MTLSize(width: width, height: height, depth: 1)
        outputSize = inputSize
        copy = BilinearUpscaler(inputWidth: width, inputHeight: height,
                                outputWidth: width, outputHeight: height)
    }

    func encode(commandBuffer: MTLCommandBuffer, input: MTLTexture, output: MTLTexture) {
        copy.encode(commandBuffer: commandBuffer, input: input, output: output)
    }
}

/// What the user picked in the toolbar. The renderer falls back down this list
/// (AI -> MetalFX -> bilinear) when a mode can't handle the current input.
enum UpscaleMode: Int, CaseIterable {
    case realESRGAN, aiEnhance, metalFX, bilinear

    var title: String {
        switch self {
        case .realESRGAN: "Real-ESRGAN"
        case .aiEnhance:  "AI Enhance"
        case .metalFX:    "MetalFX"
        case .bilinear:   "Bilinear"
        }
    }

    var isAvailable: Bool {
        switch self {
        case .realESRGAN: RealESRGAN.isAvailable(.fast)
        case .aiEnhance:  Self.aiAvailable
        case .metalFX, .bilinear: true
        }
    }

    /// Modes with a fixed scale factor override the toolbar's 2x/3x/4x.
    var fixedScale: Int? { self == .realESRGAN ? RealESRGAN.scale : nil }

    static var aiAvailable: Bool {
        if #available(macOS 26.0, *) {
            return VTLowLatencySuperResolutionScalerConfiguration.isSupported
        }
        return false
    }

    /// Largest capture side this mode can take, or nil for no limit.
    var maxInputDimension: Int? {
        // Real-ESRGAN runs ~25 fps at 480x272 in and slows with area, so the
        // live capture is kept small; recordings can use the full size.
        if self == .realESRGAN { return 480 }
        guard self == .aiEnhance, #available(macOS 26.0, *) else { return nil }
        return AIEnhanceUpscaler.maxInputDimension
    }
}
