import Cocoa
import Darwin

final class ClaudeVPNGuard: NSObject, NSMenuDelegate {
    static let shared = ClaudeVPNGuard()

    private let claudeBundleId = "com.anthropic.claudefordesktop"
    private let gatekeeperBundleId = "com.anthropic.claudefordesktop.gatekeeper"
    private let enginePrefix = FileManager.default.homeDirectoryForCurrentUser.path + "/.claude-vpn-guard/Claude-Engine.app/"
    private var engineMainPath: String { enginePrefix + "Contents/MacOS/Claude" }
    private let configStore = VpnConfigStore()
    private var config = VpnConfigStore().load()

    private var isClaudeRunning: Bool = false
    /// Guard сам переключает VPN или закрывает Claude — не задаём вопросов про «чужой» VPN.
    /// Ставится и снимается только через begin/endScriptAction: токен не даёт устаревшему
    /// сценарию снять флаг, который уже поставил новый.
    private var isScriptAction: Bool = false
    private var scriptActionToken = 0
    private var isPromptActive: Bool = false
    private var isSystemSleeping: Bool = false
    private var isKillSwitchEngaged: Bool = false
    /// Замороженные процессы: PID → путь к исполняемому файлу. Путь нужен, чтобы после смерти Claude
    /// не послать сигнал чужому процессу, получившему тот же PID.
    private var suspended: [pid_t: String] = [:]
    private var killSwitchNotified = false
    private var lastWorkState: VpnState?
    private var onDemandHinted = Set<String>()

    /// Время по systemUptime: не идёт во время сна и не скачет при переводе часов.
    private var lastReconnectUptime: TimeInterval = 0
    private var reconnectAttempts = 0
    private var sleepFlagUptime: TimeInterval = 0
    private var mainGoneUptime: TimeInterval?
    /// Меняется на каждом событии сна/пробуждения и при закрытии Claude. Отложенные шаги
    /// пробуждения сверяют его, чтобы устаревший сценарий не включил рабочий VPN, когда Claude уже закрыт.
    private var wakeGeneration = 0

