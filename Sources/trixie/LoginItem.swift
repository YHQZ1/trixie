import Foundation
import ServiceManagement

/// Starting Trixie when you log in, using Apple's login-item feature (System Settings > General > Login Items).
enum LoginItem {
    private static var service: SMAppService { .mainApp }

    static var isEnabled: Bool { service.status == .enabled }

    static func describe() -> String {
        switch service.status {
        case .enabled: return "on: she starts when you log in"
        case .requiresApproval: return "waiting for your approval: turn Trixie on in System Settings > General > Login Items"
        case .notRegistered: return "off"
        case .notFound: return "not available: start her from build/Trixie.app first"
        @unknown default: return "unknown"
        }
    }

    static func set(_ on: Bool) throws {
        if on {
            if service.status != .enabled { try service.register() }
        } else {
            try service.unregister()
        }
    }

    /// `trixie --login on | off | status`, handy from the terminal.
    static func handle(_ word: String) {
        do {
            switch word {
            case "on": try set(true)
            case "off": try set(false)
            default: break
            }
            print("Start at login: \(describe())")
        } catch {
            print("Couldn't change the login item: \(error.localizedDescription)")
        }
    }
}
