import AppKit
import CoreGraphics

// SwiftPM executables start life as a plain command-line process, so the app
// has to promote itself to a regular GUI app before any window will show.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var preview: PreviewWindowController?

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
        preview.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Check the grant before showing a selection overlay the user would
        // only get to drag around before being told it can't capture.
        guard ScreenRecordingPermission.request() else {
            // The app is listed in TCC but this build isn't recognised, which
            // on an ad-hoc signature means it was recompiled since the grant.
            ScreenRecordingPermission.presentHelp(
                rebuiltSinceGrant: CGPreflightScreenCaptureAccess() == false)
            NSApp.terminate(nil)
            return
        }

        // Jump straight into region selection - that's the first thing anyone
        // launching this wants to do.
        DispatchQueue.main.async { preview.selectRegion() }
    }

    // Deliberately false: the preview window is ordered out while the region
    // selection overlay is up, so "no visible windows" is a normal state.
    // The preview window's delegate terminates the app when it actually closes.
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
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Quit Screen Upscaler", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu
    main.addItem(appItem)
    NSApp.mainMenu = main
}
