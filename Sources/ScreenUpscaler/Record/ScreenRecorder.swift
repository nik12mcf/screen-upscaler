import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreVideo

/// Records one screen region to an HEVC .mov at native pixel density.
///
/// The file is the *input* to enhancement, so it's encoded at a generous
/// bitrate: compression artefacts baked in here would just be sharpened up
/// later.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {

    struct Result {
        let url: URL
        let duration: TimeInterval
        let frameCount: Int
        let size: CGSize
    }

    enum RecorderError: LocalizedError {
        case noMatchingDisplay, writerFailed(String), noFrames
        var errorDescription: String? {
            switch self {
            case .noMatchingDisplay: "Could not find the display that region belongs to."
            case .writerFailed(let why): "Could not write the recording: \(why)"
            case .noFrames: "Nothing was recorded - the region never changed."
            }
        }
    }

    /// Called on the main queue if the stream dies on its own.
    var onStop: ((Error) -> Void)?

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private let queue = DispatchQueue(label: "io.jeffersonst.screenupscaler.record",
                                      qos: .userInitiated)

    // Touched only on `queue`.
    private var firstPTS: CMTime?
    private var lastPTS: CMTime = .zero
    private var frameCount = 0
    private var size: CGSize = .zero
    private var frameInterval = CMTime(value: 1, timescale: 60)

    func start(selection: RegionSelector.Selection, fps: Int, to url: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == selection.screen.displayID })
                ?? content.displays.first else { throw RecorderError.noMatchingDisplay }

        let scale = selection.scaleFactor
        let width  = max(2, Int(selection.sourceRect.width  * scale) & ~1)
        let height = max(2, Int(selection.sourceRect.height * scale) & ~1)

        let config = SCStreamConfiguration()
        config.sourceRect = selection.sourceRect
        config.width = width
        config.height = height
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 8
        config.showsCursor = true
        config.capturesAudio = false

        // ~0.4 bits per pixel per frame: visually lossless for screen content.
        let bitrate = max(20_000_000, Int(Double(width * height * fps) * 0.4))
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw RecorderError.writerFailed("unsupported settings") }
        writer.add(input)
        guard writer.startWriting() else {
            throw RecorderError.writerFailed(writer.error?.localizedDescription ?? "unknown")
        }

        queue.sync {
            firstPTS = nil
            frameCount = 0
            self.size = CGSize(width: width, height: height)
            frameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        }
        self.writer = writer
        self.input = input

        let ownWindows = content.windows.filter {
            $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    /// Stops capture and finalises the file.
    func stop() async throws -> Result {
        if let stream {
            self.stream = nil
            try? await stream.stopCapture()
        }
        guard let writer, let input else { throw RecorderError.writerFailed("not recording") }
        self.writer = nil
        self.input = nil

        let (first, last, count, size, frameInterval) = queue.sync {
            (firstPTS, lastPTS, frameCount, self.size, self.frameInterval)
        }
        guard let first, count > 0 else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: writer.outputURL)
            throw RecorderError.noFrames
        }
        input.markAsFinished()
        // Give the final frame one frame-interval of screen time.
        let end = last + frameInterval
        writer.endSession(atSourceTime: end)
        await writer.finishWriting()
        if writer.status != .completed {
            throw RecorderError.writerFailed(writer.error?.localizedDescription ?? "unknown")
        }
        let duration = end - first
        return Result(url: writer.outputURL, duration: duration.seconds,
                      frameCount: count, size: size)
    }

    var isRecording: Bool { stream != nil }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let writer, let input, writer.status == .writing else { return }

        // Idle frames (nothing changed) carry no image - skip them; the
        // previous frame simply stays on screen longer in the file.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: raw), status != .complete {
            return
        }

        let pts = sampleBuffer.presentationTimeStamp
        if firstPTS == nil {
            firstPTS = pts
            writer.startSession(atSourceTime: pts)
        }
        guard input.isReadyForMoreMediaData else { return }   // encoder behind: drop
        if input.append(sampleBuffer) {
            frameCount += 1
            lastPTS = pts
        }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in self?.onStop?(error) }
    }
}
