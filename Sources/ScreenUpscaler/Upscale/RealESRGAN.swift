import Foundation
import CoreML
import CoreVideo

/// Real-ESRGAN converted to Core ML (scripts/convert-esrgan.py). Unlike
/// Apple's scalers it's a GAN: it invents plausible texture rather than only
/// recovering what's there, so results look much crisper, at the risk of a
/// slightly painted look.
///
/// The models have a fixed tile size, so frames are cut into overlapping
/// tiles; the overlap is thrown away on output so tile seams don't show.
/// Fixed shapes are what let Core ML use the Neural Engine and write into
/// our buffers. Tiles are shared between a Neural Engine and a GPU instance
/// of the model, which run side by side.
final class RealESRGAN {

    enum Variant: String {
        /// realesr-general-x4v3: ~0.1 s per 4K frame.
        case fast = "RealESRGAN-compact-512"
        /// RealESRGAN_x4plus: far more detail, ~1 s per 4K frame.
        case quality = "RealESRGAN-x4plus-256"

        var tile: Int { self == .fast ? 512 : 256 }
    }

    static let scale = 4
    /// Input pixels of context on each side of a tile that are discarded.
    private static let overlap = 16

    static let fast: RealESRGAN? = RealESRGAN(.fast)
    static let quality: RealESRGAN? = RealESRGAN(.quality)
    static func shared(_ variant: Variant) -> RealESRGAN? {
        variant == .fast ? fast : quality
    }

    static func isAvailable(_ variant: Variant) -> Bool { modelURL(variant) != nil }

    private static func modelURL(_ variant: Variant) -> URL? {
        if let dir = ProcessInfo.processInfo.environment["SCREENUPSCALER_MODELS"] {
            return URL(fileURLWithPath: dir).appendingPathComponent("\(variant.rawValue).mlpackage")
        }
        return Bundle.main.url(forResource: variant.rawValue, withExtension: "mlpackage")
    }

    enum ModelError: LocalizedError {
        case sizeMismatch, noBuffer
        var errorDescription: String? {
            switch self {
            case .sizeMismatch: "Real-ESRGAN destination must be exactly 4x the source."
            case .noBuffer: "Real-ESRGAN couldn't allocate a tile buffer."
            }
        }
    }

    /// One model instance plus the tile buffers it reads and writes.
    private final class Worker {
        let model: MLModel
        let input: CVPixelBuffer
        let output: CVPixelBuffer
        init?(url: URL, units: MLComputeUnits, tile: Int) {
            let config = MLModelConfiguration()
            config.computeUnits = units
            guard let model = try? MLModel(contentsOf: url, configuration: config),
                  let input = RealESRGAN.makeBuffer(tile, tile),
                  let output = RealESRGAN.makeBuffer(tile * RealESRGAN.scale, tile * RealESRGAN.scale)
            else { return nil }
            self.model = model
            self.input = input
            self.output = output
        }
    }

    let variant: Variant
    private let workers: [Worker]
    /// One frame at a time: live preview and file processing share instances.
    private let lock = NSLock()

    private init?(_ variant: Variant) {
        // The bundle ships .mlpackage; compiling needs no Xcode and is quick.
        guard let url = Self.modelURL(variant),
              let compiled = try? MLModel.compileModel(at: url) else { return nil }
        // The Neural Engine is the faster of the two; the GPU adds throughput.
        workers = [MLComputeUnits.cpuAndNeuralEngine, .cpuAndGPU].compactMap {
            Worker(url: compiled, units: $0, tile: variant.tile)
        }
        guard !workers.isEmpty else { return nil }
        self.variant = variant
    }

    /// Upscales `source` (BGRA, any size) into `destination` (BGRA, exactly 4x).
    func upscale(_ source: CVPixelBuffer, into destination: CVPixelBuffer) throws {
        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
        guard CVPixelBufferGetWidth(destination) == width * Self.scale,
              CVPixelBufferGetHeight(destination) == height * Self.scale else {
            throw ModelError.sizeMismatch
        }

        let tile = variant.tile, overlap = Self.overlap
        let core = tile - 2 * overlap
        let columns = (width + core - 1) / core, rows = (height + core - 1) / core
        let count = columns * rows

        lock.lock(); defer { lock.unlock() }
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }

