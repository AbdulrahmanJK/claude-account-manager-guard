import AppKit
import SystemConfiguration

// MARK: - Модель настроек

/// Как guard управляет конкретным VPN.
enum VpnKind: String, Codable {
    /// Системный VPN-сервис macOS (WireGuard, IKEv2, клиенты на NetworkExtension — всё, что видно в `scutil --nc list`).
    /// Включается через `scutil --nc`, а состояние туннеля читается у системы, поэтому guard точно знает,
    /// поднят ли туннель. Это основной и рекомендуемый вариант.
    case service
    /// Приложение без системного VPN-сервиса (например, клиент, который сам ставит системный прокси).
    /// Guard умеет только запустить и закрыть его, а «включён» для него означает «процесс запущен»:
    /// проверить сам туннель система не даёт.
    case app
}

struct VpnEntry: Codable, Equatable {
    var id: String
    var name: String
    var kind: VpnKind
    /// Имя сервиса из `scutil --nc list`. Храним имя, а не UUID сервиса: при переимпорте конфига
    /// в приложении VPN UUID меняется, а имя пользователь обычно оставляет прежним.
    var serviceName: String?
    /// Bundle ID приложения VPN: нужен, чтобы запускать или закрывать приложение и чтобы заметить,
    /// что пользователь открыл «чужой» VPN, пока работает Claude.
    var bundleId: String?
    var appPath: String?

    var kindTitle: String { kind == .service ? "Системный VPN" : "Приложение" }

    var detail: String {
        switch kind {
        case .service: return "scutil: «\(serviceName ?? "—")»"
        case .app: return appPath ?? bundleId ?? "—"
        }
    }
}

struct VpnConfig: Codable, Equatable {
    var version: Int
    var entries: [VpnEntry]
    /// VPN, который должен быть включён, пока работает Claude.
    var workVpnId: String?
    /// VPN, который включается после закрытия Claude. nil — после Claude ничего не переключаем.
    var otherVpnId: String?

    static let empty = VpnConfig(version: 2, entries: [], workVpnId: nil, otherVpnId: nil)

    var work: VpnEntry? { entries.first { $0.id == workVpnId } }

    var other: VpnEntry? {
        // Одинаковый VPN «для Claude» и «без Claude» означал бы «выключить и тут же включить» его
        // при каждом закрытии Claude, поэтому такую пару считаем отсутствием второго VPN.
        guard let otherVpnId, otherVpnId != workVpnId else { return nil }
        return entries.first { $0.id == otherVpnId }
    }

    var summary: String {
        guard let work else { return "VPN для Claude не выбран" }
        return "Claude: \(work.name)  •  без Claude: \(other?.name ?? "не менять")"
    }
}

/// Хранит vpn-config.json рядом с остальными локальными файлами guard.
struct VpnConfigStore {
    static let notification = Notification.Name("com.user.claudevpnguard.vpnConfigChanged")
    let base: URL

    init(base: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude-vpn-guard")) {
        self.base = base
    }

    var url: URL { base.appendingPathComponent("vpn-config.json") }

    func load() -> VpnConfig {
        if let data = try? Data(contentsOf: url),
           let config = try? JSONDecoder().decode(VpnConfig.self, from: data) {
            return config
        }
        return migratedFromLegacySettings()
    }

    /// До версии 5 guard знал только «повседневный» VPN из guard-settings.json, а защищённым был
    /// системный IKEv2. Повседневный переносим как VPN «без Claude». Рабочий намеренно не угадываем:
    /// пока его не выбрали, guard не пустит Claude в сеть, а это безопаснее, чем ошибиться с выбором.
    func migratedFromLegacySettings() -> VpnConfig {
        guard let legacy = GuardSettings.load(from: base.appendingPathComponent("guard-settings.json")) else {
            return .empty
        }
        let entry = VpnEntry(
            id: "legacy-default",
            name: legacy.defaultVpnServiceName,
            kind: .service,
            serviceName: legacy.defaultVpnServiceName,
            bundleId: legacy.defaultVpnBundleId,
            appPath: nil
        )
        return VpnConfig(version: 2, entries: [entry], workVpnId: nil, otherVpnId: entry.id)
    }

    func save(_ config: VpnConfig) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        // Окно запуска и агент в строке меню — разные процессы; распределённое уведомление
        // позволяет агенту сразу подхватить новый рабочий VPN, а не ждать перезапуска.
        DistributedNotificationCenter.default().postNotificationName(Self.notification, object: nil, userInfo: nil, deliverImmediately: true)
    }
}

// MARK: - Состояние VPN

enum VpnState: String {
    case connected, connecting, disconnecting, disconnected
    /// Сервис с таким именем в системе не найден (удалили или переименовали в приложении VPN).
    case missing

