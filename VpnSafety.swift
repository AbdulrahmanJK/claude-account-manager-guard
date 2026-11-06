enum VpnSafety {
    /// Claude замораживается, если рабочий VPN не выбран или не в статусе «подключён».
    static func mustSuspend(work: VpnState?) -> Bool {
        work != .connected
    }

    /// Размораживать можно, только когда рабочий VPN подключён и все остальные выключены:
    /// при двух поднятых туннелях маршрут трафика Claude зависит от их порядка.
    static func mayResume(_ snapshot: VpnSnapshot) -> Bool {
        snapshot.work == .connected && snapshot.activeOthers.isEmpty
    }
}
