import Foundation
import AVFoundation
import CoreImage
import Metal
import VideoToolbox

enum OutputResolution: Int, CaseIterable {
    case p1080, p1440, p2160

    var title: String {
        switch self {
        case .p1080: "1080p"
        case .p1440: "1440p"
        case .p2160: "4K"
        }
    }

    /// The box the output is fitted into, keeping the recording's aspect ratio.
    var box: CGSize {
        switch self {
        case .p1080: CGSize(width: 1920, height: 1080)
        case .p1440: CGSize(width: 2560, height: 1440)
        case .p2160: CGSize(width: 3840, height: 2160)
        }
    }

    /// Output size for a source of the given aspect. Multiples of 8 so the
    /// 4x model's input (output / 4) stays even for 4:2:0 encoding.
    func outputSize(forSource source: CGSize) -> (width: Int, height: Int) {
        let fit = min(box.width / source.width, box.height / source.height)
        let w = Int(source.width * fit) / 8 * 8
        let h = Int(source.height * fit) / 8 * 8
        return (max(8, w), max(8, h))
    }
}

enum EnhanceEngine: Int, CaseIterable {
    // Raw values are persisted, so new engines go on the end.
    case best, fast, cloud, esrgan, esrganQuality

    var title: String {
        switch self {
        case .best: "Apple Best"
        case .fast: "Apple Fast"
        case .cloud: "Cloud (FlashVSR)"
        case .esrgan: "Real-ESRGAN Fast"
        case .esrganQuality: "Real-ESRGAN Quality"
        }
    }

    var esrganVariant: RealESRGAN.Variant? {
        switch self {
        case .esrgan: .fast
        case .esrganQuality: .quality
        default: nil
        }
    }

    var isAvailable: Bool {
        if let v = esrganVariant { return RealESRGAN.isAvailable(v) }
        return self != .best || Self.bestAvailable
    }

    static var bestAvailable: Bool {
        if #available(macOS 26.0, *) { return VTSuperResolutionScalerConfiguration.isSupported }
        return false
    }
}

struct EnhanceSettings {
    let resolution: OutputResolution
    let fps: Int
    let engine: EnhanceEngine
}

/// Turns a recording into an enhanced video at a fixed resolution and frame
/// rate. Each source frame is enhanced once; the output timeline is then
/// filled at `fps` by holding each enhanced frame until the next one arrives,
/// so variable-rate screen recordings come out constant-rate.
final class VideoEnhancer {

    struct Progress {
        let fraction: Double
        let sourceFrames: Int
        let framesPerSecond: Double
        let secondsRemaining: Double?
        let stage: String
    }

    enum EnhanceError: LocalizedError {
        case noVideoTrack, cancelled, engineUnavailable(String), writerFailed(String)
        var errorDescription: String? {
            switch self {
            case .noVideoTrack: "The file has no video track."
            case .cancelled: "Processing was cancelled."
            case .engineUnavailable(let why): "Enhancement engine unavailable: \(why)"
            case .writerFailed(let why): "Could not write the output: \(why)"
            }
        }
    }

    /// Called on the main queue.
    var onProgress: ((Progress) -> Void)?

    private let cancelLock = NSLock()
    private var cancelled = false

    func cancel() {
        cancelLock.lock(); cancelled = true; cancelLock.unlock()
    }

    private var isCancelled: Bool {
        cancelLock.lock(); defer { cancelLock.unlock() }
        return cancelled
    }

    func run(input: URL, output: URL, settings: EnhanceSettings) async throws {
        let info = try await Self.inspect(input)
        let out = settings.resolution.outputSize(forSource: info.size)
        try? FileManager.default.removeItem(at: output)

        if settings.engine == .cloud {
            try await runCloud(input: input, info: info, output: output,
                               width: out.width, height: out.height, fps: settings.fps)
            return
        }

        report(0, 0, 0, nil, "Preparing…")
        let engine = try await makeEngine(settings.engine, source: info.size,
                                          outWidth: out.width, outHeight: out.height)
        try await transcode(input, to: output, engine: engine,
                            width: out.width, height: out.height, fps: settings.fps)
    }

