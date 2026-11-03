import AppKit
import Carbon.HIToolbox

/// Floating bar along the bottom of the screen: record a region, then
/// enhance the recording to a chosen resolution and frame rate.
///
///   [Live Preview] | FPS [120] Resolution [4K] Engine [Best] | [● Record] | status
///
/// Recording can be stopped from the bar, the menu-bar item, or ⌃⌥⌘S.
final class ControlBarController: NSObject, NSTextFieldDelegate {

    private let preview: PreviewWindowController
    private let selector = RegionSelector()
    private let recorder = ScreenRecorder()
    private var enhancer: VideoEnhancer?
    private var stopHotKey: GlobalHotKey?
    private var menuBarItem: NSStatusItem?
    private var recordingStarted: Date?
    private var timer: Timer?
    private var lastOutput: URL?

    private let panel: NSPanel
    private let fpsField = NSTextField()
    private let resolutionPopup = NSPopUpButton()
    private let enginePopup = NSPopUpButton()
    private let recordButton = NSButton()
    private let cancelButton = NSButton()
    private let revealButton = NSButton()
    private let progressBar = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "Ready")
    private var settingsControls: [NSControl] { [fpsField, resolutionPopup, enginePopup] }

    static let defaultsFPS = "outputFPS"
    static let defaultsResolution = "outputResolution"
    static let defaultsEngine = "enhanceEngine"

    init(preview: PreviewWindowController) {
        self.preview = preview
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 900, height: 52),
                        styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView],
                        backing: .buffered, defer: false)
        super.init()
        buildPanel()
        recorder.onStop = { [weak self] error in self?.recordingDied(error) }
    }

    func show() {
        positionPanel()
        panel.orderFrontRegardless()
    }

    // MARK: Settings

    private var outputFPS: Int {
        min(240, max(1, fpsField.integerValue))
    }

    private var settings: EnhanceSettings {
        EnhanceSettings(
            resolution: OutputResolution(rawValue: resolutionPopup.indexOfSelectedItem) ?? .p2160,
            fps: outputFPS,
            engine: EnhanceEngine(rawValue: enginePopup.indexOfSelectedItem) ?? .fast)
    }

    private func saveSettings() {
        let d = UserDefaults.standard
        d.set(outputFPS, forKey: Self.defaultsFPS)
        d.set(resolutionPopup.indexOfSelectedItem, forKey: Self.defaultsResolution)
        d.set(enginePopup.indexOfSelectedItem, forKey: Self.defaultsEngine)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        fpsField.integerValue = outputFPS
        saveSettings()
    }

    @objc private func settingChanged() {
        saveSettings()
        if settings.engine == .cloud, FalClient.storedKey == nil { promptForKey() }
    }

    // MARK: Recording

    @objc private func recordPressed() {
        if recorder.isRecording { stopRecording() } else { beginRecording() }
    }

    private func beginRecording() {
        panel.makeFirstResponder(nil)   // commit a half-typed FPS value
        selector.begin { [weak self] selection in
            guard let self, let selection else { return }
            self.startRecording(selection)
        }
    }

    private func startRecording(_ selection: RegionSelector.Selection) {
        let wanted = outputFPS
        let displayMax = max(selection.screen.maximumFramesPerSecond, 30)
        let captureFPS = min(wanted, displayMax)
        let url = Self.outputFolder.appendingPathComponent(
            "Recording \(Self.timestamp()).mov")

        Task { @MainActor in
            do {
                try await recorder.start(selection: selection, fps: captureFPS, to: url)
            } catch {
                setStatus("Recording failed: \(error.localizedDescription)")
                return
            }
            recordingStarted = Date()
            setRecordingUI(true)
            if wanted > displayMax {
                setStatus("Recording at \(displayMax) fps (display max) - output will repeat frames to reach \(wanted)")
            }
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.tickRecording()
            }
            tickRecording()
        }
    }

    @objc private func stopRecording() {
        guard recorder.isRecording else { return }
        Task { @MainActor in
            setRecordingUI(false)
            setStatus("Saving recording…")
            do {
                let result = try await recorder.stop()
                setStatus("Saved \(result.url.lastPathComponent)")
                askToProcess(result)
            } catch {
                setStatus("Recording failed: \(error.localizedDescription)")
            }
        }
    }

    private func recordingDied(_ error: Error) {
        guard recordingStarted != nil else { return }
        setRecordingUI(false)
        setStatus("Recording stopped: \(error.localizedDescription)")
    }

    private func tickRecording() {
        guard let started = recordingStarted else { return }
        let time = Self.clock(Date().timeIntervalSince(started))
        menuBarItem?.button?.title = " \(time)"
        if !statusLabel.stringValue.hasPrefix("Recording at") || Date().timeIntervalSince(started) > 4 {
            setStatus("● Recording  \(time)   ·   stop: ■ button, menu bar, or ⌃⌥⌘S")
        }
    }

    private func setRecordingUI(_ recording: Bool) {
        recordButton.title = recording ? "■ Stop" : "● Record"
        recordButton.contentTintColor = recording ? .systemRed : nil
        settingsControls.forEach { $0.isEnabled = !recording }
        revealButton.isHidden = true

        if recording {
            stopHotKey = GlobalHotKey(keyCode: kVK_ANSI_S,
                                      modifiers: controlKey | optionKey | cmdKey) { [weak self] in
                self?.stopRecording()
            }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.image = NSImage(systemSymbolName: "record.circle.fill",
                                         accessibilityDescription: "Stop recording")
            item.button?.contentTintColor = .systemRed
            item.button?.imagePosition = .imageLeading
            item.button?.target = self
            item.button?.action = #selector(stopRecording)
            item.button?.toolTip = "Stop recording (⌃⌥⌘S)"
            menuBarItem = item
        } else {
            timer?.invalidate()
            timer = nil
            recordingStarted = nil
            stopHotKey = nil
            if let menuBarItem { NSStatusBar.system.removeStatusItem(menuBarItem) }
            menuBarItem = nil
        }
    }

    // MARK: Processing

    private func askToProcess(_ result: ScreenRecorder.Result) {
        Task { @MainActor in await confirmAndProcess(result.url, recording: result) }
    }

    /// The "process this?" prompt, used after recording and for Open Video.
    /// For the cloud engine it also shows the price and makes sure a key is set.
    @MainActor
    private func confirmAndProcess(_ url: URL, recording: ScreenRecorder.Result?) async {
        let s = settings
        guard let info = try? await VideoEnhancer.inspect(url) else {
            setStatus("Can't read \(url.lastPathComponent)")
            return
        }
        let out = s.resolution.outputSize(forSource: info.size)
        let frames = recording?.frameCount ?? Int(info.duration * info.frameRate)

        var detail = """
            \(url.lastPathComponent)
            \(Int(info.size.width))×\(Int(info.size.height)), \(Self.clock(info.duration))

            Enhance to \(out.width)×\(out.height) at \(s.fps) fps using \(s.engine.title).
            """
        if s.engine == .cloud {
            let cost = VideoEnhancer.cloudCost(source: info, settings: s)
            let cloudFPS = VideoEnhancer.cloudFrameRate(source: info, outputFPS: s.fps)
            detail += """

                Estimated fal.ai charge: \(String(format: "$%.2f", cost)) \
                (\(cloudFPS) fps sent to the cloud; the rest of the \(s.fps) fps is filled in locally).

                The video is uploaded to fal.ai for processing and deleted from \
                their storage afterwards.
                """
        } else {
            detail += "\n" + Self.estimate(duration: info.duration, frames: frames, settings: s)
        }

        let alert = NSAlert()
        alert.messageText = recording == nil ? "Enhance this video?" : "Process this recording?"
        alert.informativeText = detail
        alert.addButton(withTitle: "Process Now")
        alert.addButton(withTitle: recording == nil ? "Cancel" : "Later")
        if recording != nil { alert.addButton(withTitle: "Show in Finder") }
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if s.engine == .cloud, FalClient.storedKey == nil, !promptForKey() { return }
            process(url)
        case .alertThirdButtonReturn:
            NSWorkspace.shared.activateFileViewerSelecting([url])
        default:
            break
        }
    }

    /// Asks for a fal.ai API key and stores it in the Keychain.
    @discardableResult
    @objc func promptForKey() -> Bool {
        let alert = NSAlert()
        alert.messageText = "fal.ai API key"
        alert.informativeText = """
            The Cloud engine runs FlashVSR on fal.ai, which needs an NVIDIA GPU \
            this Mac doesn't have. Create a key at fal.ai/dashboard/keys and paste \
            it here. It's stored in your Keychain.
            """
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "key-id:key-secret"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if FalClient.storedKey != nil { alert.addButton(withTitle: "Remove Key") }
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return false }
            FalClient.storeKey(key)
            setStatus("fal.ai key saved")
            return true
        case .alertThirdButtonReturn:
            FalClient.storeKey("")
            setStatus("fal.ai key removed")
            return false
        default:
            return false
        }
    }

    private func process(_ input: URL) {
        let s = settings
        let name = input.deletingPathExtension().lastPathComponent
            + " - Enhanced \(s.resolution.title) \(s.fps)fps.mov"
        let output = input.deletingLastPathComponent().appendingPathComponent(name)

        let enhancer = VideoEnhancer()
        self.enhancer = enhancer
        setProcessingUI(true)
        enhancer.onProgress = { [weak self] p in self?.showProgress(p) }

        Task { @MainActor in
            do {
                try await enhancer.run(input: input, output: output, settings: s)
                lastOutput = output
                setStatus("Done: \(output.lastPathComponent)")
                revealButton.isHidden = false
            } catch VideoEnhancer.EnhanceError.cancelled {
                setStatus("Processing cancelled")
            } catch {
                setStatus("Processing failed: \(error.localizedDescription)")
            }
            self.enhancer = nil
            setProcessingUI(false)
        }
    }

    private func showProgress(_ p: VideoEnhancer.Progress) {
        // A negative fraction means "working, no measurable progress" (cloud).
        let indeterminate = p.fraction < 0
        if progressBar.isIndeterminate != indeterminate {
            progressBar.isIndeterminate = indeterminate
            indeterminate ? progressBar.startAnimation(nil) : progressBar.stopAnimation(nil)
        }
        guard !indeterminate else { setStatus(p.stage); return }
        progressBar.doubleValue = p.fraction * 100
        var parts = ["\(p.stage) \(Int(p.fraction * 100))%"]
        if p.framesPerSecond > 0 {
            parts.append(String(format: "%.1f frames/s", p.framesPerSecond))
        }
        if let left = p.secondsRemaining, p.fraction < 1 {
            parts.append("~\(Self.clock(left)) left")
        }
        setStatus(parts.joined(separator: "  ·  "))
    }

    @objc private func cancelProcessing() {
        enhancer?.cancel()
        setStatus("Cancelling…")
    }

    @objc private func revealOutput() {
        if let lastOutput { NSWorkspace.shared.activateFileViewerSelecting([lastOutput]) }
    }

    @objc private func processExisting() {
        let open = NSOpenPanel()
        open.allowedContentTypes = [.movie]
        open.directoryURL = Self.outputFolder
        open.message = "Choose a video to enhance"
        NSApp.activate(ignoringOtherApps: true)
        guard open.runModal() == .OK, let url = open.url else { return }
        Task { @MainActor in await confirmAndProcess(url, recording: nil) }
    }

    private func setProcessingUI(_ processing: Bool) {
        progressBar.isHidden = !processing
        cancelButton.isHidden = !processing
        progressBar.stopAnimation(nil)
        progressBar.isIndeterminate = false
        progressBar.doubleValue = 0
        recordButton.isEnabled = !processing
        settingsControls.forEach { $0.isEnabled = !processing }
        if processing { revealButton.isHidden = true }
    }

    @objc private func openPreview() {
        preview.showWindow(nil)
        preview.selectRegion()
    }

    // MARK: Layout

    private func buildPanel() {
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        let d = UserDefaults.standard
        let previewButton = button("Live Preview", #selector(openPreview))
        let openButton = button("Open Video…", #selector(processExisting))

        fpsField.integerValue = d.object(forKey: Self.defaultsFPS) as? Int ?? 120
        fpsField.alignment = .right
        fpsField.delegate = self
        fpsField.toolTip = "Output frame rate (1-240)"
        let formatter = NumberFormatter()
        formatter.allowsFloats = false
        formatter.minimum = 1
        formatter.maximum = 240
        fpsField.formatter = formatter
        fpsField.widthAnchor.constraint(equalToConstant: 48).isActive = true

        resolutionPopup.addItems(withTitles: OutputResolution.allCases.map(\.title))
        resolutionPopup.selectItem(at: d.object(forKey: Self.defaultsResolution) as? Int
                                   ?? OutputResolution.p2160.rawValue)
        resolutionPopup.target = self
        resolutionPopup.action = #selector(settingChanged)

        enginePopup.autoenablesItems = false
        for e in EnhanceEngine.allCases {
            enginePopup.addItem(withTitle: e.title)
            enginePopup.lastItem?.isEnabled = e.isAvailable
        }
        enginePopup.selectItem(at: d.object(forKey: Self.defaultsEngine) as? Int
                               ?? (EnhanceEngine.esrganQuality.isAvailable ? EnhanceEngine.esrganQuality : .fast).rawValue)
        enginePopup.toolTip = """
            Real-ESRGAN Quality: most detail, on this Mac (~1 s per 4K frame).
            Real-ESRGAN Fast: crisp, on this Mac (~10 frames/s at 4K).
            Apple Best / Fast: Apple's conservative models, on this Mac.
            Cloud: FlashVSR on fal.ai - paid per megapixel, needs an API key.
            """
        enginePopup.target = self
        enginePopup.action = #selector(settingChanged)

        recordButton.title = "● Record"
        recordButton.bezelStyle = .rounded
        recordButton.target = self
        recordButton.action = #selector(recordPressed)
        recordButton.keyEquivalent = "\r"

        cancelButton.title = "Cancel"
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelProcessing)
        cancelButton.isHidden = true

        revealButton.title = "Show in Finder"
        revealButton.bezelStyle = .rounded
        revealButton.target = self
        revealButton.action = #selector(revealOutput)
        revealButton.isHidden = true

        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 100
        progressBar.isHidden = true
        progressBar.widthAnchor.constraint(equalToConstant: 120).isActive = true

        statusLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true

        let row = NSStackView(views: [
            previewButton, openButton, divider(),
            label("FPS"), fpsField,
            label("Resolution"), resolutionPopup,
            label("Engine"), enginePopup, divider(),
            recordButton, progressBar, cancelButton, revealButton, statusLabel,
        ])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        row.setCustomSpacing(4, after: row.views[3])
        row.setCustomSpacing(4, after: row.views[5])
        row.setCustomSpacing(4, after: row.views[7])

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true
        row.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            row.topAnchor.constraint(equalTo: background.topAnchor),
            row.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.setContentSize(row.fittingSize)
    }

    private func positionPanel() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 16))
    }

    private func setStatus(_ text: String) {
        statusLabel.stringValue = text
        statusLabel.toolTip = text
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        return b
    }

    private func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 11, weight: .medium)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func divider() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return box
    }

    // MARK: Helpers

    static var outputFolder: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let folder = movies.appendingPathComponent("Screen Upscaler", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f.string(from: Date())
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Rough time estimate from the throughput measured on an M4 Pro.
    private static func estimate(duration: Double, frames: Int,
                                 settings: EnhanceSettings) -> String {
        let pixels = Double(settings.resolution.box.width * settings.resolution.box.height)
        // Source frames per second at 4K, scaled roughly by output pixels.
        // Measured end to end on an M4 Pro.
        let at4K: Double
        switch settings.engine {
        case .best: at4K = 5
        case .fast: at4K = 23
        case .esrgan: at4K = 6
        case .esrganQuality: at4K = 0.6
        case .cloud: at4K = 1   // not used: the cloud prompt shows cost instead
        }
        let perSecond = at4K * (3840 * 2160) / pixels
        let seconds = Double(max(frames, 1)) / perSecond
        return "Estimated processing time: about \(clock(max(seconds, 1))) (\(frames) recorded frames)."
    }
}