    /// Через выключенный или несуществующий сервис трафик не идёт. Промежуточные состояния
    /// считаем включёнными: «connecting» у чужого VPN уже может перехватить маршрут.
    var isOff: Bool { self == .disconnected || self == .missing }

    var title: String {
        switch self {
        case .connected: return "подключён"
        case .connecting: return "подключается"
        case .disconnecting: return "отключается"
        case .disconnected: return "выключен"
        case .missing: return "не найден в системе"
        }
    }

    init(_ status: SCNetworkConnectionStatus) {
        switch status {
        case .connected: self = .connected
        case .connecting: self = .connecting
        case .disconnecting: self = .disconnecting
        case .disconnected: self = .disconnected
        default: self = .missing
        }
    }
}

struct SystemVpnService: Equatable {
    let id: String
    let name: String
    let state: VpnState
}

/// Сервисы из `scutil --nc list` с Bundle ID приложения — нужен только окну настроек,
/// чтобы предложить готовые варианты и подставить название приложения.
struct DiscoveredVpnService: Equatable {
    let id: String
    let name: String
    let providerBundleId: String?
}

enum SystemVpnServices {
    /// Все сервисы текущего сетевого набора, у которых есть «соединение» (VPN, IPSec, PPP).
    /// Wi‑Fi и Ethernet отсекаются сами: для них система отдаёт статус invalid.
    /// Читаем через SystemConfiguration, а не через `scutil`: агент делает это каждые 2 секунды,
    /// и запуск процесса на каждую проверку был бы заметно дороже.
    static func all() -> [SystemVpnService] {
        guard let prefs = SCPreferencesCreate(nil, "ClaudeVPNGuard" as CFString, nil),
              let set = SCNetworkSetCopyCurrent(prefs),
              let services = SCNetworkSetCopyServices(set) as? [SCNetworkService] else { return [] }
        return services.compactMap { service in
            guard let id = SCNetworkServiceGetServiceID(service).map({ $0 as String }),
                  let name = SCNetworkServiceGetName(service).map({ $0 as String }),
                  let connection = SCNetworkConnectionCreateWithServiceID(nil, id as CFString, nil, nil) else { return nil }
            let status = SCNetworkConnectionGetStatus(connection)
            guard status != .invalid else { return nil }
            return SystemVpnService(id: id, name: name, state: VpnState(status))
        }
    }

    static func discover() -> [DiscoveredVpnService] {
        parseScutilList(runScutil(["--nc", "list"]))
    }

    /// Разбирает строки вида
    /// `* (Connected)  0A1B2C3D-… VPN (com.example.workvpn) "Work VPN"  [VPN:com.example.workvpn]`.
    static func parseScutilList(_ text: String) -> [DiscoveredVpnService] {
        let pattern = #"\(([^)]*)\)\s+([0-9A-Fa-f-]{36})\s+\S+(?:\s+\(([^)]*)\))?\s+"(.*)"\s+\["#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let line = String(line)
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  let idRange = Range(match.range(at: 2), in: line),
                  let nameRange = Range(match.range(at: 4), in: line) else { return nil }
            let bundle = Range(match.range(at: 3), in: line).map { String(line[$0]) }
            return DiscoveredVpnService(id: String(line[idRange]), name: String(line[nameRange]), providerBundleId: bundle)
        }
    }

    @discardableResult
    static func runScutil(_ arguments: [String]) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        // Не waitUntilExit: он крутит run loop текущего потока, и таймер агента успевал бы зайти
        // в проверку посреди переключения VPN. Семафор просто ждёт, ничего не исполняя.
        let exited = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in exited.signal() }
        do { try task.run() } catch { return "" }

        // Вывод читаем в фоне: при заполненном пайпе scutil иначе не завершится.
        final class Box { var data = Data() }
        let box = Box()
        let readDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.data = pipe.fileHandleForReading.readDataToEndOfFile()
            readDone.signal()
        }
        // После пробуждения configd бывает подвисает. Без таймаута вместе со scutil
        // вставал бы весь агент — и kill switch тоже.
        if exited.wait(timeout: .now() + 5) == .timedOut {
            task.terminate()
            _ = exited.wait(timeout: .now() + 1)
        }
        _ = readDone.wait(timeout: .now() + 1)
        return String(data: box.data, encoding: .utf8) ?? ""
    }
}

// MARK: - Снимок и переключение

/// Состояние всех VPN в один момент времени — по нему решаем, можно ли Claude работать.
struct VpnSnapshot {
    /// nil — рабочий VPN не выбран.
    let work: VpnState?
    /// Все остальные VPN: системные сервисы (в том числе не добавленные в настройки) и приложения из настроек.
    let others: [(name: String, state: VpnState)]
    let serviceIds: Set<String>

