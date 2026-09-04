import Foundation
import Observation
import ServiceManagement

@MainActor
@Observable
final class LaunchAtLoginController {
    private(set) var isRegistered = false
    private(set) var requiresApproval = false
    private(set) var statusMessage: String?

    let canManage: Bool

    init(bundleURL: URL = Bundle.main.bundleURL) {
        canManage = bundleURL.pathExtension.lowercased() == "app"
        refresh()
    }

    func setEnabled(_ enabled: Bool) {
        guard canManage else { return }
        var operationError: String?

        do {
            if enabled {
                switch SMAppService.mainApp.status {
                case .enabled:
                    break
                case .requiresApproval:
                    SMAppService.openSystemSettingsLoginItems()
                case .notRegistered, .notFound:
                    try SMAppService.mainApp.register()
                @unknown default:
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            operationError = error.localizedDescription
        }

        refresh()
        if let operationError {
            statusMessage = operationError
        }
    }

    func refresh() {
        guard canManage else {
            isRegistered = false
            requiresApproval = false
            statusMessage = "Available from the installed application."
            return
        }

        switch SMAppService.mainApp.status {
        case .enabled:
            isRegistered = true
            requiresApproval = false
            statusMessage = nil
        case .requiresApproval:
            isRegistered = true
            requiresApproval = true
            statusMessage = "Approval required in System Settings."
        case .notRegistered:
            isRegistered = false
            requiresApproval = false
            statusMessage = nil
        case .notFound:
            isRegistered = false
            requiresApproval = false
            statusMessage = "The login item could not be found."
        @unknown default:
            isRegistered = false
            requiresApproval = false
            statusMessage = "Unknown login-item status."
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