    struct SourceInfo {
        let size: CGSize
        let duration: Double
        /// Average rate of distinct frames (screen recordings are variable-rate).
        let frameRate: Double
    }

    static func inspect(_ url: URL) async throws -> SourceInfo {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw EnhanceError.noVideoTrack
        }
        let (natural, transform, range, rate) = try await track.load(
            .naturalSize, .preferredTransform, .timeRange, .nominalFrameRate)
        let s = natural.applying(transform)
        return SourceInfo(size: CGSize(width: abs(s.width), height: abs(s.height)),
                          duration: range.duration.seconds,
                          frameRate: Double(rate > 0 ? rate : 30))
    }

    /// Decode -> enhance each frame -> re-time to `fps` -> HEVC. Runs on its
    /// own thread: the loop blocks on the encoder and the model for hours,
    /// which would starve Swift's cooperative pool.
    private func transcode(_ input: URL, to output: URL, engine: FrameEnhancer,
                           width: Int, height: Int, fps: Int,
                           stage: String = "Enhancing") async throws {
        let asset = AVURLAsset(url: input)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw EnhanceError.noVideoTrack
        }
        let duration = try await track.load(.timeRange).duration
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let thread = Thread { [self] in
                do {
                    try self.process(asset: asset, track: track, duration: duration,
                                     engine: engine, output: output,
                                     width: width, height: height, fps: fps, stage: stage)
                    c.resume()
                } catch {
                    c.resume(throwing: error)
                }
            }
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    // MARK: Cloud (FlashVSR on fal.ai)

    /// FlashVSR does 4x and crops its output to multiples of 128, so the
    /// upload is sized to a multiple of 32 near output / 4. The result is
    /// resized to the exact output locally, undoing the slight stretch.
    static func cloudInputSize(width: Int, height: Int) -> (width: Int, height: Int) {
        func up32(_ v: Int) -> Int { max(32, (v + 31) / 32 * 32) }
        return (up32(width / 4), up32(height / 4))
    }

    /// The cloud only sees distinct frames, capped at the output rate; the
    /// rest of the output frame rate is filled in locally for free.
    static func cloudFrameRate(source: SourceInfo, outputFPS: Int) -> Int {
        max(1, min(outputFPS, Int(source.frameRate.rounded())))
    }

    static func cloudCost(source: SourceInfo, settings: EnhanceSettings) -> Double {
        let out = settings.resolution.outputSize(forSource: source.size)
        let input = cloudInputSize(width: out.width, height: out.height)
        let frames = source.duration * Double(cloudFrameRate(source: source, outputFPS: settings.fps))
        let megapixels = Double(input.width * 4 * input.height * 4) * frames / 1_000_000
        return megapixels * FalClient.pricePerMegapixel
    }

    private func runCloud(input: URL, info: SourceInfo, output: URL,
                          width: Int, height: Int, fps: Int) async throws {
        guard let key = FalClient.storedKey else { throw FalClient.FalError.noKey }
        let fal = FalClient(key: key)
        let cloudIn = Self.cloudInputSize(width: width, height: height)
        let cloudFPS = Self.cloudFrameRate(source: info, outputFPS: fps)

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenUpscaler-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let prepared = work.appendingPathComponent("upload.mov")
        let enhanced = work.appendingPathComponent("flashvsr.mp4")

        // 1. shrink to the model's input size at a constant, capped rate
        try await transcode(input, to: prepared, engine: ResizeEnhancer(),
                            width: cloudIn.width, height: cloudIn.height, fps: cloudFPS,
                            stage: "Preparing upload")

        // 2. upload
        try checkCancelled()
        report(0, 0, 0, nil, "Uploading")
        let fileURL = try await fal.upload(prepared, contentType: "video/quicktime") { [weak self] f in
            self?.report(f, 0, 0, nil, "Uploading")
        }

        do {
            // 3. FlashVSR
            let job = try await fal.submit([
                "video_url": fileURL,
                "upscale_factor": 4,
                "acceleration": "regular",
                "color_fix": true,
                "output_format": "X264 (.mp4)",
                "output_quality": "maximum",
            ])
            let started = Date()
            polling: while true {
                if isCancelled {
                    await fal.cancel(job)
                    throw EnhanceError.cancelled
                }
                let elapsed = Self.clock(Date().timeIntervalSince(started))
                switch try await fal.status(job) {
                case .queued(let position):
                    report(-1, 0, 0, nil, position.map { "Queued at fal.ai (#\($0 + 1))" } ?? "Queued at fal.ai")
                case .running:
                    report(-1, 0, 0, nil, "FlashVSR running in the cloud · \(elapsed)")
                case .completed(let error):
                    if let error { throw FalClient.FalError.failed(error) }
                    break polling
                }
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }

            // 4. download
            let resultURL = try await fal.result(job)
            try await fal.download(resultURL, to: enhanced) { [weak self] f in
                self?.report(f, 0, 0, nil, "Downloading")
            }
            await fal.delete(fileURL: resultURL.absoluteString)
        } catch {
            await fal.delete(fileURL: fileURL)
            throw error
        }
        await fal.delete(fileURL: fileURL)

        // 5. exact output size and frame rate, locally
        try await transcode(enhanced, to: output, engine: ResizeEnhancer(),
                            width: width, height: height, fps: fps, stage: "Finalising")
    }

    private func checkCancelled() throws {
        if isCancelled { throw EnhanceError.cancelled }
    }

    private static func clock(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: Pipeline

    private func process(asset: AVAsset, track: AVAssetTrack, duration: CMTime,
                         engine: FrameEnhancer, output: URL,
                         width: Int, height: Int, fps: Int, stage: String) throws {
        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ])
        readerOutput.alwaysCopiesSampleData = false
        reader.add(readerOutput)

        // ~0.15 bits per pixel per frame; plenty for HEVC at these sizes.
        let bitrate = min(400_000_000, max(20_000_000, Int(Double(width * height * fps) * 0.15)))
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: fps,
            ],
        ])
        writerInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ])
        writer.add(writerInput)

        guard reader.startReading() else {
            throw EnhanceError.writerFailed(reader.error?.localizedDescription ?? "cannot read input")
        }
        guard writer.startWriting() else {
            throw EnhanceError.writerFailed(writer.error?.localizedDescription ?? "unknown")
        }
        writer.startSession(atSourceTime: .zero)

        func abort(_ error: Error) -> Error {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: output)
            return error
        }

        let frameTime = CMTime(value: 1, timescale: CMTimeScale(fps))
        var outIndex: Int64 = 0
        var held: CVPixelBuffer?
        var origin: CMTime?
        var sourceFrames = 0
        let started = CFAbsoluteTimeGetCurrent()
        var lastReport = 0.0

        // Writes the held frame for every output tick before `time`.
        func emit(until time: CMTime) throws {
            guard let held else { return }
            while CMTimeMultiply(frameTime, multiplier: Int32(outIndex)) < time {
                while !writerInput.isReadyForMoreMediaData {
                    if isCancelled { throw abort(EnhanceError.cancelled) }
                    usleep(2_000)
                }
                let t = CMTimeMultiply(frameTime, multiplier: Int32(outIndex))
                guard adaptor.append(held, withPresentationTime: t) else {
                    throw abort(EnhanceError.writerFailed(writer.error?.localizedDescription ?? "append failed"))
                }
                outIndex += 1
            }
        }

        while let sample = readerOutput.copyNextSampleBuffer() {
            if isCancelled { throw abort(EnhanceError.cancelled) }
            guard let image = sample.imageBuffer else { continue }
            let pts = sample.presentationTimeStamp
            if origin == nil { origin = pts }
            let t = pts - origin!

            try emit(until: t)

            guard let pool = adaptor.pixelBufferPool else {
                throw abort(EnhanceError.writerFailed("no pixel buffer pool"))
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw abort(EnhanceError.writerFailed("out of buffers")) }
            do { try engine.enhance(image, into: buffer) } catch { throw abort(error) }
            held = buffer
            sourceFrames += 1

            let now = CFAbsoluteTimeGetCurrent()
            if now - lastReport > 0.25 {
                lastReport = now
                let elapsed = now - started
                let fraction = min(1, max(0, t.seconds / max(duration.seconds, 0.001)))
                let remaining = fraction > 0.01 ? elapsed / fraction - elapsed : nil
                report(fraction, sourceFrames, Double(sourceFrames) / elapsed, remaining, stage)
            }
        }
        if reader.status == .failed {
            throw abort(EnhanceError.writerFailed(reader.error?.localizedDescription ?? "read failed"))
        }

        // Fill to the end of the recording, always at least one frame.
        try emit(until: CMTimeMaximum(duration, frameTime))
        writerInput.markAsFinished()
        report(1, sourceFrames, 0, 0, "Finishing…")
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status != .completed {
            throw EnhanceError.writerFailed(writer.error?.localizedDescription ?? "unknown")
        }
    }

    private func report(_ fraction: Double, _ frames: Int, _ fps: Double,
                        _ remaining: Double?, _ stage: String) {
        let p = Progress(fraction: fraction, sourceFrames: frames, framesPerSecond: fps,
                         secondsRemaining: remaining, stage: stage)
        DispatchQueue.main.async { [weak self] in self?.onProgress?(p) }
    }

    // MARK: Engines

    private func makeEngine(_ kind: EnhanceEngine, source: CGSize,
                            outWidth: Int, outHeight: Int) async throws -> FrameEnhancer {
        if let variant = kind.esrganVariant {
            report(0, 0, 0, nil, "Loading \(kind.title)…")
            guard let model = RealESRGAN.shared(variant) else {
                throw EnhanceError.engineUnavailable("\(kind.title) model missing from the app bundle")
            }
            guard let engine = ESRGANEnhancer(model: model, outWidth: outWidth, outHeight: outHeight) else {
                throw EnhanceError.engineUnavailable("out of memory")
            }
            return engine
        }
        if kind == .best, #available(macOS 26.0, *) {
            let engine = try SuperResolutionEnhancer(outWidth: outWidth, outHeight: outHeight)
            if !engine.modelReady {
                report(0, 0, 0, nil, "Downloading Apple's enhancement model…")
                try await engine.downloadModel()
            }
            try engine.start()
            return engine
        }
        guard let engine = FastEnhancer(source: source, outWidth: outWidth, outHeight: outHeight) else {
            throw EnhanceError.engineUnavailable("no Metal device")
        }
        return engine
    }
}

