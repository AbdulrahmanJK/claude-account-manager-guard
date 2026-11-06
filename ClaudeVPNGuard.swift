import Cocoa
import Darwin

final class ClaudeVPNGuard: NSObject, NSMenuDelegate {
    static let shared = ClaudeVPNGuard()

    private let claudeBundleId = "com.anthropic.claudefordesktop"
    private let configStore = VpnConfigStore()
    private var config = VpnConfigStore().load()

    private var isClaudeRunning: Bool = false
    private var isScriptAction: Bool = false
    private var isPromptActive: Bool = false
    private var isSystemSleeping: Bool = false
    private var isKillSwitchEngaged: Bool = false
    private var suspendedPIDs = Set<pid_t>()
    private var lastWorkState: VpnState?

    private var lastReconnectAttempt: Date = .distantPast
    private var checkTimer: Timer?
    private var statusMonitor: VpnStatusMonitor?
    private let restorePoller = MainPoller()
    private let wakePoller = MainPoller()

    private let control = GuardControl()
    private var controlState = GuardControl().load()
    private var statusItem: NSStatusItem?
    private var toggleItem: NSMenuItem?
    private var workInfoItem: NSMenuItem?
    private var otherInfoItem: NSMenuItem?
    private var settingsWindow: VpnSettingsWindowController?
    private var guardIsActive: Bool { controlState.enabled && control.load().enabled }

    private override init() { super.init() }

    // MARK: - Menu

