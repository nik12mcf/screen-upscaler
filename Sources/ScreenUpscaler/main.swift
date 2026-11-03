import AppKit
import CoreGraphics

// SwiftPM executables start life as a plain command-line process, so the app
// has to promote itself to a regular GUI app before any window will show.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var preview: PreviewWindowController?
    private var controlBar: ControlBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let preview = PreviewWindowController.make() else {
            let alert = NSAlert()
            alert.messageText = "No Metal device available"
            alert.informativeText = "Screen Upscaler needs a Metal-capable GPU."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        self.preview = preview
        NSApp.activate(ignoringOtherApps: true)

        // Check the grant before showing a selection overlay the user would
        // only get to drag around before being told it can't capture.
        guard ScreenRecordingPermission.request() else {
            // Only blame the signature when it really is ad-hoc - with a stable
            // certificate a missing grant just means it hasn't been given yet.
            ScreenRecordingPermission.presentHelp(
                rebuiltSinceGrant: ScreenRecordingPermission.isAdHocSigned)
            NSApp.terminate(nil)
            return
        }

        // The control bar is the app's home; the live preview opens from it.
        let bar = ControlBarController(preview: preview)
        controlBar = bar
        bar.show()
    }

    // The control bar is a panel, and the preview window comes and goes, so
    // quitting is explicit (⌘Q) rather than tied to the last window closing.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
buildMenu()
app.run()

private func buildMenu() {
    let main = NSMenu()
    let appItem = NSMenuItem()
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "Select Region…", action: #selector(PreviewWindowController.selectRegion), keyEquivalent: "r")
    appMenu.addItem(withTitle: "Set fal.ai API Key…", action: #selector(ControlBarController.promptForKey), keyEquivalent: "")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Quit Screen Upscaler", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu
    main.addItem(appItem)
    NSApp.mainMenu = main
}
