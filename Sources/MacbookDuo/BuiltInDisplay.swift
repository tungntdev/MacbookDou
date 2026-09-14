import AppKit
import ScreenCaptureKit

enum BuiltInDisplay {
    /// The display ID of the internal panel, or `nil` on a desktop Mac / a
    /// MacBook running with the lid closed and an external display only.
    static func directDisplayID() -> CGDirectDisplayID? {
        NSScreen.screens.first { $0.isBuiltIn }?.directDisplayID
    }

    /// Builds an `SCContentFilter` capturing only the built-in display's
    /// content, with this app's own windows excluded so the overlay can
    /// never end up capturing itself.
    static func makeFilter() async throws -> SCContentFilter? {
        guard let targetID = directDisplayID() else { return nil }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == targetID }) else { return nil }
        let ownApps = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        return SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
    }
}

extension NSScreen {
    var isBuiltIn: Bool {
        guard let number = deviceDescription[.init("NSScreenNumber")] as? NSNumber else { return false }
        return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0
    }

    var directDisplayID: CGDirectDisplayID? {
        (deviceDescription[.init("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }

    static var builtIn: NSScreen? { NSScreen.screens.first { $0.isBuiltIn } }
}