    private var checkTimer: Timer?
    private var statusMonitor: VpnStatusMonitor?
    private var termSignalSource: DispatchSourceSignal?
    private let restorePoller = MainPoller()
    private let wakePoller = MainPoller()
    private let closePoller = MainPoller()
    private let quitPoller = MainPoller()

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
        scriptActionToken += 1
        isScriptAction = false
        isPromptActive = false
        lastReconnectUptime = 0
        reconnectAttempts = 0
        // Раз мы исполняем этот код, Mac не спит. Незавершённое пробуждение сверяет ревизию
        // защиты и всё равно бы отменилось, но до тех пор держало бы проверки выключенными —
        // а значит, после «выключить и включить» Claude был бы без защиты до 18 секунд.
        wakeGeneration += 1
        wakePoller.cancel()
        setSystemSleeping(false)
        isClaudeRunning = isClaudeMainRunning()
        updateControlMenu()
        if !next.enabled {
            isKillSwitchEngaged = false
            killSwitchNotified = false
            resumeClaude()
            log("VPN Guard выключен: автосмена VPN и блокировка Claude отключены.")
        } else {
            log("VPN Guard включён.")
            // Защиту включили при открытом Claude, который сидит на другом VPN. Вопрос «закрыть Claude?»
            // тут неуместен: пользователь как раз хочет, чтобы guard сам перевёл Claude на рабочий VPN.
            if isClaudeRunning && !isSystemSleeping {
                switchToWorkVpn(reason: "VPN Guard включён при открытом Claude")
            }
        }
    }

    private func operationIsCurrent(_ revision: String) -> Bool {
        let state = control.load()
        return state.enabled && state.revision == revision
    }

    @discardableResult
    private func beginScriptAction() -> Int {
        scriptActionToken += 1
        isScriptAction = true
        return scriptActionToken
    }

    private func endScriptAction(_ token: Int) {
        if token == scriptActionToken { isScriptAction = false }
    }

    // MARK: - Start

    func start() {
        log("Claude VPN Guard v5.0 (рабочий VPN + VPN без Claude) запущен.")
        log("Настройки VPN: \(config.summary).")
        setupControlMenu()
        installTerminationHandler()

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

        isClaudeRunning = isClaudeMainRunning()
        if isClaudeRunning {
            log("Claude Engine уже активен при старте (Профиль: \(getCurrentProfileName())).")
            // Прошлый экземпляр агента мог упасть или быть перезапущен, пока Claude был заморожен.
            // Список замороженных PID жил только в его памяти, поэтому без этого шага Claude так и
            // остался бы замороженным: разморозка трогает только то, что заморозил текущий экземпляр.
            let snapshot = VpnSwitcher.snapshot(config)
            if guardIsActive && !VpnSafety.mayResume(snapshot) {
                engageKillSwitch(reason: "VPN не в рабочем состоянии при запуске агента: \(VpnSwitcher.describeBlockers(config, snapshot))")
            } else {
                resumeClaude()
            }
        } else {
            log("Claude Engine не запущен. Ожидание запуска...")
        }
        periodicCheck()

        // Таймер безопасности: подписка на статусы VPN быстрее, но таймер ловит то, что она не покрывает
        // (VPN-приложения, новые сервисы, пропущенные события, новые процессы Claude). .common — чтобы
        // проверка не вставала, пока открыто меню агента.
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in self?.periodicCheck() }
        RunLoop.main.add(timer, forMode: .common)
        checkTimer = timer
    }

    /// `stop.sh` и `launchctl bootout` останавливают агент сигналом SIGTERM. Если в этот момент
    /// Claude заморожен, размораживать его было бы уже некому — он висел бы до перезагрузки.
    /// Остановка агента и так означает отказ от защиты, поэтому перед выходом отпускаем Claude.
    private func installTerminationHandler() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            self?.log("Агент останавливается: размораживаем Claude, чтобы он не остался замороженным без присмотра.")
            self?.resumeClaude()
            exit(0)
        }
        source.resume()
        termSignalSource = source
    }

    // MARK: - App Event Handlers

    private func handleAppLaunched(_ notif: Notification) {
        guard let app = notif.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        if app.bundleIdentifier == claudeBundleId {
            log("Обнаружен запуск движка Claude (Профиль: \(getCurrentProfileName())).")
            isClaudeRunning = true
            mainGoneUptime = nil
            // Claude открыли снова, пока после прошлого закрытия ещё поднимался VPN «без Claude».
            closePoller.cancel()
            if guardIsActive && !isScriptAction && !isSystemSleeping && !VpnSafety.mayResume(VpnSwitcher.snapshot(config)) {
                // Окно запуска готовит VPN заранее, так что сюда попадаем, когда Claude открыли в обход
                // него: по ссылке claude://, из Finder прямо из Claude-Engine.app, через «Открыть недавние».
                // Пользователь хочет работать в Claude — переключаем VPN сами, без вопроса «закрыть Claude?».
                switchToWorkVpn(reason: "Claude запущен без подготовленного VPN")
            }
        }
        // Запуск VPN-приложения из списка тоже меняет картину (для типа «приложение» это и есть включение VPN).
        periodicCheck()
    }

    private func handleAppTerminated(_ notif: Notification) {
        guard let app = notif.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        guard app.bundleIdentifier == claudeBundleId else { periodicCheck(); return }
        log("Обнаружено завершение процесса Claude (Профиль: \(getCurrentProfileName())).")
        handleClaudeTerminated()
    }

    private func handleAppActivated(_ notif: Notification) {
        guard let app = notif.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleId = app.bundleIdentifier,
              config.entries.contains(where: { $0.bundleId == bundleId }) else { return }
        // Раньше одно лишь открытие окна другого VPN-приложения замораживало Claude и показывало
        // диалог, даже если туннель так и не включали. Теперь решает только реальный статус VPN:
        // включат туннель — проверка заморозит Claude сразу, без ложных срабатываний.
        periodicCheck()
    }

    @objc private func vpnConfigChanged() {
        let next = configStore.load()
        guard next != config else { return }
        config = next
        onDemandHinted.removeAll()
        log("Настройки VPN обновлены: \(config.summary).")
        // Во время пробуждения сценарий сна сам прочитает новый config, когда дойдёт до переключения.
        guard guardIsActive, isClaudeRunning, !isSystemSleeping else { return }
        // Рабочий VPN сменили при открытом Claude: прежний рабочий теперь «чужой» VPN.
        // Переключаем сами, без вопроса «закрыть Claude?», — это и есть то, что пользователь попросил.
        switchToWorkVpn(reason: "Сменились настройки VPN")
    }

    // MARK: - Kill Switch Engine

    private func engageKillSwitch(reason: String, notify: Bool = true) {
        guard guardIsActive, !isKillSwitchEngaged else { return }
        isKillSwitchEngaged = true
        log("⚠️ СРАБОТАЛ KILL SWITCH: \(reason). Заморозка процесса Claude на уровне ядра...")
        suspendClaude()
        // Замороженный Claude выглядит как зависший; без уведомления непонятно, что это guard.
        if notify {
            killSwitchNotified = true
            notifyUser(title: "Claude приостановлен", message: reason)
        }
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
        if killSwitchNotified {
            killSwitchNotified = false
            notifyUser(title: "Claude VPN Guard", message: "\(config.work?.name ?? "Рабочий VPN") подключён, Claude снова работает")
        }
    }

    /// Переводит открытый Claude на рабочий VPN без вопросов: выключает остальные VPN, включает
    /// рабочий и ждёт безопасного состояния. Пока ждём, Claude заморожен, если сеть небезопасна.
    private func switchToWorkVpn(reason: String, focusWhenDone: Bool = false) {
        guard guardIsActive, let work = config.work else { return }
        let revision = controlState.revision
        let token = beginScriptAction()
        log("\(reason): переключаем на \(work.name).")
        let snapshot = VpnSwitcher.enforceClaudeMode(config, force: true, log: log)
        if !VpnSafety.mayResume(snapshot) { engageKillSwitch(reason: reason) }

        restorePoller.start(timeout: 20, until: { [weak self] in
            guard let self else { return true }
            guard self.isClaudeRunning, self.operationIsCurrent(revision) else { return true }
            return VpnSafety.mayResume(VpnSwitcher.enforceClaudeMode(self.config, log: self.log))
        }) { [weak self] ok in
            guard let self else { return }
            // Снимаем флаг до любых проверок — на каждом пути выхода. Если за это время флаг взял
            // новый сценарий (закрытие Claude, повторное переключение), токен не совпадёт и его не тронем.
            self.endScriptAction(token)
            guard self.isClaudeRunning, self.operationIsCurrent(revision) else { return }
            if ok {
                self.disengageKillSwitch()
                if focusWhenDone { self.focusClaude() }
            } else {
                let blockers = VpnSwitcher.describeBlockers(self.config, VpnSwitcher.snapshot(self.config))
                self.log("Рабочий VPN не подготовлен за 20 секунд: \(blockers). Claude остаётся замороженным.")
                self.notifyUser(title: "Claude VPN Guard", message: "\(work.name) не подключился. Claude приостановлен.")
            }
            self.periodicCheck()
        }
    }

    // MARK: - Sleep & Wake Handlers

    private func setSystemSleeping(_ value: Bool) {
        isSystemSleeping = value
        if value { sleepFlagUptime = ProcessInfo.processInfo.systemUptime }
    }

    private func handleSystemWillSleep() {
        wakeGeneration += 1
        wakePoller.cancel()
        setSystemSleeping(true)
        guard guardIsActive, isClaudeEngineRunning() else { return }
        log("Mac уходит в сон. Включение Kill Switch для Claude...")
        engageKillSwitch(reason: "Переход в режим сна", notify: false)
    }

    private func handleSystemDidWake() {
        wakeGeneration += 1
        let generation = wakeGeneration
        wakePoller.cancel()
        setSystemSleeping(false)
        guard guardIsActive, isClaudeMainRunning() else { return }
        let revision = controlState.revision

        log("Mac проснулся. Ожидаем сеть для восстановления рабочего VPN...")
        // Пока ждём сеть, обычная проверка не должна паниковать из-за временно упавшего туннеля
        // и показывать диалог про чужой VPN. Флаг снимает либо этот сценарий, либо событие,
        // которое его отменило (новый сон/пробуждение, закрытие Claude), либо страховка в periodicCheck.
        setSystemSleeping(true)

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            guard let self, generation == self.wakeGeneration else { return }
            guard self.operationIsCurrent(revision), self.isClaudeMainRunning() else {
                self.setSystemSleeping(false)
                self.periodicCheck()
                return
            }
            VpnSwitcher.enterClaudeMode(self.config, log: self.log)
            self.wakePoller.start(timeout: 15, until: { [weak self] in
                guard let self, generation == self.wakeGeneration else { return true }
                guard self.operationIsCurrent(revision), self.isClaudeMainRunning() else { return true }
                return VpnSafety.mayResume(VpnSwitcher.enforceClaudeMode(self.config, log: self.log))
            }) { [weak self] ok in
                guard let self, generation == self.wakeGeneration else { return }
                self.setSystemSleeping(false)
                if self.operationIsCurrent(revision) && self.isClaudeMainRunning() {
                    if ok {
                        self.log("Рабочий VPN восстановлен после сна! Снятие Kill Switch.")
                        self.disengageKillSwitch()
                    } else {
                        self.log("Не удалось восстановить рабочий VPN сразу после сна. Продолжаем попытки в фоне.")
                        self.killSwitchNotified = true
                        self.notifyUser(title: "Claude приостановлен", message: "Рабочий VPN не поднялся после сна")
                    }
                }
                // Если Claude закрыли во время ожидания, обычная проверка доведёт закрытие до конца.
                self.periodicCheck()
            }
        }
    }

    // MARK: - Periodic Safety Check

    private func periodicCheck() {
        refreshControlState()
        guard guardIsActive else {
            isClaudeRunning = isClaudeMainRunning()
            return
        }
        if isSystemSleeping {
            // Страховка от залипшего флага: macOS может прислать willSleep без didWake (сон отменили),
            // и тогда все проверки молча стояли бы — защита была бы выключена. Сценарий пробуждения
            // укладывается в 18,5 с; uptime во сне не идёт, так что 45 с — это 45 с бодрствования.
            guard ProcessInfo.processInfo.systemUptime - sleepFlagUptime > 45 else { return }
            log("Флаг сна не снят за 45 секунд бодрствования — возобновляем проверки.")
            wakeGeneration += 1
            wakePoller.cancel()
            setSystemSleeping(false)
        }

        let mainRunning = isClaudeMainRunning()
        if !mainRunning && isClaudeRunning {
            handleClaudeTerminated()
            return
        }
        if mainRunning && !isClaudeRunning { isClaudeRunning = true }

        let snapshot = VpnSwitcher.snapshot(config)
        statusMonitor?.refresh(ids: snapshot.serviceIds)
        if snapshot.work != lastWorkState {
            lastWorkState = snapshot.work
            log("Рабочий VPN (\(config.work?.name ?? "не выбран")): \(snapshot.work?.title ?? "—")")
        }
        if snapshot.work == .connected { reconnectAttempts = 0 }

        guard isClaudeRunning else { return }
        guard config.work != nil else {
            engageKillSwitch(reason: "Не выбран VPN для работы Claude")
            return
        }

        // Процессы, появившиеся после заморозки (новая сессия Claude Code, новый хелпер), тоже
        // должны стоять. SIGSTOP уже остановленному процессу ничего не делает, так что повтор безопасен.
        if isKillSwitchEngaged { suspendClaude() }

        // Инвариант: Claude работает только при подключённом рабочем VPN и выключенных остальных.
        // Проверяем до флагов isScriptAction/isPromptActive — пока guard сам переключает VPN или ждёт
        // ответа в диалоге, Claude не должен успеть сходить в сеть через чужой туннель.
        if !VpnSafety.mayResume(snapshot) {
            let reason = VpnSafety.mustSuspend(work: snapshot.work)
                ? "Рабочий VPN не подключён"
                : "Включён другой VPN: \(snapshot.activeOthers.joined(separator: ", "))"
            engageKillSwitch(reason: reason)
            if snapshot.work?.isOff == true { handleBackgroundReconnect() }
        }

        guard !isScriptAction, !isPromptActive else { return }

        if !snapshot.activeOthers.isEmpty {
            log("Другой VPN включился при работающем Claude: \(snapshot.activeOthers.joined(separator: ", ")).")
            hintAboutAutoReconnect(snapshot.activeOthers)
            handleUnauthorizedSwitch(names: snapshot.activeOthers)
            return
        }
        if snapshot.work == .connected && isKillSwitchEngaged { disengageKillSwitch() }
    }

    /// VPN, который guard только что выключил, а он поднялся снова, почти наверняка настроен на
    /// автоподключение. Без подсказки пользователь получал бы вопрос «закрыть Claude?» по кругу.
    private func hintAboutAutoReconnect(_ names: [String]) {
        for name in names where VpnSwitcher.wasRecentlyStopped(name) && !onDemandHinted.contains(name) {
            onDemandHinted.insert(name)
            let message = "\(name) включился сам сразу после выключения. Похоже, в его приложении включено автоподключение (On Demand / Always-on) — отключите его, иначе guard будет снова и снова выключать этот VPN."
            log(message)
            notifyUser(title: "Claude VPN Guard", message: message)
        }
    }

    // MARK: - Termination & Switch Handlers

    private func handleClaudeTerminated() {
        guard guardIsActive else { isClaudeRunning = false; return }
        guard isClaudeRunning else { return }
        guard !isClaudeMainRunning() else { return }

        // Заморожённые хелперы и сессии Claude Code сами завершиться не могут: если Claude убили,
        // пока он был заморожен (принудительное завершение, сбой), они висели бы вечно, а guard вечно
        // ждал бы их и не переключал VPN. Размораживать их нельзя — сеть небезопасна, — поэтому завершаем.
        killFrozenLeftovers()

        let now = ProcessInfo.processInfo.systemUptime
        if isClaudeEngineRunning() {
            if mainGoneUptime == nil {
                mainGoneUptime = now
                log("Ожидаем завершения всех процессов Claude до смены VPN.")
            }
            // Зависший хелпер не должен навсегда оставить пользователя на рабочем VPN.
            if let since = mainGoneUptime, now - since < 15 { return }
            log("Процессы Claude не завершились за 15 секунд — переключаем VPN без них.")
        }
        mainGoneUptime = nil

        isClaudeRunning = false
        isKillSwitchEngaged = false
        killSwitchNotified = false
        suspended.removeAll()
        restorePoller.cancel()
        quitPoller.cancel()
        // Отменяем незавершённое пробуждение: иначе через пару секунд оно включило бы рабочий VPN
        // и выключило бы VPN «без Claude», хотя Claude уже закрыт.
        wakeGeneration += 1
        wakePoller.cancel()
        setSystemSleeping(false)
        let token = beginScriptAction()

        let profile = getCurrentProfileName()
        // Пока агент дожидался хелперов, пользователь мог уже снова открыть Claude и выбрать аккаунт.
        // Окно запуска в этот момент гасит VPN «без Claude» — включать его обратно значит устроить
        // перетягивание, после которого запуск падает по таймауту.
        if isGatekeeperRunning() {
            log("Claude завершён [\(profile)], но его уже открывают снова — VPN не переключаем.")
        } else {
            log("Claude завершён [\(profile)]: переключаем VPN на режим без Claude...")
            VpnSwitcher.leaveClaudeMode(config, log: log)
        }
        if let other = config.other, !isGatekeeperRunning() {
            notifyUser(title: "Claude VPN Guard", message: "Claude закрыт [\(profile)]. Включаем \(other.name)")
            // Рабочий VPN мог быть ещё в «disconnecting», и тогда второй VPN не стартует с первой команды.
            closePoller.start(timeout: 20, until: { [weak self] in
                guard let self, self.guardIsActive else { return true }
                // Claude открывают снова — VPN теперь готовит окно запуска; не тянем одеяло на себя.
                if self.isClaudeEngineRunning() || self.isGatekeeperRunning() { return true }
                return VpnSwitcher.enforceClosedMode(self.config, log: self.log)
            }) { [weak self] ok in
                if !ok { self?.log("\(other.name) не подключился за 20 секунд после закрытия Claude.") }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.endScriptAction(token)
            self?.log("Переключение VPN после Claude завершено.")
        }
    }

    private func isGatekeeperRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: gatekeeperBundleId).isEmpty
    }

    private func handleBackgroundReconnect() {
        guard guardIsActive, let work = config.work else { return }
        // Нарастающая пауза 4 → 8 → 16 → 32 → 60 с: без сети (ночь с открытым Claude, самолёт)
        // попытка раз в 4 секунды только засоряла бы лог и дёргала клиент VPN.
        let interval = min(60.0, 4.0 * pow(2.0, Double(min(reconnectAttempts, 4))))
        let now = ProcessInfo.processInfo.systemUptime
        guard lastReconnectUptime == 0 || now - lastReconnectUptime > interval else { return }
        lastReconnectUptime = now
        reconnectAttempts += 1

        log("Попытка тихого восстановления \(work.name) (№\(reconnectAttempts))...")
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

            let answer = self.askUserToQuitClaude(otherNames: names, workName: workName)

            DispatchQueue.main.async {
                guard self.operationIsCurrent(revision) else { return }
                self.isPromptActive = false
                // Пока диалог висел, Claude могли закрыть сами — тогда вопрос уже не актуален.
                guard self.isClaudeRunning else { return }

                switch answer {
                case .quit:
                    self.quitClaudeSafely(revision: revision)
                case .keep:
                    self.switchToWorkVpn(reason: "Пользователь оставил Claude", focusWhenDone: true)
                case .failed(let details):
                    // Чаще всего у агента нет доступа к System Events (Конфиденциальность → Автоматизация).
                    // Безопасный выбор — оставить Claude на рабочем VPN, но молча это делать нельзя.
                    self.log("Не удалось показать диалог про другой VPN (\(details)). Возвращаем рабочий VPN.")
                    self.notifyUser(title: "Claude VPN Guard", message: "Включился другой VPN. Диалог не открылся — проверьте доступ ClaudeVPNGuard к System Events. Возвращаем \(workName).")
                    self.switchToWorkVpn(reason: "Диалог не показан", focusWhenDone: false)
                }
            }
        }
    }

    /// Закрытие по кнопке «Закрыть Claude». Диалог появляется, только когда включён чужой VPN,
    /// поэтому сразу разморозить Claude для штатного Cmd+Q нельзя, а SIGKILL теряет несохранённые
    /// данные. Сначала возвращаем рабочий VPN, затем размораживаем и закрываем штатно;
    /// принудительно — только если VPN не поднялся или Claude не закрылся сам.
    private func quitClaudeSafely(revision: String) {
        let token = beginScriptAction()
        log("Пользователь подтвердил закрытие Claude. Возвращаем рабочий VPN, чтобы Claude закрылся штатно.")
        VpnSwitcher.enforceClaudeMode(config, force: true, log: log)

        quitPoller.start(timeout: 10, until: { [weak self] in
            guard let self, self.isClaudeMainRunning(), self.operationIsCurrent(revision) else { return true }
            return VpnSafety.mayResume(VpnSwitcher.enforceClaudeMode(self.config, log: self.log))
        }) { [weak self] _ in
            guard let self else { return }
            guard self.operationIsCurrent(revision), self.isClaudeMainRunning() else {
                self.endScriptAction(token)
                self.periodicCheck()
                return
            }
            guard VpnSafety.mayResume(VpnSwitcher.snapshot(self.config)) else {
                self.log("Рабочий VPN не поднялся за 10 секунд — закрываем Claude принудительно, не размораживая.")
                self.forceKillClaude()
                self.endScriptAction(token)
                self.handleClaudeTerminated()
                return
            }
            // Флаг kill switch снимаем до разморозки: иначе тик проверки снова заморозил бы
            // процессы Claude посреди штатного закрытия.
            self.isKillSwitchEngaged = false
            self.killSwitchNotified = false
            self.resumeClaude()
            NSRunningApplication.runningApplications(withBundleIdentifier: self.claudeBundleId).forEach { $0.terminate() }
            self.quitPoller.start(timeout: 8, until: { [weak self] in
                !(self?.isClaudeEngineRunning() ?? false)
            }) { [weak self] exited in
                guard let self else { return }
                if !exited && self.isClaudeEngineRunning() {
                    self.log("Claude не закрылся за 8 секунд — завершаем принудительно.")
                    self.forceKillClaude()
                }
                self.endScriptAction(token)
                self.handleClaudeTerminated()
            }
        }
    }

    // MARK: - Process Controls

    private struct ProcessEntry {
        let pid: pid_t
        let ppid: pid_t
        let path: String
    }

    private func allProcesses() -> [ProcessEntry] {
        let capacity = max(1024, Int(proc_listallpids(nil, 0)) + 128)
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        guard count > 0 else { return [] }
        var buffer = [CChar](repeating: 0, count: 4096)
        var result: [ProcessEntry] = []
        for pid in pids.prefix(count) where pid > 0 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { continue }
            let path = proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : ""
            result.append(ProcessEntry(pid: pid, ppid: pid_t(info.pbi_ppid), path: path))
        }
        return result
    }

    private func isEngineProcess(_ path: String) -> Bool {
        path.hasPrefix(enginePrefix) && !path.hasSuffix("chrome_crashpad_handler")
    }

    /// Процессы Claude вместе со всеми потомками, родители раньше детей.
    /// Одного бандла мало: сессии Claude Code запускаются из ~/Library/Application Support/Claude/
    /// claude-code/…, то есть вне Claude-Engine.app, и без обхода дерева продолжали бы ходить
    /// в сеть при обрыве VPN. Сюда же попадают их дочерние процессы (MCP-серверы, команды).
    /// Не ловятся только процессы, отцепившиеся от дерева (nohup/демоны, перешедшие к launchd).
    private func claudeProcessTree() -> [ProcessEntry] {
        let all = allProcesses()
        var children: [pid_t: [ProcessEntry]] = [:]
        for process in all { children[process.ppid, default: []].append(process) }
        var result = all.filter { isEngineProcess($0.path) }
        var seen = Set(result.map(\.pid))
        var index = 0
        while index < result.count {
            for child in children[result[index].pid] ?? [] where !seen.contains(child.pid) {
                seen.insert(child.pid)
                result.append(child)
            }
            index += 1
        }
        return result
    }

    private func suspendClaude() {
        for process in claudeProcessTree() {
            if kill(process.pid, SIGSTOP) == 0 { suspended[process.pid] = process.path }
            else if errno != ESRCH { log("Не удалось остановить процесс Claude PID \(process.pid): \(String(cString: strerror(errno)))") }
        }
    }

    private func resumeClaude() {
        let live = Dictionary(allProcesses().map { ($0.pid, $0.path) }, uniquingKeysWith: { first, _ in first })
        // Сначала всё, что замораживали мы, даже если процесс уже отцепился от дерева Claude.
        for (pid, path) in suspended where live[pid] == path { _ = kill(pid, SIGCONT) }
        // Затем всё текущее дерево: процессы мог заморозить прошлый экземпляр агента. SIGCONT
        // работающему процессу ничего не делает.
        for process in claudeProcessTree() { _ = kill(process.pid, SIGCONT) }
        suspended.removeAll()
    }

    private func killFrozenLeftovers() {
        guard !suspended.isEmpty else { return }
        let live = Dictionary(allProcesses().map { ($0.pid, $0.path) }, uniquingKeysWith: { first, _ in first })
        var killed = 0
        for (pid, path) in suspended where live[pid] == path {
            if kill(pid, SIGKILL) == 0 { killed += 1 }
        }
        if killed > 0 { log("Claude завершился замороженным: завершено \(killed) оставшихся замороженных процессов.") }
        suspended.removeAll()
    }

    private func forceKillClaude() {
        // Всё дерево, а не только бандл: иначе замороженные сессии Claude Code остались бы сиротами.
        for process in claudeProcessTree() { _ = kill(process.pid, SIGKILL) }
        suspended.removeAll()
    }

    private func focusClaude() {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundleId).first {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    /// Claude «запущен», пока жив его главный процесс. По любому хелперу судить нельзя:
    /// замороженный хелпер после смерти главного процесса не завершится никогда.
    private func isClaudeMainRunning() -> Bool {
        allProcesses().contains { $0.path == engineMainPath }
    }

    private func isClaudeEngineRunning() -> Bool {
        allProcesses().contains { isEngineProcess($0.path) }
    }

    // MARK: - UI Alerts & Notifications

    private func appleScriptLiteral(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    private enum QuitAnswer { case quit, keep, failed(String) }

    private func askUserToQuitClaude(otherNames: [String], workName: String) -> QuitAnswer {
        let message = "Claude сейчас запущен, а включился другой VPN: \(otherNames.joined(separator: ", ")).\n\nПока работает Claude, должен быть включён только \(workName). Закрыть Claude, чтобы переключиться?"
        // Кнопка «Оставить Claude» объявлена cancel button и приходит как ошибка -128. Остальные
        // ошибки (нет доступа к System Events, таймаут диалога) отличаем, чтобы не выдавать их
        // за ответ пользователя.
        let scriptText = """
        try
            with timeout of 660 seconds
                tell application "System Events"
                    activate
                    set dialogResult to display dialog \(appleScriptLiteral(message)) buttons {"Оставить Claude", "Закрыть Claude"} default button "Оставить Claude" cancel button "Оставить Claude" with icon caution with title "Claude VPN Guard" giving up after 600
                    if gave up of dialogResult then return "Оставить Claude"
                    return button returned of dialogResult
                end tell
            end timeout
        on error errMsg number errNum
            if errNum is -128 then return "Оставить Claude"
            return "ERROR " & errNum & ": " & errMsg
        end try
        """

        var error: NSDictionary?
        guard let script = NSAppleScript(source: scriptText) else { return .failed("скрипт не собрался") }
        let result = script.executeAndReturnError(&error).stringValue ?? ""
        if let error { return .failed("\(error[NSAppleScript.errorNumber] ?? "?"): \(error[NSAppleScript.errorMessage] ?? "")") }
        switch result {
        case "Закрыть Claude": return .quit
        case "Оставить Claude": return .keep
        default: return .failed(result)
        }
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