    var activeOthers: [String] { others.filter { !$0.state.isOff }.map(\.name) }
}

enum VpnSwitcher {
    static func snapshot(_ config: VpnConfig) -> VpnSnapshot {
        let services = SystemVpnServices.all()
        let work = config.work
        let workServiceName = work?.kind == .service ? work?.serviceName : nil
        // Проверяем все системные VPN, а не только добавленные в настройки: включённый
        // второй VPN-клиент или любой другой туннель так же уводит трафик Claude мимо рабочего VPN.
        var others = services.filter { $0.name != workServiceName }.map { (name: $0.name, state: $0.state) }
        for entry in config.entries where entry.kind == .app && entry.id != work?.id {
            others.append((name: entry.name, state: appState(entry)))
        }
        return VpnSnapshot(
            work: work.map { state(of: $0, services: services) },
            others: others,
            serviceIds: Set(services.map(\.id))
        )
    }

    static func state(of entry: VpnEntry, services: [SystemVpnService]? = nil) -> VpnState {
        switch entry.kind {
        case .service:
            let list = services ?? SystemVpnServices.all()
            return list.first { $0.name == entry.serviceName }?.state ?? .missing
        case .app:
            return appState(entry)
        }
    }

    /// Режим «работает Claude»: гасим всё, кроме рабочего VPN, и поднимаем рабочий.
    static func enterClaudeMode(_ config: VpnConfig, log: (String) -> Void) {
        enforceClaudeMode(config, force: true, log: log)
    }

    /// Доводит систему до режима «работает Claude» и возвращает снимок до команд.
    /// Вызывается на каждом шаге ожидания, а не один раз: туннель в состоянии «disconnecting»
    /// (Claude только что закрыли и сразу открыли) команду start игнорирует, а VPN с автоподключением
    /// поднимается снова после stop. Повторы ограничены одной командой в 4 секунды на VPN,
    /// иначе ожидание с шагом 0,5 с засыпало бы клиент VPN командами.
    @discardableResult
    static func enforceClaudeMode(_ config: VpnConfig, force: Bool = false, log: (String) -> Void) -> VpnSnapshot {
        let services = SystemVpnServices.all()
        let work = config.work
        let workServiceName = work?.kind == .service ? work?.serviceName : nil
        // «disconnecting» не трогаем: туннель и так выключается, повторный stop ничего не даст.
        for service in services where service.name != workServiceName && (service.state == .connected || service.state == .connecting) {
            if allowCommand("stop:" + service.name, force: force) {
                log("Выключаем \(service.name)…")
                SystemVpnServices.runScutil(["--nc", "stop", service.name])
                noteStopped(service.name)
            }
        }
        for entry in config.entries where entry.kind == .app && entry.id != work?.id && !appState(entry).isOff {
            if allowCommand("stop:" + entry.id, force: force) {
                log("Закрываем \(entry.name)…")
                stop(entry)
                noteStopped(entry.name)
            }
        }
        // Уже подключённый или подключающийся туннель не трогаем: повторный start
        // у некоторых клиентов рвёт текущее соединение.
        if let work, state(of: work, services: services).isOff, allowCommand("start:" + work.id, force: force) {
            log("Включаем \(work.name)…")
            start(work)
        }
        return snapshot(config)
    }

    /// Режим «Claude закрыт»: выключаем рабочий VPN и включаем второй.
    /// Без второго VPN ничего не меняем — пользователь сам решает, что включено вне Claude.
    static func leaveClaudeMode(_ config: VpnConfig, log: (String) -> Void) {
        guard config.other != nil else {
            log("VPN без Claude не выбран — подключения не меняем.")
            return
        }
        enforceClosedMode(config, force: true, log: log)
    }

    /// Доводит систему до режима «Claude закрыт». Возвращает true, когда второй VPN подключён
    /// (или его нет и доводить нечего).
    @discardableResult
    static func enforceClosedMode(_ config: VpnConfig, force: Bool = false, log: (String) -> Void) -> Bool {
        guard let other = config.other else { return true }
        let services = SystemVpnServices.all()
        if let work = config.work {
            let workState = state(of: work, services: services)
            if (workState == .connected || workState == .connecting) && allowCommand("stop:" + work.id, force: force) {
                log("Выключаем \(work.name)…")
                stop(work)
            }
        }
        let otherState = state(of: other, services: services)
        if otherState.isOff && allowCommand("start:" + other.id, force: force) {
            log("Включаем \(other.name)…")
            start(other)
        }
        return otherState == .connected
    }

    /// true, если guard сам выключил этот VPN меньше `seconds` назад. Повторное появление такого VPN
    /// почти всегда означает автоподключение (On Demand) в его приложении — об этом стоит сказать.
    static func wasRecentlyStopped(_ name: String, within seconds: TimeInterval = 60) -> Bool {
        guard let at = lastStopped[name] else { return false }
        return ProcessInfo.processInfo.systemUptime - at < seconds
    }

