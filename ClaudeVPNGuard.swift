import Cocoa
import NetworkExtension
import Darwin

final class ClaudeVPNGuard {
    static let shared = ClaudeVPNGuard()

    private let claudeBundleId = "com.anthropic.claudefordesktop"
    private let settings = GuardSettings.load()
    private var defaultVpnBundleId: String { settings?.defaultVpnBundleId ?? "" }
    private var defaultVpnServiceName: String { settings?.defaultVpnServiceName ?? "" }

    private var isClaudeRunning: Bool = false
    private var isScriptAction: Bool = false
    private var isPromptActive: Bool = false
    private var isSystemSleeping: Bool = false
    private var isKillSwitchEngaged: Bool = false
    private var suspendedPIDs = Set<pid_t>()

    private var lastReconnectAttempt: Date = .distantPast
    private var checkTimer: Timer?

    private init() {}

    func start() {
        log("Claude VPN Guard v4.1 (Gatekeeper + процессная защита) запущен.")
        guard settings != nil else {
            isClaudeRunning = isClaudeEngineRunning()
            if isClaudeRunning { engageKillSwitch(reason: "Отсутствуют настройки VPN") }
            log("Ошибка: отсутствуют или повреждены настройки VPN в guard-settings.json")
            return
        }

        // 1. Загружаем настройки защищенного VPN
        loadSecureVpnPreferences()

        // 2. Слушаем изменения статуса защищенного VPN
        NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: NEVPNManager.shared().connection,
            queue: .main
        ) { [weak self] _ in
            self?.handleSecureVpnStatusChange()
        }

        // 3. Слушаем события приложений
        let wsCenter = NSWorkspace.shared.notificationCenter

        wsCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notif in
            self?.handleAppLaunched(notif)
        }

        wsCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notif in
            self?.handleAppTerminated(notif)
        }

        wsCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notif in
            self?.handleAppActivated(notif)
        }

        // 4. Слушаем события сна и пробуждения
        wsCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleSystemWillSleep()
        }

        wsCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleSystemDidWake()
        }

        // 5. Первичная проверка состояния
        isClaudeRunning = isClaudeEngineRunning()
        if isClaudeRunning {
            let profile = getCurrentProfileName()
            log("Claude Engine уже активен при старте (Профиль: \(profile)).")
            periodicCheck()
        } else {
            log("Claude Engine не запущен. Ожидание запуска...")
        }

        // 6. Таймер безопасности (каждые 2 секунды)
        checkTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.periodicCheck()
        }
    }

    // MARK: - App Event Handlers

    private func handleAppLaunched(_ notif: Notification) {
        guard let app = notif.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == claudeBundleId else { return }

        let profile = getCurrentProfileName()
        log("Обнаружен запуск движка Claude (Профиль: \(profile)).")
        isClaudeRunning = true
        periodicCheck()
    }

    private func handleAppTerminated(_ notif: Notification) {
        guard let app = notif.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == claudeBundleId else { return }

        let profile = getCurrentProfileName()
        log("Обнаружено завершение процесса Claude (Профиль: \(profile)).")
        // Electron can still have live helpers after the main app notification.
        if !isClaudeEngineRunning() { handleClaudeTerminated() }
    }

    private func handleAppActivated(_ notif: Notification) {
        guard let app = notif.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == defaultVpnBundleId else { return }

        if isClaudeRunning && !isScriptAction && !isPromptActive && !isSystemSleeping {
            log("Пользователь открыл стороннее приложение VPN при работающем Claude!")
            handleUnauthorizedSwitch()
        }
    }

    private func handleSecureVpnStatusChange() {
        let status = NEVPNManager.shared().connection.status
        log("Статус защищенного VPN: \(statusDescription(status))")

        guard isClaudeRunning, !isSystemSleeping else { return }

        if status == .connected {
            if isKillSwitchEngaged && VpnSafety.mayResume(status, defaultStatus: getDefaultVpnStatus()) {
                log("Защищенный VPN восстановлен! Отключаем Kill Switch и размораживаем Claude.")
                isKillSwitchEngaged = false
                resumeClaude()
                notifyUser(title: "Claude VPN Guard", message: "Соединение с защищенным VPN восстановлено")
            }
        } else {
            engageKillSwitch(reason: "Обрыв защищенного VPN-туннеля")
            if status == .disconnected || status == .invalid { handleBackgroundReconnect() }
        }
    }

    // MARK: - Kill Switch Engine

    private func engageKillSwitch(reason: String) {
        guard !isKillSwitchEngaged else { return }
        isKillSwitchEngaged = true
        log("⚠️ СРАБОТАЛ KILL SWITCH: \(reason). Заморозка процесса Claude на уровне ядра...")
        suspendClaude()
    }

    private func disengageKillSwitch() {
        guard isKillSwitchEngaged else { return }
        guard VpnSafety.mayResume(NEVPNManager.shared().connection.status, defaultStatus: getDefaultVpnStatus()) else {
            log("Claude остаётся замороженным: защищённый VPN не подтверждён или включён второй VPN.")
            return
        }
        isKillSwitchEngaged = false
        log("Kill Switch снят. Разморозка Claude...")
        resumeClaude()
    }

    // MARK: - Sleep & Wake Handlers

    private func handleSystemWillSleep() {
        guard isClaudeEngineRunning() else { return }
        log("Mac уходит в сон. Включение Kill Switch для Claude...")
        isSystemSleeping = true
        engageKillSwitch(reason: "Переход в режим сна")
    }

    private func handleSystemDidWake() {
        guard isClaudeEngineRunning() else {
            isSystemSleeping = false
            return
        }

        log("Mac проснулся. Ожидаем сеть для восстановления защищенного VPN...")
        isSystemSleeping = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            Thread.sleep(forTimeInterval: 3.5)
            self.connectSecureVpn()

            let start = Date()
            var connected = false
            while Date().timeIntervalSince(start) < 15.0 {
                if NEVPNManager.shared().connection.status == .connected {
                    connected = true
                    break
                }
                Thread.sleep(forTimeInterval: 0.5)
            }

            DispatchQueue.main.async {
                self.isSystemSleeping = false
                if connected {
                    self.log("Защищенный VPN восстановлен после сна! Снятие Kill Switch.")
                    self.disengageKillSwitch()
                } else {
                    self.log("Не удалось восстановить защищенный VPN сразу после сна.")
                }
            }
        }
    }

    // MARK: - Periodic Safety Check

    private func periodicCheck() {
        guard !isSystemSleeping else { return }

        let currentlyRunning = isClaudeEngineRunning()

        if !currentlyRunning && isClaudeRunning {
            handleClaudeTerminated()
            return
        }
        if currentlyRunning && !isClaudeRunning { isClaudeRunning = true }

        guard isClaudeRunning else { return }

        // Check the protected tunnel before calling the slower scutil process.
        let vpnStatus = NEVPNManager.shared().connection.status
        if VpnSafety.mustSuspend(vpnStatus) {
            engageKillSwitch(reason: "Защищенный VPN не в статусе connected")
            if vpnStatus == .disconnected || vpnStatus == .invalid { handleBackgroundReconnect() }
        }

        guard !isScriptAction, !isPromptActive else { return }

        // 1. Проверка активности стороннего VPN
        let defaultVpnStatus = getDefaultVpnStatus()
        if defaultVpnStatus == "Connected" || defaultVpnStatus == "Connecting" {
            log("Сторонний VPN включился при работающем Claude!")
            handleUnauthorizedSwitch()
            return
        }
        if vpnStatus == .connected && isKillSwitchEngaged { disengageKillSwitch() }

    }

    // MARK: - Termination & Switch Handlers

    private func handleClaudeTerminated() {
        guard isClaudeRunning else { return }
        guard !isClaudeEngineRunning() else {
            log("Ожидаем завершения всех процессов Claude до смены VPN.")
            return
        }
        isClaudeRunning = false
        isKillSwitchEngaged = false
        suspendedPIDs.removeAll()
        isScriptAction = true

        let profile = getCurrentProfileName()
        log("Claude завершен [\(profile)]: отключаем защищенный VPN и восстанавливаем повседневный VPN...")

        disconnectSecureVpn()
        connectDefaultVpn()

        notifyUser(title: "Claude VPN Guard", message: "Claude закрыт [\(profile)]. Возвращен повседневный VPN")

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.isScriptAction = false
            self?.log("Возврат на повседневный VPN завершен.")
        }
    }

    private func handleBackgroundReconnect() {
        let now = Date()
        guard now.timeIntervalSince(lastReconnectAttempt) > 4.0 else { return }
        lastReconnectAttempt = now

        log("Попытка тихого восстановления защищенного VPN...")
        connectSecureVpn()
    }

    private func handleUnauthorizedSwitch() {
        guard !isPromptActive, !isScriptAction, !isSystemSleeping else { return }
        isPromptActive = true

        engageKillSwitch(reason: "Попытка переключения на сторонний VPN")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let quitConfirmed = self.askUserToQuitClaude()

            DispatchQueue.main.async {
                self.isPromptActive = false

                if quitConfirmed {
                    self.log("Пользователь подтвердил закрытие Claude.")
                    self.isScriptAction = true
                    self.quitClaude()
                    if !self.isClaudeEngineRunning() {
                        self.handleClaudeTerminated()
                    } else {
                        self.log("Claude не завершился; защищённый VPN остаётся включённым.")
                        self.isScriptAction = false
                    }
                } else {
                    self.log("Пользователь выбрал оставить Claude. Восстанавливаем защищенный VPN...")
                    self.isScriptAction = true
                    self.disconnectDefaultVpn()
                    self.connectSecureVpn()

                    DispatchQueue.global(qos: .userInitiated).async {
                        let waitStart = Date()
                        while Date().timeIntervalSince(waitStart) < 10.0 {
                            if NEVPNManager.shared().connection.status == .connected {
                                break
                            }
                            Thread.sleep(forTimeInterval: 0.3)
                        }

                        DispatchQueue.main.async {
                            if NEVPNManager.shared().connection.status == .connected {
                                self.disengageKillSwitch()
                                self.focusClaude()
                            } else {
                                self.log("Защищённый VPN не восстановлен за 10 секунд. Claude остаётся замороженным.")
                                self.notifyUser(title: "Claude VPN Guard", message: "VPN не восстановлен. Claude приостановлен.")
                            }
                            self.isScriptAction = false
                        }
                    }
                }
            }
        }
    }

    // MARK: - Process Controls

    private func suspendClaude() {
        for pid in engineProcessPIDs() {
            if kill(pid, SIGSTOP) == 0 { suspendedPIDs.insert(pid) }
            else if errno != ESRCH { log("Не удалось остановить Claude PID \(pid): \(String(cString: strerror(errno)))") }
        }
    }

    private func resumeClaude() {
        let live = Set(engineProcessPIDs())
        for pid in suspendedPIDs where live.contains(pid) { _ = kill(pid, SIGCONT) }
        suspendedPIDs.removeAll()
    }

    private func quitClaude() {
        let safeToResume = VpnSafety.mayResume(NEVPNManager.shared().connection.status, defaultStatus: getDefaultVpnStatus())
        if safeToResume { resumeClaude() }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundleId)
        if safeToResume { for app in apps { app.terminate() } }

        let limit = Date().addingTimeInterval(safeToResume ? 3.0 : 0.0)
        while Date() < limit {
            if !isClaudeEngineRunning() { break }
            Thread.sleep(forTimeInterval: 0.1)
        }

        if isClaudeEngineRunning() {
            for pid in engineProcessPIDs() { _ = kill(pid, SIGKILL) }
        }
    }

    private func focusClaude() {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundleId).first {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    private func isClaudeEngineRunning() -> Bool {
        return !engineProcessPIDs().isEmpty
    }

    private func engineProcessPIDs() -> [pid_t] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let prefix = home + "/.claude-vpn-guard/Claude-Engine.app/"
        let capacity = max(1024, Int(proc_listallpids(nil, 0)) + 128)
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        guard count > 0 else { return [] }
        return pids.prefix(count).filter { pid in
            guard pid > 0 else { return false }
            var buffer = [CChar](repeating: 0, count: 4096)
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
            let path = String(cString: buffer)
            return path.hasPrefix(prefix) && !path.hasSuffix("chrome_crashpad_handler")
        }
    }

    // MARK: - VPN Controls

    private func loadSecureVpnPreferences() {
        NEVPNManager.shared().loadFromPreferences { [weak self] error in
            if let error = error {
                self?.log("Ошибка загрузки защищенного VPN: \(error.localizedDescription)")
            } else {
                self?.log("Профиль защищенного VPN загружен.")
            }
        }
    }

    private func connectSecureVpn() {
        NEVPNManager.shared().loadFromPreferences { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error { self.log("Ошибка загрузки защищённого VPN: \(error.localizedDescription)"); return }
                do {
                    try NEVPNManager.shared().connection.startVPNTunnel()
                    self.log("Команда старта защищенного VPN отправлена.")
                } catch {
                    self.log("Ошибка старта защищенного VPN: \(error.localizedDescription)")
                }
            }
        }
    }

    private func disconnectSecureVpn() {
        NEVPNManager.shared().connection.stopVPNTunnel()
        log("Команда отключения защищенного VPN отправлена.")
    }

    private func getDefaultVpnStatus() -> String {
        let task = Process()
        task.launchPath = "/usr/sbin/scutil"
        task.arguments = ["--nc", "status", defaultVpnServiceName]
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return output.components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func connectDefaultVpn() {
        log("Подключение \(defaultVpnServiceName)...")
        let task = Process()
        task.launchPath = "/usr/sbin/scutil"
        task.arguments = ["--nc", "start", defaultVpnServiceName]
        try? task.run()
        task.waitUntilExit()
    }

    private func disconnectDefaultVpn() {
        log("Отключение \(defaultVpnServiceName)...")
        let task = Process()
        task.launchPath = "/usr/sbin/scutil"
        task.arguments = ["--nc", "stop", defaultVpnServiceName]
        try? task.run()
        task.waitUntilExit()
    }

    // MARK: - UI Alerts & Notifications

    private func askUserToQuitClaude() -> Bool {
        let scriptText = """
        tell application "System Events"
            activate
            try
                set dialogResult to display dialog "Claude сейчас запущен.\\n\\nДля переключения на другой VPN необходимо закрыть Claude. Хотите закрыть Claude прямо сейчас?" buttons {"Оставить Claude", "Закрыть Claude"} default button "Оставить Claude" cancel button "Оставить Claude" with icon caution with title "Claude VPN Guard"
                return button returned of dialogResult
            on error
                return "Оставить Claude"
            end try
        end tell
        """

        var error: NSDictionary?
        if let script = NSAppleScript(source: scriptText) {
            let output = script.executeAndReturnError(&error)
            let result = output.stringValue ?? ""
            return result == "Закрыть Claude"
        }
        return false
    }

    private func notifyUser(title: String, message: String) {
        func literal(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n") + "\""
        }
        let scriptText = "display notification \(literal(message)) with title \(literal(title))"
        var error: NSDictionary?
        if let script = NSAppleScript(source: scriptText) {
            script.executeAndReturnError(&error)
        }
    }

    private func statusDescription(_ status: NEVPNStatus) -> String {
        switch status {
        case .invalid: return "invalid"
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .reasserting: return "reasserting"
        case .disconnecting: return "disconnecting"
        @unknown default: return "unknown"
        }
    }

    private func getCurrentProfileName() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let profileFile = "\(home)/.claude-vpn-guard/current_profile.txt"
        let jsonFile = "\(home)/.claude-vpn-guard/profiles.json"

        let currentId = (try? String(contentsOfFile: profileFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "work"

        if let data = try? Data(contentsOf: URL(fileURLWithPath: jsonFile)),
           let slots = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for slot in slots {
                if let id = slot["id"] as? String, id == currentId,
                   let name = slot["name"] as? String {
                    return name
                }
            }
        }

        if currentId == "work" { return "Рабочий" }
        if currentId == "personal" { return "Личный" }
        return currentId
    }

    private func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let ts = formatter.string(from: Date())
        print("[\(ts)] \(message)")
        fflush(stdout)
    }
}
