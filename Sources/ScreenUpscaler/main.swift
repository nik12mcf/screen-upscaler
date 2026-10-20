import AppKit

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

        // Jump straight into region selection - that's the first thing anyone
        // launching this wants to do.
        DispatchQueue.main.async { preview.selectRegion() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
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
