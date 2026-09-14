import ServiceManagement

/// Registers or unregisters this app as a login item via the modern
/// ServiceManagement API (macOS 13+).
enum LoginItem {
    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            Log.app.error("login item change failed: \(error, privacy: .public)")
        }
    }
}