/// No enhancement: just resize. Used around the cloud step.
private final class ResizeEnhancer: FrameEnhancer {
    private let context = CIContext()
    func enhance(_ source: CVPixelBuffer, into destination: CVPixelBuffer) throws {
        context.render(resized(CIImage(cvPixelBuffer: source),
                               to: CVPixelBufferGetWidth(destination),
                               CVPixelBufferGetHeight(destination)), to: destination)
    }
}

protocol FrameEnhancer {
    /// Enhances `source` (BGRA, any size) into `destination` (BGRA, output size).
    func enhance(_ source: CVPixelBuffer, into destination: CVPixelBuffer) throws
}

/// Resize helper shared by both engines.
private func resized(_ image: CIImage, to width: Int, _ height: Int) -> CIImage {
    let sx = CGFloat(width) / image.extent.width
    let sy = CGFloat(height) / image.extent.height
    if abs(sx - 1) < 0.001 && abs(sy - 1) < 0.001 { return image }
    return image
        .applyingFilter("CILanczosScaleTransform",
                        parameters: [kCIInputScaleKey: sy, kCIInputAspectRatioKey: sx / sy])
        .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
}

/// Real-ESRGAN 4x: the source is resized to a quarter of the output, then
/// the model writes the full-size result straight into the encoder's buffer.
private final class ESRGANEnhancer: FrameEnhancer {
    private let model: RealESRGAN
    private let context = CIContext()
    private let input: CVPixelBuffer
    private let inWidth, inHeight, outWidth, outHeight: Int
    /// Only used if the encoder's buffer isn't exactly 4x the model input.
    private let staging: CVPixelBuffer?

