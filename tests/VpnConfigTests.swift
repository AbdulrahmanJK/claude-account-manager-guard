import Foundation

@main
struct VpnConfigTests {
    static func main() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = VpnConfigStore(base: base)

        // Нет ни нового, ни старого файла — пустая конфигурация без рабочего VPN.
        precondition(store.load() == .empty)

        // Старый guard-settings.json переносится как VPN «без Claude», рабочий не угадывается.
        try #"{"defaultVpnServiceName":"Daily VPN","defaultVpnBundleId":"com.example.dailyvpn"}"#
            .write(to: base.appendingPathComponent("guard-settings.json"), atomically: true, encoding: .utf8)
        let migrated = store.load()
        precondition(migrated.work == nil)
        precondition(migrated.other?.serviceName == "Daily VPN" && migrated.other?.bundleId == "com.example.dailyvpn")

        // Сохранение и чтение, права 0600.
        let work = VpnEntry(id: "work", name: "Work VPN", kind: .service, serviceName: "work-tunnel", bundleId: "com.example.workvpn", appPath: nil)
        var config = migrated
        config.entries.append(work)
        config.workVpnId = work.id
        try store.save(config)
        precondition(store.load() == config)
        precondition(store.load().summary == "Claude: Work VPN  •  без Claude: Daily VPN")
        let permissions = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as! NSNumber
        precondition(permissions.intValue == 0o600)

        // Один и тот же VPN в обеих ролях не считается вторым VPN.
        config.otherVpnId = work.id
        precondition(config.other == nil)

        // Повреждённый файл не должен молча включать «что-нибудь»: откатываемся к миграции без рабочего VPN.
        try Data("broken".utf8).write(to: store.url)
        precondition(store.load().work == nil)

        // Разбор `scutil --nc list`, включая сервис без Bundle ID (IPSec) и строки-заголовки.
        let list = """
        Available network connection services in the current set (*=enabled):
        * (Disconnected)   AAAAAAAA-1111-4AAA-8AAA-AAAAAAAAAAAA VPN (com.example.othervpn) "Other VPN"                       [VPN:com.example.othervpn]
        * (Connected)      BBBBBBBB-2222-4BBB-8BBB-BBBBBBBBBBBB VPN (com.example.workvpn) "work-tunnel"                        [VPN:com.example.workvpn]
          (Disconnected)   11111111-2222-3333-4444-555555555555 IPSec              "Office (IKE) VPN"                [IPSec]
        """
        let parsed = SystemVpnServices.parseScutilList(list)
        precondition(parsed.count == 3)
        precondition(parsed[1] == DiscoveredVpnService(id: "BBBBBBBB-2222-4BBB-8BBB-BBBBBBBBBBBB", name: "work-tunnel", providerBundleId: "com.example.workvpn"))
        precondition(parsed[2].name == "Office (IKE) VPN" && parsed[2].providerBundleId == nil)

        print("VpnConfig: migration, persistence, roles, corrupted file and scutil parsing passed")
    }
}
