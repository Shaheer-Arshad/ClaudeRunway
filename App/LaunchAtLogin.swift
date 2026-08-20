import ServiceManagement

/// Thin wrapper over SMAppService. Off by default — the user didn't ask for it,
/// it's offered as a toggle in the popover.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns false if the request failed (most often because the app isn't in
    /// a location macOS will register, e.g. still inside a build directory).
    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            return false
        }
    }
}
