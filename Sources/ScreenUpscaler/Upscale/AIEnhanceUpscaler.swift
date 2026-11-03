import Metal
import CoreVideo
import CoreMedia
import VideoToolbox

/// ML super-resolution via VideoToolbox's low-latency scaler (macOS 26+).
/// Unlike MetalFX, which only interpolates, this is a trained model that
/// reconstructs detail - sharper text and edges, less blocky compression.
///
///   BGRA -> (compute) -> 420v -> VT super-res 2x -> 420v -> (compute) -> BGRA
///                                                           -> MetalFX for 3x/4x
///
/// The model only works in 4:2:0 YUV and only does 2x, so the colour
/// conversions and the MetalFX tail exist to fit it into the BGRA pipeline.
/// Everything is encoded into the caller's command buffer, so it stays one
/// GPU submission per frame; VT runs the model on the Neural Engine.
@available(macOS 26.0, *)
final class AIEnhanceUpscaler: Upscaler {
    private typealias Config = VTLowLatencySuperResolutionScalerConfiguration

    /// The model's fixed scale factor.
    static let modelScale = 2

    /// Largest input the model accepts, per side (960 on current hardware).
    static var maxInputDimension: Int {
        guard let d = Config.maximumDimensions else { return 0 }
        return Int(min(d.width, d.height))
    }

    static func isSupported(width: Int, height: Int) -> Bool {
        Config.isSupported
            && width % 2 == 0 && height % 2 == 0
            && Config.supportedScaleFactors(frameWidth: width, frameHeight: height)
                .contains(Float(modelScale))
    }

    let name: String
    let inputSize: MTLSize
    let outputSize: MTLSize

    private let processor = VTFrameProcessor()
    private let sourceBuffer: CVPixelBuffer
    private let destinationBuffer: CVPixelBuffer
    private var frameIndex: Int64 = 0

    // Plane views onto the two YUV buffers. The CVMetalTextures are retained
    // because the MTLTextures are only valid while they are.
    private let planeTextures: [CVMetalTexture]
    private let sourceLuma, sourceChroma, destinationLuma, destinationChroma: MTLTexture

    private let toYUV: MTLComputePipelineState
    private let toRGB: MTLComputePipelineState

    /// Holds the model's 2x output when a further MetalFX pass is needed.
    private let modelOutput: MTLTexture?
    private let tail: Upscaler?

    init?(device: MTLDevice,
          inputWidth: Int, inputHeight: Int,
          outputWidth: Int, outputHeight: Int) {
        guard Self.isSupported(width: inputWidth, height: inputHeight) else { return nil }

        let config = Config(frameWidth: inputWidth, frameHeight: inputHeight,
                            scaleFactor: Float(Self.modelScale))
        do { try processor.startSession(configuration: config) } catch { return nil }

        guard let src = Self.makeBuffer(config.sourcePixelBufferAttributes),
              let dst = Self.makeBuffer(config.destinationPixelBufferAttributes),
              let pipelines = Self.makePipelines(device: device) else {
            processor.endSession()
            return nil
        }
        sourceBuffer = src
        destinationBuffer = dst
        toYUV = pipelines.toYUV
        toRGB = pipelines.toRGB

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        var refs: [CVMetalTexture] = []
        func plane(_ buffer: CVPixelBuffer, _ index: Int, _ format: MTLPixelFormat) -> MTLTexture? {
            guard let cache else { return nil }
            let attrs = [kCVMetalTextureUsage: MTLTextureUsage([.shaderRead, .shaderWrite]).rawValue]
            var tex: CVMetalTexture?
            CVMetalTextureCacheCreateTextureFromImage(
                nil, cache, buffer, attrs as CFDictionary, format,
                CVPixelBufferGetWidthOfPlane(buffer, index),
                CVPixelBufferGetHeightOfPlane(buffer, index), index, &tex)
            guard let tex else { return nil }
            refs.append(tex)
            return CVMetalTextureGetTexture(tex)
        }
        guard let sy = plane(src, 0, .r8Unorm), let sc = plane(src, 1, .rg8Unorm),
              let dy = plane(dst, 0, .r8Unorm), let dc = plane(dst, 1, .rg8Unorm) else {
            processor.endSession()
            return nil
        }
        sourceLuma = sy; sourceChroma = sc
        destinationLuma = dy; destinationChroma = dc
        planeTextures = refs

        // 3x/4x: let the model do the first 2x, MetalFX the rest.
        let modelW = inputWidth * Self.modelScale
        let modelH = inputHeight * Self.modelScale
        if modelW == outputWidth && modelH == outputHeight {
            modelOutput = nil
            tail = nil
            name = "AI Enhance"
        } else {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: modelW, height: modelH, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            guard let tex = device.makeTexture(descriptor: d),
                  let fx = MetalFXUpscaler(device: device,
                                           inputWidth: modelW, inputHeight: modelH,
                                           outputWidth: outputWidth, outputHeight: outputHeight) else {
                processor.endSession()
                return nil
            }
            modelOutput = tex
            tail = fx
            name = "AI Enhance + MetalFX"
        }

        inputSize = MTLSize(width: inputWidth, height: inputHeight, depth: 1)
        outputSize = MTLSize(width: outputWidth, height: outputHeight, depth: 1)
    }

    deinit { processor.endSession() }

