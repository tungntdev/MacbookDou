import AppKit
import CoreGraphics

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings: Settings!
    private var controller: EffectController!
    private var menuBar: MenuBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.notice("launch: screen recording access = \(CGPreflightScreenCaptureAccess())")

        settings = Settings.shared
        controller = EffectController(settings: settings)
        menuBar = MenuBarController(controller: controller, settings: settings)
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
    }
}
