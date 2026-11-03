import Foundation
import ScreenCaptureKit
import CoreVideo

/// Thin wrapper over ScreenCaptureKit that streams one screen region as
/// CVPixelBuffers. Frames arrive on a background queue; `onFrame` is called
/// there, so whatever consumes it must be cheap and thread-safe.
final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate {

    enum CaptureError: LocalizedError {
        case noMatchingDisplay
        var errorDescription: String? {
            "Could not find the display that region belongs to."
        }
    }

    /// Called on `queue` for every captured frame.
    var onFrame: ((CVPixelBuffer) -> Void)?
    /// Called on the main queue if the stream dies on its own.
    var onStop: ((Error?) -> Void)?

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "io.jeffersonst.screenupscaler.capture",
                                      qos: .userInteractive)

    private(set) var pixelSize: (width: Int, height: Int) = (0, 0)

    /// `maxDimension` caps the captured size per side, letting ScreenCaptureKit
    /// downscale large regions to fit what the upscaler accepts.
    func start(selection: RegionSelector.Selection, fps: Int? = nil,
               maxDimension: Int? = nil) async throws {
        try await stop()
        // Default to the display's refresh rate (120 on ProMotion) - capturing
        // faster than the screen redraws only yields duplicate frames.
        let fps = fps ?? max(selection.screen.maximumFramesPerSecond, 60)

        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)

        // NSScreen -> SCDisplay is matched on CGDirectDisplayID.
        let targetID = selection.screen.displayID
        guard let display = content.displays.first(where: { $0.displayID == targetID })
                ?? content.displays.first else {
            throw CaptureError.noMatchingDisplay
        }

        let scale = selection.scaleFactor
        let config = SCStreamConfiguration()
        config.sourceRect = selection.sourceRect
        // Capture at native pixel density, not points, or we throw away the
        // very detail the upscaler is supposed to work from.
        var width  = selection.sourceRect.width  * scale
        var height = selection.sourceRect.height * scale
        if let maxDimension, max(width, height) > CGFloat(maxDimension) {
            let fit = CGFloat(maxDimension) / max(width, height)
            width *= fit
            height *= fit
        }
        // Even sizes, since 4:2:0 chroma covers 2x2 pixel blocks.
        config.width  = max(2, Int(width)  & ~1)
        config.height = max(2, Int(height) & ~1)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 5
        config.showsCursor = true
        config.capturesAudio = false

        pixelSize = (config.width, config.height)

        // Exclude our own windows so the preview can't photograph itself.
        let ownWindows = content.windows.filter {
            $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        let filter = SCContentFilter(display: display, excludingWindows: ownWindows)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async throws {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }

        // ScreenCaptureKit emits frames even when nothing changed; those carry
        // a status of .idle and an empty surface. Rendering them is harmless
        // but wasteful, so drop anything that isn't a complete new frame.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: raw),
           status != .complete {
            return
        }

        guard let buffer = sampleBuffer.imageBuffer else { return }
        onFrame?(buffer)
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.stream = nil
            self?.onStop?(error)
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value ?? CGMainDisplayID()
    }
}