    // Время по systemUptime, а не Date: не скачет при переводе часов и стоит на месте во время сна.
    private static var lastCommand: [String: TimeInterval] = [:]
    private static var lastStopped: [String: TimeInterval] = [:]

    private static func allowCommand(_ key: String, force: Bool) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if !force, let last = lastCommand[key], now - last < 4 { return false }
        lastCommand[key] = now
        return true
    }

    private static func noteStopped(_ name: String) {
        lastStopped[name] = ProcessInfo.processInfo.systemUptime
    }

    static func start(_ entry: VpnEntry) {
        switch entry.kind {
        case .service:
            guard let name = entry.serviceName else { return }
            // scutil, а не SCNetworkConnectionStart: у последнего туннель живёт, пока жив наш объект
            // соединения (если не передать linger), а scutil уже управлял повседневным VPN в прошлых версиях guard.
            SystemVpnServices.runScutil(["--nc", "start", name])
        case .app:
            guard let url = appURL(entry) else { return }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: nil)
        }
    }

    static func stop(_ entry: VpnEntry) {
        switch entry.kind {
        case .service:
            guard let name = entry.serviceName else { return }
            SystemVpnServices.runScutil(["--nc", "stop", name])
        case .app:
            guard let bundleId = entry.bundleId else { return }
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).forEach { $0.terminate() }
        }
    }

    static func describeBlockers(_ config: VpnConfig, _ snapshot: VpnSnapshot) -> String {
        guard let work = config.work else { return "Не выбран VPN для работы Claude" }
        var reasons: [String] = []
        if let state = snapshot.work, state != .connected { reasons.append("\(work.name): \(state.title)") }
        if !snapshot.activeOthers.isEmpty { reasons.append("не выключился: \(snapshot.activeOthers.joined(separator: ", "))") }
        return reasons.isEmpty ? "VPN не подтверждён" : reasons.joined(separator: "; ")
    }

    private static func appState(_ entry: VpnEntry) -> VpnState {
        guard let bundleId = entry.bundleId else { return .missing }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty ? .disconnected : .connected
    }

    private static func appURL(_ entry: VpnEntry) -> URL? {
        if let path = entry.appPath, FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        return entry.bundleId.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    }
}

// MARK: - Наблюдение и ожидание

/// Подписка на смену статуса системных VPN. Без неё агент узнал бы об обрыве рабочего туннеля
/// только на следующем 2‑секундном тике — подписка возвращает ту скорость реакции, что была
/// у прежнего NEVPNStatusDidChange. Таймер при этом остаётся страховкой.
final class VpnStatusMonitor {
    private var connections: [String: SCNetworkConnection] = [:]
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) { self.onChange = onChange }

    func refresh(ids: Set<String>) {
        for (id, connection) in connections where !ids.contains(id) {
            SCNetworkConnectionUnscheduleFromRunLoop(connection, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            connections[id] = nil
        }
        for id in ids where connections[id] == nil {
            var context = SCNetworkConnectionContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
            let callback: SCNetworkConnectionCallBack = { _, _, info in
                guard let info else { return }
                Unmanaged<VpnStatusMonitor>.fromOpaque(info).takeUnretainedValue().onChange()
            }
            guard let connection = SCNetworkConnectionCreateWithServiceID(nil, id as CFString, callback, &context) else { continue }
            // commonModes: иначе уведомления не приходят, пока открыто меню агента или модальный диалог.
            SCNetworkConnectionScheduleWithRunLoop(connection, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            connections[id] = connection
        }
    }
}

/// Ждёт условие на главном потоке. Прежняя версия крутила Thread.sleep в фоновой очереди
/// и читала там состояние VPN; таймер на главном потоке убирает гонки с остальной логикой агента.
final class MainPoller {
    private var timer: Timer?

    /// Повторный вызов заменяет предыдущее ожидание: его completion уже не вызывается,
    /// поэтому вызывающий код сбрасывает свои флаги в каждом completion, а не полагается на первый.
    func start(timeout: TimeInterval, interval: TimeInterval = 0.5, until condition: @escaping () -> Bool, completion: @escaping (Bool) -> Void) {
        cancel()
        if condition() { completion(true); return }
        let deadline = Date().addingTimeInterval(timeout)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] timer in
            if condition() {
                timer.invalidate(); self?.timer = nil; completion(true)
            } else if Date() >= deadline {
                timer.invalidate(); self?.timer = nil; completion(false)
            }
        }
        // .common — чтобы ожидание не замирало, пока пользователь держит открытым меню или алерт.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }
}