    init?(model: RealESRGAN, outWidth: Int, outHeight: Int) {
        let w = outWidth / RealESRGAN.scale, h = outHeight / RealESRGAN.scale
        guard let buffer = RealESRGAN.makeBuffer(w, h) else { return nil }
        self.model = model
        input = buffer
        inWidth = w; inHeight = h
        self.outWidth = outWidth; self.outHeight = outHeight
        if w * RealESRGAN.scale != outWidth || h * RealESRGAN.scale != outHeight {
            staging = RealESRGAN.makeBuffer(w * RealESRGAN.scale, h * RealESRGAN.scale)
        } else {
            staging = nil
        }
    }

    func enhance(_ source: CVPixelBuffer, into destination: CVPixelBuffer) throws {
        context.render(resized(CIImage(cvPixelBuffer: source), to: inWidth, inHeight), to: input)
        if let staging {
            try model.upscale(input, into: staging)
            context.render(resized(CIImage(cvPixelBuffer: staging), to: outWidth, outHeight),
                           to: destination)
        } else {
            try model.upscale(input, into: destination)
        }
    }
}

/// Apple's heavy 4x super-resolution model. Uses the previous frame and its
/// output to keep detail stable over time. ~180 ms per 4K frame on M4 Pro.
@available(macOS 26.0, *)
private final class SuperResolutionEnhancer: FrameEnhancer {
    private typealias Config = VTSuperResolutionScalerConfiguration
    private static let scale = 4

