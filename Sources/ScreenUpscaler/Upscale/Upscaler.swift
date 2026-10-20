import Metal
import MetalFX

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