    func encode(commandBuffer: MTLCommandBuffer, input: MTLTexture, output: MTLTexture) {
        // 1. BGRA -> 420v, one thread per 2x2 block (one chroma sample)
        guard let enc = commandBuffer.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(toYUV)
        enc.setTexture(input, index: 0)
        enc.setTexture(sourceLuma, index: 1)
        enc.setTexture(sourceChroma, index: 2)
        dispatch(enc, toYUV, width: inputSize.width / 2, height: inputSize.height / 2)
        enc.endEncoding()

        // 2. the model. Runs after everything already in the buffer.
        let pts = CMTime(value: frameIndex, timescale: 600)
        frameIndex += 1
        guard let srcFrame = VTFrameProcessorFrame(buffer: sourceBuffer, presentationTimeStamp: pts),
              let dstFrame = VTFrameProcessorFrame(buffer: destinationBuffer, presentationTimeStamp: pts)
        else { return }
        processor.process(
            with: commandBuffer,
            parameters: VTLowLatencySuperResolutionScalerParameters(
                sourceFrame: srcFrame, destinationFrame: dstFrame))

        // 3. 420v -> BGRA, then the optional MetalFX tail
        let rgbTarget = modelOutput ?? output
        guard let enc = commandBuffer.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(toRGB)
        enc.setTexture(destinationLuma, index: 0)
        enc.setTexture(destinationChroma, index: 1)
        enc.setTexture(rgbTarget, index: 2)
        dispatch(enc, toRGB, width: rgbTarget.width, height: rgbTarget.height)
        enc.endEncoding()

        if let tail, let modelOutput {
            tail.encode(commandBuffer: commandBuffer, input: modelOutput, output: output)
        }
    }

    private func dispatch(_ enc: MTLComputeCommandEncoder, _ pso: MTLComputePipelineState,
                          width: Int, height: Int) {
        let w = pso.threadExecutionWidth
        let h = max(1, pso.maxTotalThreadsPerThreadgroup / w)
        enc.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
    }

    // MARK: Setup

    private static func makeBuffer(_ attributes: [String: Any]) -> CVPixelBuffer? {
        guard let width = attributes[kCVPixelBufferWidthKey as String] as? Int,
              let height = attributes[kCVPixelBufferHeightKey as String] as? Int,
              let format = attributes[kCVPixelBufferPixelFormatTypeKey as String] as? OSType
        else { return nil }
        var attrs = attributes
        attrs[kCVPixelBufferMetalCompatibilityKey as String] = true
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, width, height, format, attrs as CFDictionary, &buffer)
                == kCVReturnSuccess, let buffer else { return nil }
        // Tag it so VT interprets the YUV the same way our shaders write it.
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        return buffer
    }

    private static func makePipelines(device: MTLDevice)
        -> (toYUV: MTLComputePipelineState, toRGB: MTLComputePipelineState)? {
        // BT.709, video range - matches the attachments set in makeBuffer.
        let source = """
        #include <metal_stdlib>
        using namespace metal;

        constant float3 kLuma = float3(0.2126, 0.7152, 0.0722);

        kernel void rgb_to_yuv(texture2d<float, access::read>  rgb    [[texture(0)]],
                               texture2d<float, access::write> luma   [[texture(1)]],
                               texture2d<float, access::write> chroma [[texture(2)]],
                               uint2 gid [[thread_position_in_grid]]) {
            float2 cbcr = 0.0;
            for (uint dy = 0; dy < 2; dy++) {
                for (uint dx = 0; dx < 2; dx++) {
                    uint2 p = gid * 2 + uint2(dx, dy);
                    float3 c = rgb.read(p).rgb;
                    float y = dot(c, kLuma);
                    luma.write(float4(16.0 / 255.0 + y * 219.0 / 255.0), p);
                    cbcr += float2((c.b - y) / 1.8556, (c.r - y) / 1.5748);
                }
            }
            cbcr *= 0.25;
            chroma.write(float4(128.0 / 255.0 + cbcr * 224.0 / 255.0, 0.0, 0.0), gid);
        }

        kernel void yuv_to_rgb(texture2d<float, access::read>   luma   [[texture(0)]],
                               texture2d<float, access::sample> chroma [[texture(1)]],
                               texture2d<float, access::write>  rgb    [[texture(2)]],
                               uint2 gid [[thread_position_in_grid]]) {
            constexpr sampler s(coord::pixel, filter::linear, address::clamp_to_edge);
            float y = (luma.read(gid).r - 16.0 / 255.0) * 255.0 / 219.0;
            float2 c = (chroma.sample(s, (float2(gid) + 0.5) * 0.5).rg - 128.0 / 255.0) * 255.0 / 224.0;
            float3 col = float3(y + 1.5748 * c.y,
                                y - 0.1873 * c.x - 0.4681 * c.y,
                                y + 1.8556 * c.x);
            rgb.write(float4(saturate(col), 1.0), gid);
        }
        """
        guard let lib = try? device.makeLibrary(source: source, options: nil),
              let a = lib.makeFunction(name: "rgb_to_yuv"),
              let b = lib.makeFunction(name: "yuv_to_rgb"),
              let toYUV = try? device.makeComputePipelineState(function: a),
              let toRGB = try? device.makeComputePipelineState(function: b) else { return nil }
        return (toYUV, toRGB)
    }
}