    private let config: Config
    private let processor = VTFrameProcessor()
    private let context = CIContext()
    private let modelWidth, modelHeight, outWidth, outHeight: Int
    private var sources: [CVPixelBuffer] = []
    private var results: [CVPixelBuffer] = []
    private var index = 0

    init(outWidth: Int, outHeight: Int) throws {
        self.outWidth = outWidth
        self.outHeight = outHeight
        modelWidth = outWidth / Self.scale
        modelHeight = outHeight / Self.scale
        guard let config = Config(frameWidth: modelWidth, frameHeight: modelHeight,
                                  scaleFactor: Self.scale, inputType: .video,
                                  usePrecomputedFlow: false, qualityPrioritization: .normal,
                                  revision: Config.defaultRevision) else {
            throw VideoEnhancer.EnhanceError.engineUnavailable(
                "\(modelWidth)x\(modelHeight) is not a supported model input")
        }
        self.config = config
    }

    var modelReady: Bool { config.configurationModelStatus == .ready }

    func downloadModel() async throws {
        // The download can report an error even when the model ends up
        // usable, so trust the status afterwards rather than the error.
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            config.downloadConfigurationModel { _ in c.resume() }
        }
        guard modelReady else {
            throw VideoEnhancer.EnhanceError.engineUnavailable("model download failed")
        }
    }

    func start() throws {
        try processor.startSession(configuration: config)
        func make(_ w: Int, _ h: Int) throws -> CVPixelBuffer {
            var b: CVPixelBuffer?
            let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                                        kCVPixelBufferMetalCompatibilityKey as String: true]
            CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_64RGBAHalf, attrs as CFDictionary, &b)
            guard let b else { throw VideoEnhancer.EnhanceError.engineUnavailable("out of memory") }
            return b
        }
        // Two of each: the current frame plus the previous one the model looks back at.
        sources = try [make(modelWidth, modelHeight), make(modelWidth, modelHeight)]
        results = try [make(outWidth, outHeight), make(outWidth, outHeight)]
    }

    deinit { processor.endSession() }

    func enhance(_ source: CVPixelBuffer, into destination: CVPixelBuffer) throws {
        let cur = index % 2, prev = 1 - cur
        let pts = CMTime(value: Int64(index), timescale: 600)
        let prevPTS = CMTime(value: Int64(index - 1), timescale: 600)

        context.render(resized(CIImage(cvPixelBuffer: source), to: modelWidth, modelHeight),
                       to: sources[cur])

        guard let src = VTFrameProcessorFrame(buffer: sources[cur], presentationTimeStamp: pts),
              let dst = VTFrameProcessorFrame(buffer: results[cur], presentationTimeStamp: pts) else {
            throw VideoEnhancer.EnhanceError.engineUnavailable("bad frame")
        }
        let first = index == 0
        guard let params = VTSuperResolutionScalerParameters(
            sourceFrame: src,
            previousFrame: first ? nil : VTFrameProcessorFrame(buffer: sources[prev], presentationTimeStamp: prevPTS),
            previousOutputFrame: first ? nil : VTFrameProcessorFrame(buffer: results[prev], presentationTimeStamp: prevPTS),
            opticalFlow: nil,
            submissionMode: first ? .random : .sequential,
            destinationFrame: dst) else {
            throw VideoEnhancer.EnhanceError.engineUnavailable("bad parameters")
        }

        let done = DispatchSemaphore(value: 0)
        var failure: Error?
        processor.process(parameters: params) { _, error in failure = error; done.signal() }
        done.wait()
        if let failure { throw failure }
        index += 1

        context.render(CIImage(cvPixelBuffer: results[cur]), to: destination)
    }
}

