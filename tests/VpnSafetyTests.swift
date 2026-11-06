import Foundation

@main
struct VpnSafetyTests {
    static func snapshot(work: VpnState?, others: [VpnState] = []) -> VpnSnapshot {
        VpnSnapshot(work: work, others: others.enumerated().map { (name: "vpn\($0.offset)", state: $0.element) }, serviceIds: [])
    }

    static func main() {
        // Рабочий VPN не подключён или не выбран — Claude замораживается и не размораживается.
        for state: VpnState? in [nil, .missing, .disconnected, .connecting, .disconnecting] {
            precondition(VpnSafety.mustSuspend(work: state))
            precondition(!VpnSafety.mayResume(snapshot(work: state)))
        }
        precondition(!VpnSafety.mustSuspend(work: .connected))
        precondition(VpnSafety.mayResume(snapshot(work: .connected)))
        precondition(VpnSafety.mayResume(snapshot(work: .connected, others: [.disconnected, .missing])))

        // Любой другой туннель, даже ещё подключающийся или уже отключающийся, блокирует разморозку.
        for other: VpnState in [.connected, .connecting, .disconnecting] {
            precondition(!VpnSafety.mayResume(snapshot(work: .connected, others: [.disconnected, other])))
        }
        print("VpnSafety: missing/transitional work VPN and second active VPN passed")
    }
}
