import AppKit
import SwiftUI

/// The menu-bar icon and the popover that hosts `SettingsView`.
@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let settings: Settings
    private let controller: EffectController
    private var angleRefreshTimer: Timer?

    init(controller: EffectController, settings: Settings) {
        self.controller = controller
        self.settings = settings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: "MacbookDou")
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePopover)
        }

        popover.behavior = .transient
        popover.animates = true
        let hosting = NSHostingController(rootView: SettingsView(settings: settings, controller: controller))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting

        angleRefreshTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshTitle() }
        }
    }

    private func refreshTitle() {
        guard let button = statusItem.button else { return }
        button.title = settings.showsAngleInMenuBar ? String(format: " %.0f°", controller.currentAngleDegrees) : ""
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.close()
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