/// The realtime path run offline: AI 2x (where available) then MetalFX to
/// the output size. Seconds per minute of video rather than minutes.
private final class FastEnhancer: FrameEnhancer {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let context: CIContext
    private var cache: CVMetalTextureCache?
    private let upscaler: Upscaler
    private let inWidth, inHeight: Int
    private let input: CVPixelBuffer
    private let inputTexture: MTLTexture
    private let outputTexture: MTLTexture

    init?(source: CGSize, outWidth: Int, outHeight: Int) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        context = CIContext(mtlDevice: device)
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)

        // Model input: half the output, capped at what the AI model accepts.
        var w = outWidth / 2, h = outHeight / 2
        var ai: Upscaler?
        if #available(macOS 26.0, *) {
            let cap = AIEnhanceUpscaler.maxInputDimension
            if cap > 0, max(w, h) > cap {
                let fit = Double(cap) / Double(max(w, h))
                w = Int(Double(w) * fit) & ~1
                h = Int(Double(h) * fit) & ~1
            }
            ai = AIEnhanceUpscaler(device: device, inputWidth: w, inputHeight: h,
                                   outputWidth: outWidth, outputHeight: outHeight)
        }
        if ai == nil {
            // No AI: hand MetalFX the source at (up to) native size.
            let fit = min(1, Double(outWidth) / source.width, Double(outHeight) / source.height)
            w = max(2, Int(source.width * fit) & ~1)
            h = max(2, Int(source.height * fit) & ~1)
        }
        guard let upscaler = ai ?? MetalFXUpscaler(device: device, inputWidth: w, inputHeight: h,
                                                   outputWidth: outWidth, outputHeight: outHeight)
        else { return nil }
        self.upscaler = upscaler
        inWidth = w
        inHeight = h

        var buffer: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                                    kCVPixelBufferMetalCompatibilityKey as String: true]
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer)
        guard let buffer else { return nil }
        input = buffer

        func texture(_ w: Int, _ h: Int) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite, .renderTarget]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        guard let inTex = texture(w, h), let outTex = texture(outWidth, outHeight) else { return nil }
        inputTexture = inTex
        outputTexture = outTex
    }

    func enhance(_ source: CVPixelBuffer, into destination: CVPixelBuffer) throws {
        context.render(resized(CIImage(cvPixelBuffer: source), to: inWidth, inHeight), to: input)

        guard let staged = texture(for: input), let target = texture(for: destination),
              let cb = queue.makeCommandBuffer() else {
            throw VideoEnhancer.EnhanceError.engineUnavailable("Metal setup failed")
        }
        // Cache textures lack the usage flags the scalers want, so stage
        // through private textures - the same trick the live renderer uses.
        copy(cb, from: staged, to: inputTexture)
        upscaler.encode(commandBuffer: cb, input: inputTexture, output: outputTexture)
        copy(cb, from: outputTexture, to: target)
        cb.commit()
        cb.waitUntilCompleted()
        if let error = cb.error { throw error }
    }

    private func copy(_ cb: MTLCommandBuffer, from: MTLTexture, to: MTLTexture) {
        guard let blit = cb.makeBlitCommandEncoder() else { return }
        blit.copy(from: from, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: min(from.width, to.width),
                                      height: min(from.height, to.height), depth: 1),
                  to: to, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
    }

    private func texture(for buffer: CVPixelBuffer) -> MTLTexture? {
        guard let cache else { return nil }
        var tex: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, buffer, nil, .bgra8Unorm,
            CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &tex)
        return tex.flatMap(CVMetalTextureGetTexture)
    }
}
