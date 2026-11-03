import CoreGraphics
import AppKit
import Security

/// Screen Recording permission, checked up front instead of discovered when
/// `SCStream.startCapture()` fails.
///
/// Worth knowing: macOS ties this grant to the app's code signature. An
/// ad-hoc-signed build (no Developer ID) is identified by its cdhash, which
/// changes on every rebuild - so a grant you clicked yesterday stops applying
/// the moment you recompile. `Makefile` has a `cert` target that sets up a
/// stable self-signed identity to avoid that.
enum ScreenRecordingPermission {

    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// True when the running binary has no certificate chain, i.e. it was
    /// signed with `codesign --sign -` and its identity changes per build.
    static var isAdHocSigned: Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return true }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return true }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(
                staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return true }
        let certs = dict[kSecCodeInfoCertificates as String] as? [Any] ?? []
        return certs.isEmpty
    }

    /// Triggers the system prompt if the app has never asked before.
    /// Returns the state *after* asking.
    @discardableResult
    static func request() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        CGRequestScreenCaptureAccess()
        return CGPreflightScreenCaptureAccess()
    }

    /// Shown when the grant is missing or stale.
    static func presentHelp(rebuiltSinceGrant: Bool) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Screen Recording permission needed"
        alert.informativeText = rebuiltSinceGrant ? """
            Screen Upscaler appears in Privacy & Security but macOS no longer \
            recognises this build.

            This build is ad-hoc signed, so macOS identifies it by a hash that \
            changes every time it is recompiled - the permission you granted \
            applies to the previous build.

            Fix it permanently with a stable signing identity:
                make cert && make run

            Or, for a one-off: remove Screen Upscaler from the list below, \
            relaunch, and grant it again.
            """ : """
            Grant Screen Upscaler access under
            Privacy & Security → Screen & System Audio Recording,
            then launch it again.

            macOS only applies a new grant to a freshly launched process, so \
            the app must be relaunched after you flip the switch.
            """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Quit")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
