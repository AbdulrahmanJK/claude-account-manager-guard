import Foundation

struct GuardSettings: Decodable {
    let defaultVpnServiceName: String
    let defaultVpnBundleId: String

    static func load() -> GuardSettings? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-vpn-guard/guard-settings.json")
        if let data = try? Data(contentsOf: path),
           let settings = try? JSONDecoder().decode(GuardSettings.self, from: data),
           !settings.defaultVpnServiceName.isEmpty, !settings.defaultVpnBundleId.isEmpty {
            return settings
        }
        return nil
    }
}

/// Shared by the launcher and menu-bar agent. Missing/invalid state enables protection.
struct GuardControl {
    struct State: Codable, Equatable {
        var enabled: Bool
        var revision: String
    }

    static let notification = Notification.Name("com.user.claudevpnguard.controlChanged")
    let url: URL

    init(base: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude-vpn-guard")) {
        url = base.appendingPathComponent("guard-control.json")
    }

    func load() -> State {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(State.self, from: data) else {
            return State(enabled: true, revision: "default")
        }
        return state
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) throws -> State {
        let state = State(enabled: enabled, revision: UUID().uuidString)
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        DistributedNotificationCenter.default().postNotificationName(Self.notification, object: nil, userInfo: nil, deliverImmediately: true)
        return state
    }
}
