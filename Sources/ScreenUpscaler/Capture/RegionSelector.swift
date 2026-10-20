import AppKit

/// Full-screen dimmed overlay that lets the user drag out a rectangle.
///
/// Reports the selection in *display-local, top-left-origin points*, which is
/// the coordinate space `SCStreamConfiguration.sourceRect` expects. AppKit
/// gives us bottom-left-origin global coordinates, so the flip happens here
/// rather than leaking into the capture layer.
final class RegionSelector {
    struct Selection {
        let screen: NSScreen
        /// Top-left-origin rect, relative to `screen`, in points.
        let sourceRect: CGRect
        /// Pixels per point for the captured display.
        let scaleFactor: CGFloat
    }

    private var windows: [SelectionWindow] = []
    private var completion: ((Selection?) -> Void)?

    func begin(completion: @escaping (Selection?) -> Void) {
        self.completion = completion
        // One overlay per screen, so a region can be picked on any display.
        windows = NSScreen.screens.map { screen in
            let w = SelectionWindow(screen: screen)
            w.onFinish = { [weak self] rect in self?.finish(screen: screen, rect: rect) }
            w.orderFrontRegardless()
            return w
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func finish(screen: NSScreen, rect: NSRect?) {
        windows.forEach { $0.close() }
        windows.removeAll()

        guard let rect, rect.width >= 16, rect.height >= 16 else {
            completion?(nil); completion = nil; return
        }

        // Global bottom-left origin -> display-local top-left origin.
        let frame = screen.frame
        let local = CGRect(x: rect.minX - frame.minX,
                           y: frame.maxY - rect.maxY,
                           width: rect.width,
                           height: rect.height)

        completion?(Selection(screen: screen,
                              sourceRect: local.integral,
                              scaleFactor: screen.backingScaleFactor))
        completion = nil
    }
}

private final class SelectionWindow: NSWindow {
    var onFinish: ((NSRect?) -> Void)?

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame,
                   styleMask: [.borderless],
                   backing: .buffered,
                   defer: false)
        setFrame(screen.frame, display: false)
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.onFinish = { [weak self] rect in
            guard let self else { return }
            // Convert view-local -> global before handing it up.
            self.onFinish?(rect.map { NSRect(x: $0.minX + screen.frame.minX,
                                             y: $0.minY + screen.frame.minY,
                                             width: $0.width, height: $0.height) })
        }
        contentView = view
        makeFirstResponder(view)
    }

    override var canBecomeKey: Bool { true }
}

private final class SelectionView: NSView {
    var onFinish: ((NSRect?) -> Void)?
    private var anchor: NSPoint?
    private var current: NSRect = .zero

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        anchor = convert(event.locationInWindow, from: nil)
        current = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor else { return }
        let p = convert(event.locationInWindow, from: nil)
        current = NSRect(x: min(anchor.x, p.x), y: min(anchor.y, p.y),
                         width: abs(p.x - anchor.x), height: abs(p.y - anchor.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        onFinish?(current.isEmpty ? nil : current)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish?(nil) }   // esc
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()

        guard !current.isEmpty else {
            drawHint(); return
        }
        // Punch the selection out of the dim layer so it reads as "live".
        NSColor.clear.setFill()
        current.fill(using: .copy)

        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(rect: current)
        border.lineWidth = 2
        border.stroke()

        let label = "\(Int(current.width)) x \(Int(current.height))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = label.size(withAttributes: attrs)
        let badge = NSRect(x: current.minX, y: current.maxY + 6,
                           width: size.width + 10, height: size.height + 6)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: badge, xRadius: 4, yRadius: 4).fill()
        label.draw(at: NSPoint(x: badge.minX + 5, y: badge.minY + 3), withAttributes: attrs)
    }

    private func drawHint() {
        let hint = "Drag to select a region  ·  esc to cancel"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9)
        ]
        let size = hint.size(withAttributes: attrs)
        hint.draw(at: NSPoint(x: bounds.midX - size.width / 2,
                              y: bounds.midY - size.height / 2), withAttributes: attrs)
    }
}
