import NetworkExtension

enum VpnSafety {
    static func mustSuspend(_ secureStatus: NEVPNStatus) -> Bool {
        secureStatus != .connected
    }

    static func mayResume(_ secureStatus: NEVPNStatus, defaultStatus: String) -> Bool {
        secureStatus == .connected && defaultStatus == "Disconnected"
    }
}
