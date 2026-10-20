import AppKit
import MetalKit

/// The live preview: a Metal view plus a small toolbar for re-selecting the
/// region and changing the scale factor.
final class PreviewWindowController: NSWindowController {

    private let device: MTLDevice
    private let renderer: PreviewRenderer
    private let capture = ScreenCapture()
    private let selector = RegionSelector()

    private var metalView: MTKView!
    private var statusLabel: NSTextField!
    private var scalePopup: NSPopUpButton!

    private var selection: RegionSelector.Selection?
    private var scaleFactor = 2

    /// `NSWindowController.init()` is non-failable, so the "no GPU" case is
    /// handled by this factory rather than a failable initializer.
    static func make() -> PreviewWindowController? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = PreviewRenderer(device: device) else { return nil }
        return PreviewWindowController(device: device, renderer: renderer)
    }

    private init(device: MTLDevice, renderer: PreviewRenderer) {
        self.device = device
        self.renderer = renderer

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Screen Upscaler"
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("PreviewWindow")
        super.init(window: window)

        buildUI()
        wireCapture()
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: UI

    private func buildUI() {
        guard let window else { return }

        metalView = MTKView(frame: .zero, device: device)
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.framebufferOnly = false
        metalView.delegate = renderer
        metalView.preferredFramesPerSecond = 60
        // Only redraw when a frame actually arrives.
        metalView.isPaused = true
        metalView.enableSetNeedsDisplay = false
        metalView.autoResizeDrawable = true

        let selectButton = NSButton(title: "Select Region…",
                                    target: self, action: #selector(selectRegion))
        selectButton.bezelStyle = .rounded
        selectButton.keyEquivalent = "r"
        selectButton.keyEquivalentModifierMask = [.command]

        scalePopup = NSPopUpButton()
        scalePopup.addItems(withTitles: ["2x", "3x", "4x"])
        scalePopup.target = self
        scalePopup.action = #selector(scaleChanged)

        statusLabel = NSTextField(labelWithString: "No region selected")
        statusLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor

        let toolbar = NSStackView(views: [selectButton, scalePopup, statusLabel])
        toolbar.orientation = .horizontal
        toolbar.spacing = 12
        toolbar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        toolbar.alignment = .centerY

        let stack = NSStackView(views: [toolbar, metalView])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.distribution = .fill
        toolbar.setContentHuggingPriority(.defaultHigh, for: .vertical)

        window.contentView = stack
        renderer.onStats = { [weak self] fps, name in
            self?.updateStatus(fps: fps, upscaler: name)
        }
    }

    private func wireCapture() {
        capture.onFrame = { [weak self] buffer in
            guard let self else { return }
            self.renderer.submit(buffer: buffer)
            // isPaused + manual draw keeps us at the capture rate rather than
            // spinning the display link when nothing has changed.
            DispatchQueue.main.async { self.metalView.draw() }
        }
        capture.onStop = { [weak self] error in
            guard let error else { return }
            self?.statusLabel.stringValue = "Capture stopped: \(error.localizedDescription)"
        }
    }

    // MARK: Actions

    @objc func selectRegion() {
        window?.orderOut(nil)
        selector.begin { [weak self] selection in
            guard let self else { return }
            self.window?.makeKeyAndOrderFront(nil)
            guard let selection else { return }
            self.selection = selection
            self.restartCapture()
        }
    }

    @objc private func scaleChanged() {
        scaleFactor = scalePopup.indexOfSelectedItem + 2
        restartCapture()
    }

    private func restartCapture() {
        guard let selection else { return }
        Task { @MainActor in
            do {
                try await capture.start(selection: selection)
                let (w, h) = capture.pixelSize
                renderer.configure(inputWidth: w, inputHeight: h, scale: scaleFactor)
                sizeWindow(toContentWidth: w * scaleFactor, height: h * scaleFactor)
            } catch {
                statusLabel.stringValue = "Capture failed: \(error.localizedDescription)"
                presentPermissionHintIfNeeded()
            }
        }
    }

    private func sizeWindow(toContentWidth width: Int, height: Int) {
        guard let window, width > 0, height > 0 else { return }
        let aspect = NSSize(width: width, height: height)
        window.contentAspectRatio = aspect

        // Fit the upscaled output on screen without exceeding the visible frame.
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame.size
            ?? NSSize(width: 1440, height: 900)
        let maxW = visible.width * 0.9
        let maxH = visible.height * 0.9 - 44        // leave room for the toolbar
        let scale = min(1, min(maxW / CGFloat(width), maxH / CGFloat(height)))
        let size = NSSize(width: CGFloat(width) * scale,
                          height: CGFloat(height) * scale + 44)
        window.setContentSize(size)
    }

    private func updateStatus(fps: Double, upscaler: String) {
        guard let selection else { return }
        let (w, h) = capture.pixelSize
        statusLabel.stringValue = String(
            format: "%d\u{00d7}%d \u{2192} %d\u{00d7}%d  ·  %@  ·  %.0f fps",
            w, h, w * scaleFactor, h * scaleFactor, upscaler, fps)
        _ = selection
    }

    fileprivate func terminateFromWindowClose() {
        Task { try? await capture.stop(); NSApp.terminate(nil) }
    }

    private func presentPermissionHintIfNeeded() {
        let alert = NSAlert()
        alert.messageText = "Screen Recording permission needed"
        alert.informativeText = """
            Grant Screen Upscaler access under
            System Settings → Privacy & Security → Screen & System Audio Recording,
            then launch the app again.
            """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}


extension PreviewWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        terminateFromWindowClose()
    }
}