        // Workers pull tile indices from a shared counter, so the faster unit
        // naturally takes more of them.
        var next = 0
        let counter = NSLock()
        var failure: Error?
        DispatchQueue.concurrentPerform(iterations: workers.count) { w in
            let worker = workers[w]
            while true {
                counter.lock()
                let index = next
                next += 1
                let stop = failure != nil
                counter.unlock()
                guard index < count, !stop else { return }

                let cx = (index % columns) * core, cy = (index / columns) * core
                do {
                    Self.extract(from: source, x: cx - overlap, y: cy - overlap, into: worker.input)
                    let options = MLPredictionOptions()
                    options.outputBackings = ["output": worker.output]
                    _ = try worker.model.prediction(
                        from: MLDictionaryFeatureProvider(
                            dictionary: ["input": MLFeatureValue(pixelBuffer: worker.input)]),
                        options: options)
                    Self.place(worker.output, offset: overlap * Self.scale,
                               width: min(core, width - cx) * Self.scale,
                               height: min(core, height - cy) * Self.scale,
                               into: destination, x: cx * Self.scale, y: cy * Self.scale)
                } catch {
                    counter.lock(); failure = error; counter.unlock()
                    return
                }
            }
        }
        if let failure { throw failure }
    }

    // MARK: Pixel plumbing (BGRA, 4 bytes per pixel)

    /// Copies a tile-sized window starting at (x, y) into `tile`, repeating
    /// edge pixels wherever the window hangs off the image.
    private static func extract(from source: CVPixelBuffer, x: Int, y: Int, into tile: CVPixelBuffer) {
        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
        let size = CVPixelBufferGetWidth(tile)
        CVPixelBufferLockBaseAddress(tile, [])
        defer { CVPixelBufferUnlockBaseAddress(tile, []) }
        guard let src = CVPixelBufferGetBaseAddress(source)?.assumingMemoryBound(to: UInt32.self),
              let dst = CVPixelBufferGetBaseAddress(tile)?.assumingMemoryBound(to: UInt32.self) else { return }
        let srcStride = CVPixelBufferGetBytesPerRow(source) / 4
        let dstStride = CVPixelBufferGetBytesPerRow(tile) / 4

        let first = max(0, x), last = min(width, x + size)       // in-image columns
        for row in 0..<size {
            let sy = min(max(y + row, 0), height - 1)
            let srcRow = src + sy * srcStride
            let dstRow = dst + row * dstStride
            if last > first {
                (dstRow + (first - x)).update(from: srcRow + first, count: last - first)
            }
            for col in 0..<(first - x) { dstRow[col] = srcRow[0] }
            for col in max(0, last - x)..<size { dstRow[col] = srcRow[width - 1] }
        }
    }

    /// Copies the `width` x `height` block at (offset, offset) of `tile` to (x, y) of `destination`.
    private static func place(_ tile: CVPixelBuffer, offset: Int, width: Int, height: Int,
                              into destination: CVPixelBuffer, x: Int, y: Int) {
        CVPixelBufferLockBaseAddress(tile, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(tile, .readOnly) }
        guard let src = CVPixelBufferGetBaseAddress(tile)?.assumingMemoryBound(to: UInt32.self),
              let dst = CVPixelBufferGetBaseAddress(destination)?.assumingMemoryBound(to: UInt32.self) else { return }
        let srcStride = CVPixelBufferGetBytesPerRow(tile) / 4
        let dstStride = CVPixelBufferGetBytesPerRow(destination) / 4
        for row in 0..<height {
            (dst + (y + row) * dstStride + x)
                .update(from: src + (offset + row) * srcStride + offset, count: width)
        }
    }

    static func makeBuffer(_ width: Int, _ height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                                    kCVPixelBufferMetalCompatibilityKey as String: true]
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer)
        return buffer
    }

    /// An IOSurface-backed BGRA pool, so outputs can go straight to Metal.
    static func makePool(width: Int, height: Int) -> CVPixelBufferPool? {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        return pool
    }
}
