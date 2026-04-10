import ServiceManagement

protocol LaunchAtLoginControlling {
    func currentStatus() -> Bool
    func setEnabled(_ enabled: Bool) throws
}

struct SystemLaunchAtLoginController: LaunchAtLoginControlling {
    func currentStatus() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
