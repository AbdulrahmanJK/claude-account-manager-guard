import NetworkExtension

@main
struct VpnSafetyTests {
    static func main() {
        for status: NEVPNStatus in [.invalid, .disconnected, .connecting, .reasserting, .disconnecting] {
            precondition(VpnSafety.mustSuspend(status))
            precondition(!VpnSafety.mayResume(status, defaultStatus: "Disconnected"))
        }
        precondition(!VpnSafety.mustSuspend(.connected))
        precondition(VpnSafety.mayResume(.connected, defaultStatus: "Disconnected"))
        precondition(!VpnSafety.mayResume(.connected, defaultStatus: "Connected"))
        precondition(!VpnSafety.mayResume(.connected, defaultStatus: "Connecting"))
        precondition(!VpnSafety.mayResume(.connected, defaultStatus: ""))
        print("VpnSafety: disconnected, transitional and dual-VPN states passed")
    }
}
