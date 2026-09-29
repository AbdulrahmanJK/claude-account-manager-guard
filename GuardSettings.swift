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