    private func setupControlMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        let toggle = NSMenuItem(title: "VPN Guard включён", action: #selector(toggleProtection), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        let hint = NSMenuItem(title: "Автосмена VPN и защита Claude", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())
        let workInfo = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        workInfo.isEnabled = false
        menu.addItem(workInfo)
        let otherInfo = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        otherInfo.isEnabled = false
        menu.addItem(otherInfo)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Настройки VPN…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        item.menu = menu
        statusItem = item
        toggleItem = toggle
        workInfoItem = workInfo
        otherInfoItem = otherInfo
        updateControlMenu()
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(controlChanged), name: GuardControl.notification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(vpnConfigChanged), name: VpnConfigStore.notification, object: nil)
    }

    private func updateControlMenu() {
        toggleItem?.state = controlState.enabled ? .on : .off
        toggleItem?.title = controlState.enabled ? "VPN Guard включён" : "VPN Guard выключен"
        statusItem?.button?.title = controlState.enabled ? "VPN Guard ✓" : "VPN Guard выкл."
        statusItem?.button?.toolTip = "Включить или выключить защиту и автоматическое переключение VPN для Claude"
    }

    /// Статусы VPN считаем при открытии меню, а не на каждом тике: так в меню всегда свежие данные,
    /// а лишних обращений к системе нет.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let services = SystemVpnServices.all()
        if let work = config.work {
            workInfoItem?.title = "Для Claude: \(work.name) — \(VpnSwitcher.state(of: work, services: services).title)"
        } else {
            workInfoItem?.title = "Для Claude: VPN не выбран"
        }
        if let other = config.other {
            otherInfoItem?.title = "Без Claude: \(other.name) — \(VpnSwitcher.state(of: other, services: services).title)"
        } else {
            otherInfoItem?.title = "Без Claude: ничего не менять"
        }
    }

    @objc private func openSettings() {
        if let settingsWindow {
            settingsWindow.present()
            return
        }
        let controller = VpnSettingsWindowController(store: configStore) { [weak self] _ in
            // Сами изменения агент подхватывает через уведомление VpnConfigStore — оно приходит
            // и когда настройки сохраняют из окна запуска Claude.
            self?.settingsWindow = nil
        }
        settingsWindow = controller
        controller.present()
    }

    @objc private func toggleProtection() {
        do {
            try control.setEnabled(!control.load().enabled)
            controlChanged()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Не удалось сохранить состояние VPN Guard"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func controlChanged() {
        refreshControlState()
        periodicCheck()
    }

    private func refreshControlState() {
        let next = control.load()
        guard next != controlState else { return }
        controlState = next
        isScriptAction = false
        isPromptActive = false
        lastReconnectAttempt = .distantPast
        if !next.enabled {
            isKillSwitchEngaged = false
            resumeClaude()
            log("VPN Guard выключен: автосмена VPN и блокировка Claude отключены.")
        } else {
            log("VPN Guard включён.")
        }
        isClaudeRunning = isClaudeEngineRunning()
        updateControlMenu()
    }

    private func operationIsCurrent(_ revision: String) -> Bool {
        let state = control.load()
        return state.enabled && state.revision == revision
    }

    // MARK: - Start

    func start() {
        log("Claude VPN Guard v5.0 (рабочий VPN + VPN без Claude) запущен.")
        log("Настройки VPN: \(config.summary).")
        setupControlMenu()

        statusMonitor = VpnStatusMonitor { [weak self] in self?.periodicCheck() }

        let wsCenter = NSWorkspace.shared.notificationCenter
        wsCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] notif in
            self?.handleAppLaunched(notif)
        }
        wsCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] notif in
            self?.handleAppTerminated(notif)
        }
        wsCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notif in
            self?.handleAppActivated(notif)
        }
        wsCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleSystemWillSleep()
        }
        wsCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleSystemDidWake()
        }

        isClaudeRunning = isClaudeEngineRunning()
        if isClaudeRunning {
            log("Claude Engine уже активен при старте (Профиль: \(getCurrentProfileName())).")
        } else {
            log("Claude Engine не запущен. Ожидание запуска...")
        }
        periodicCheck()

        // Таймер безопасности: подписка на статусы VPN быстрее, но таймер ловит то, что она не покрывает
        // (VPN-приложения, новые сервисы, пропущенные события). .common — чтобы проверка не вставала,
        // пока открыто меню агента.
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in self?.periodicCheck() }
        RunLoop.main.add(timer, forMode: .common)
        checkTimer = timer
    }

    // MARK: - App Event Handlers

    private func handleAppLaunched(_ notif: Notification) {
        guard let app = notif.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        if app.bundleIdentifier == claudeBundleId {
            log("Обнаружен запуск движка Claude (Профиль: \(getCurrentProfileName())).")
            isClaudeRunning = true
        }
        // Запуск VPN-приложения из списка тоже меняет картину (для типа «приложение» это и есть включение VPN).
        periodicCheck()
    }

    private func handleAppTerminated(_ notif: Notification) {
        guard let app = notif.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        guard app.bundleIdentifier == claudeBundleId else { periodicCheck(); return }
        log("Обнаружено завершение процесса Claude (Профиль: \(getCurrentProfileName())).")
        // Electron can still have live helpers after the main app notification.
        if !isClaudeEngineRunning() { handleClaudeTerminated() }
    }

    private func handleAppActivated(_ notif: Notification) {
        guard let app = notif.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleId = app.bundleIdentifier else { return }
        // Приложение рабочего VPN открывать можно; спрашиваем только про приложения остальных VPN.
        // Сравниваем по Bundle ID, потому что у одного приложения может быть и рабочий, и личный туннель.
        guard bundleId != config.work?.bundleId,
              let entry = config.entries.first(where: { $0.id != config.workVpnId && $0.bundleId == bundleId }) else { return }

        if guardIsActive && isClaudeRunning && !isScriptAction && !isPromptActive && !isSystemSleeping {
            log("Пользователь открыл \(entry.name) при работающем Claude!")
            handleUnauthorizedSwitch(names: [entry.name])
        }
    }

    @objc private func vpnConfigChanged() {
        let next = configStore.load()
        guard next != config else { return }
        config = next
        log("Настройки VPN обновлены: \(config.summary).")
        guard guardIsActive, isClaudeRunning, !isSystemSleeping else { return }

        // Рабочий VPN сменили при открытом Claude: прежний рабочий теперь «чужой» VPN.
        // Переключаем сами, без вопроса «закрыть Claude?», — это и есть то, что пользователь попросил.
        let revision = controlState.revision
        isScriptAction = true
        VpnSwitcher.enterClaudeMode(config, log: log)
        periodicCheck()
        restorePoller.start(timeout: 15, until: { [weak self] in
            guard let self else { return true }
            return VpnSafety.mayResume(VpnSwitcher.snapshot(self.config))
        }) { [weak self] ok in
            guard let self else { return }
            guard self.operationIsCurrent(revision) else { return }
            self.isScriptAction = false
            if ok {
                self.disengageKillSwitch()
            } else {
                self.log("Новый рабочий VPN не подтверждён за 15 секунд: \(VpnSwitcher.describeBlockers(self.config, VpnSwitcher.snapshot(self.config))).")
            }
            self.periodicCheck()
        }
    }

    // MARK: - Kill Switch Engine

    private func engageKillSwitch(reason: String) {
        guard guardIsActive, !isKillSwitchEngaged else { return }
        isKillSwitchEngaged = true
        log("⚠️ СРАБОТАЛ KILL SWITCH: \(reason). Заморозка процесса Claude на уровне ядра...")
        suspendClaude()
    }

    private func disengageKillSwitch() {
        guard guardIsActive, isKillSwitchEngaged else { return }
        let snapshot = VpnSwitcher.snapshot(config)
        guard VpnSafety.mayResume(snapshot) else {
            log("Claude остаётся замороженным: \(VpnSwitcher.describeBlockers(config, snapshot)).")
            return
        }
        isKillSwitchEngaged = false
        log("Kill Switch снят. Разморозка Claude...")
        resumeClaude()
    }

    // MARK: - Sleep & Wake Handlers

    private func handleSystemWillSleep() {
        isSystemSleeping = true
        guard guardIsActive, isClaudeEngineRunning() else { return }
        log("Mac уходит в сон. Включение Kill Switch для Claude...")
        engageKillSwitch(reason: "Переход в режим сна")
    }

    private func handleSystemDidWake() {
        isSystemSleeping = false
        guard guardIsActive, isClaudeEngineRunning() else { return }
        let revision = controlState.revision

        log("Mac проснулся. Ожидаем сеть для восстановления рабочего VPN...")
        // Пока ждём сеть, обычная проверка не должна паниковать из-за временно упавшего туннеля
        // и показывать диалог про чужой VPN. Флаг снимается на каждом пути выхода ниже.
        isSystemSleeping = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            guard let self else { return }
            guard self.operationIsCurrent(revision) else {
                self.isSystemSleeping = false
                return
            }
            VpnSwitcher.enterClaudeMode(self.config, log: self.log)
            self.wakePoller.start(timeout: 15, until: { [weak self] in
                guard let self else { return true }
                return VpnSafety.mayResume(VpnSwitcher.snapshot(self.config))
            }) { [weak self] ok in
                guard let self else { return }
                self.isSystemSleeping = false
                guard self.operationIsCurrent(revision) else { return }
                if ok {
                    self.log("Рабочий VPN восстановлен после сна! Снятие Kill Switch.")
                    self.disengageKillSwitch()
                } else {
                    self.log("Не удалось восстановить рабочий VPN сразу после сна.")
                }
            }
        }
    }

    // MARK: - Periodic Safety Check

    private func periodicCheck() {
        refreshControlState()
        guard guardIsActive else {
            isClaudeRunning = isClaudeEngineRunning()
            return
        }
        guard !isSystemSleeping else { return }

        let currentlyRunning = isClaudeEngineRunning()
        if !currentlyRunning && isClaudeRunning {
            handleClaudeTerminated()
            return
        }
        if currentlyRunning && !isClaudeRunning { isClaudeRunning = true }

        let snapshot = VpnSwitcher.snapshot(config)
        statusMonitor?.refresh(ids: snapshot.serviceIds)
        if snapshot.work != lastWorkState {
            lastWorkState = snapshot.work
            log("Рабочий VPN (\(config.work?.name ?? "не выбран")): \(snapshot.work?.title ?? "—")")
        }

        guard isClaudeRunning else { return }
        guard config.work != nil else {
            engageKillSwitch(reason: "Не выбран VPN для работы Claude")
            return
        }

        if VpnSafety.mustSuspend(work: snapshot.work) {
            engageKillSwitch(reason: "Рабочий VPN не подключён")
            if snapshot.work?.isOff == true { handleBackgroundReconnect() }
        }

        guard !isScriptAction, !isPromptActive else { return }

        if !snapshot.activeOthers.isEmpty {
            log("Другой VPN включился при работающем Claude: \(snapshot.activeOthers.joined(separator: ", ")).")
            handleUnauthorizedSwitch(names: snapshot.activeOthers)
            return
        }
        if snapshot.work == .connected && isKillSwitchEngaged { disengageKillSwitch() }
    }

    // MARK: - Termination & Switch Handlers

    private func handleClaudeTerminated() {
        guard guardIsActive else { isClaudeRunning = false; return }
        guard isClaudeRunning else { return }
        guard !isClaudeEngineRunning() else {
            log("Ожидаем завершения всех процессов Claude до смены VPN.")
            return
        }
        isClaudeRunning = false
        isKillSwitchEngaged = false
        suspendedPIDs.removeAll()
        restorePoller.cancel()
        isScriptAction = true

        let profile = getCurrentProfileName()
        log("Claude завершён [\(profile)]: переключаем VPN на режим без Claude...")
        VpnSwitcher.leaveClaudeMode(config, log: log)
        if let other = config.other {
            notifyUser(title: "Claude VPN Guard", message: "Claude закрыт [\(profile)]. Включён \(other.name)")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.isScriptAction = false
            self?.log("Переключение VPN после Claude завершено.")
        }
    }

    private func handleBackgroundReconnect() {
        guard guardIsActive, let work = config.work else { return }
        let now = Date()
        guard now.timeIntervalSince(lastReconnectAttempt) > 4.0 else { return }
        lastReconnectAttempt = now

        log("Попытка тихого восстановления \(work.name)...")
        VpnSwitcher.start(work)
    }

    private func handleUnauthorizedSwitch(names: [String]) {
        guard guardIsActive, !isPromptActive, !isScriptAction, !isSystemSleeping else { return }
        isPromptActive = true
        let revision = controlState.revision
        let workName = config.work?.name ?? "рабочий VPN"

        engageKillSwitch(reason: "Включён другой VPN: \(names.joined(separator: ", "))")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let quitConfirmed = self.askUserToQuitClaude(otherNames: names, workName: workName)

            DispatchQueue.main.async {
                guard self.operationIsCurrent(revision) else { return }
                self.isPromptActive = false

                if quitConfirmed {
                    self.log("Пользователь подтвердил закрытие Claude.")
                    self.isScriptAction = true
                    self.quitClaude()
                    if !self.isClaudeEngineRunning() {
                        self.handleClaudeTerminated()
                    } else {
                        self.log("Claude не завершился; рабочий VPN остаётся включённым.")
                        self.isScriptAction = false
                    }
                } else {
                    self.log("Пользователь выбрал оставить Claude. Возвращаем \(workName)...")
                    self.isScriptAction = true
                    VpnSwitcher.enterClaudeMode(self.config, log: self.log)

                    self.restorePoller.start(timeout: 15, until: { [weak self] in
                        guard let self else { return true }
                        return VpnSafety.mayResume(VpnSwitcher.snapshot(self.config))
                    }) { [weak self] ok in
                        guard let self else { return }
                        guard self.operationIsCurrent(revision) else { return }
                        self.isScriptAction = false
                        if ok {
                            self.disengageKillSwitch()
                            self.focusClaude()
                        } else {
                            self.log("Рабочий VPN не восстановлен за 15 секунд. Claude остаётся замороженным.")
                            self.notifyUser(title: "Claude VPN Guard", message: "\(workName) не восстановлен. Claude приостановлен.")
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
        // Размораживаем для штатного закрытия, только если сеть безопасна: иначе Claude успел бы
        // отправить что-то через чужой VPN, пока обрабатывает Cmd+Q.
        let safeToResume = VpnSafety.mayResume(VpnSwitcher.snapshot(config))
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

    // MARK: - UI Alerts & Notifications

    private func appleScriptLiteral(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    private func askUserToQuitClaude(otherNames: [String], workName: String) -> Bool {
        let message = "Claude сейчас запущен, а включился другой VPN: \(otherNames.joined(separator: ", ")).\n\nПока работает Claude, должен быть включён только \(workName). Закрыть Claude, чтобы переключиться?"
        let scriptText = """
        tell application "System Events"
            activate
            try
                set dialogResult to display dialog \(appleScriptLiteral(message)) buttons {"Оставить Claude", "Закрыть Claude"} default button "Оставить Claude" cancel button "Оставить Claude" with icon caution with title "Claude VPN Guard"
                return button returned of dialogResult
            on error
                return "Оставить Claude"
            end try
        end tell
        """

        var error: NSDictionary?
        if let script = NSAppleScript(source: scriptText) {
            let output = script.executeAndReturnError(&error)
            return (output.stringValue ?? "") == "Закрыть Claude"
        }
        return false
    }

    private func notifyUser(title: String, message: String) {
        let scriptText = "display notification \(appleScriptLiteral(message)) with title \(appleScriptLiteral(title))"
        var error: NSDictionary?
        if let script = NSAppleScript(source: scriptText) {
            script.executeAndReturnError(&error)
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
