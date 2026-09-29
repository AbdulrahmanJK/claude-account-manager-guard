import Cocoa
import NetworkExtension

struct ProfileSlot: Codable {
    var id: String
    var name: String
    var icon: String?
}

final class ActionIconButton: NSButton {
    var isHovered: Bool = false {
        didSet { updateAppearance() }
    }
    var hoverColor: NSColor = NSColor.white.withAlphaComponent(0.2)
    var normalColor: NSColor = NSColor.white.withAlphaComponent(0.08)
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = frameRect.height / 2
        layer?.masksToBounds = true
        updateAppearance()
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = trackingArea { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self, userInfo: nil)
        addTrackingArea(area)
        self.trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    private func updateAppearance() {
        layer?.backgroundColor = isHovered ? hoverColor.cgColor : normalColor.cgColor
    }
}

final class ProfileCardButton: NSButton {
    var isHovered: Bool = false {
        didSet { updateAppearance() }
    }
    var accentBorderColor: NSColor = .controlAccentColor
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        updateAppearance()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = trackingArea { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self, userInfo: nil)
        addTrackingArea(area)
        self.trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    private func updateAppearance() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            if isHovered {
                layer?.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
                layer?.borderWidth = 1.5
                layer?.borderColor = accentBorderColor.withAlphaComponent(0.8).cgColor
            } else {
                layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
                layer?.borderWidth = 1.0
                layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
            }
        }
    }
}

@main
final class GatekeeperApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = GatekeeperApp()
        app.delegate = delegate
        app.run()
    }

    private var profilePickerWindow: NSWindow?
    private var visualEffectView: NSVisualEffectView?
    private var hudWindow: NSWindow?
    private var localKeyMonitor: Any?
    private var connectionTimer: Timer?
    private var connectionFinished: Bool = false
    private var launchDeadline: Date = .distantPast
    private var isCreatingSlot: Bool = false
    private let profileStore = ProfileStore()

    private let enginePath: String = NSString(string: "~/.claude-vpn-guard/Claude-Engine.app").expandingTildeInPath
    private let claudeBundleId = "com.anthropic.claudefordesktop"
    private let guardSettings = GuardSettings.load()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let icon = Bundle.main.image(forResource: "electron.icns") ?? (NSWorkspace.shared.icon(forFile: enginePath) as NSImage?) {
            NSApp.applicationIconImage = icon
        }

        guard FileManager.default.fileExists(atPath: enginePath) else {
            showErrorAlert(
                title: "Ошибка запуска Claude",
                message: "Движок Claude не найден по пути:\n\(enginePath)\n\nЗапустите ~/.claude-vpn-guard/install.sh"
            )
            NSApp.terminate(nil)
            return
        }

        guard guardSettings != nil else {
            showErrorAlert(title: "Настройки VPN не найдены", message: "Проверьте ~/.claude-vpn-guard/guard-settings.json и повторите установку.")
            NSApp.terminate(nil)
            return
        }

        do {
            _ = try profileStore.validateLinks()
        } catch {
            showErrorAlert(title: "Профили Claude требуют восстановления", message: error.localizedDescription + "\n\nЗапустите установщик после сохранения копии данных.")
            NSApp.terminate(nil)
            return
        }

        if isClaudeEngineRunning() {
            let activeName = getCurrentProfileDisplayName()
            showAlreadyRunningAlert(profileName: activeName)
            activateRunningEngine()
            NSApp.terminate(nil)
            return
        }

        showProfilePicker()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        cancelPicker()
        return true
    }

    // MARK: - Profile Picker UI

    private func showProfilePicker() {
        NSApp.setActivationPolicy(.regular)

        let width: CGFloat = 380
        let slots = loadProfiles()
        let windowHeight = computeWindowHeight(for: slots.count)

        let screenRect = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let windowRect = NSRect(
            x: screenRect.midX - width / 2,
            y: screenRect.midY - windowHeight / 2,
            width: width,
            height: windowHeight
        )

        let window = NSWindow(
            contentRect: windowRect,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.delegate = self
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating

        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true

        let visualEffect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: windowHeight))
        visualEffect.material = .hudWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 20
        visualEffect.layer?.masksToBounds = true
        self.visualEffectView = visualEffect

        window.contentView = visualEffect
        self.profilePickerWindow = window

        buildPickerContent()

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        setupKeyMonitor()
    }

    private func computeWindowHeight(for slotCount: Int) -> CGFloat {
        let rowHeight: CGFloat = 54
        let rowSpacing: CGFloat = 8
        let contentHeight = CGFloat(slotCount) * rowHeight + CGFloat(max(0, slotCount - 1)) * rowSpacing
        let listHeight = min(contentHeight, 240)
        return 114 + 12 + listHeight + 10 + 36 + 8 + 18 + 14
    }

    private func buildPickerContent() {
        guard let visualEffect = visualEffectView, let window = profilePickerWindow else { return }

        visualEffect.subviews.forEach { $0.removeFromSuperview() }

        let slots = loadProfiles()
        let width = window.frame.width
        let height = window.frame.height

        // 1. Иконка Claude
        let iconView = NSImageView(frame: NSRect(x: (width - 50) / 2, y: height - 64, width: 50, height: 50))
        if let icon = Bundle.main.image(forResource: "electron.icns") ?? (NSWorkspace.shared.icon(forFile: enginePath) as NSImage?) {
            iconView.image = icon
        }
        visualEffect.addSubview(iconView)

        // 3. Заголовок
        let titleLabel = NSTextField(frame: NSRect(x: 16, y: height - 90, width: width - 32, height: 22))
        titleLabel.stringValue = "Claude Desktop"
        titleLabel.isEditable = false
        titleLabel.isBezeled = false
        titleLabel.drawsBackground = false
        titleLabel.alignment = .center
        titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .bold)
        titleLabel.textColor = .labelColor
        visualEffect.addSubview(titleLabel)

        // 4. Подзаголовок
        let subLabel = NSTextField(frame: NSRect(x: 16, y: height - 110, width: width - 32, height: 16))
        subLabel.stringValue = "Выберите профиль для входа:"
        subLabel.isEditable = false
        subLabel.isBezeled = false
        subLabel.drawsBackground = false
        subLabel.alignment = .center
        subLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .regular)
        subLabel.textColor = .secondaryLabelColor
        visualEffect.addSubview(subLabel)

        // 5. Список слотов
        let rowHeight: CGFloat = 54
        let rowSpacing: CGFloat = 8
        let totalListContentHeight = CGFloat(slots.count) * rowHeight + CGFloat(max(0, slots.count - 1)) * rowSpacing
        let visibleListHeight = min(totalListContentHeight, 240)
        let listY = height - 110 - 12 - visibleListHeight

        let scrollView = NSScrollView(frame: NSRect(x: 20, y: listY, width: width - 40, height: visibleListHeight))
        scrollView.hasVerticalScroller = totalListContentHeight > 240
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        let documentView = NSView(frame: NSRect(x: 0, y: 0, width: scrollView.contentSize.width, height: totalListContentHeight))

        for (index, slot) in slots.enumerated() {
            let rowY = totalListContentHeight - CGFloat(index + 1) * rowHeight - CGFloat(index) * rowSpacing
            let rowFrame = NSRect(x: 0, y: rowY, width: documentView.bounds.width, height: rowHeight)

            let canDelete = slots.count > 1
            let cardWidth = canDelete ? (rowFrame.width - 38) : rowFrame.width

            // Кнопка карточки профиля
            let cardBtn = ProfileCardButton(frame: NSRect(x: 0, y: 0, width: cardWidth, height: rowHeight))
            cardBtn.tag = index
            cardBtn.target = self
            cardBtn.action = #selector(didSelectSlotButton(_:))

            let pStyle = NSMutableParagraphStyle()
            pStyle.alignment = .left
            pStyle.lineSpacing = 3

            let iconStr = slot.icon ?? "👤"
            let keyHint = (index == 0) ? "[ 1 / ⏎ ]" : "[ \(index + 1) ]"

            let attr = NSMutableAttributedString()
            attr.append(NSAttributedString(string: "  \(iconStr)  \(index + 1). \(slot.name)\n", attributes: [
                .font: NSFont.systemFont(ofSize: 13.5, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: pStyle
            ]))

            if let email = getProfileEmail(profileId: slot.id) {
                attr.append(NSAttributedString(string: "       ✉️  \(email)   •   \(keyHint)", attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: pStyle
                ]))
            } else {
                attr.append(NSAttributedString(string: "       ⚪️  Пустой слот   •   \(keyHint)", attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: pStyle
                ]))
            }
            cardBtn.attributedTitle = attr

            let rowContainer = NSView(frame: rowFrame)
            rowContainer.addSubview(cardBtn)

            // Кнопка удаления слота
            if canDelete {
                let deleteBtn = ActionIconButton(frame: NSRect(x: rowFrame.width - 32, y: (rowHeight - 30) / 2, width: 30, height: 30))
                deleteBtn.title = "🗑"
                deleteBtn.font = NSFont.systemFont(ofSize: 12)
                deleteBtn.tag = index
                deleteBtn.hoverColor = NSColor.systemRed.withAlphaComponent(0.25)
                deleteBtn.target = self
                deleteBtn.action = #selector(didClickDeleteSlot(_:))
                deleteBtn.toolTip = "Удалить слот «\(slot.name)»"
                rowContainer.addSubview(deleteBtn)
            }

            documentView.addSubview(rowContainer)
        }

        scrollView.documentView = documentView
        if totalListContentHeight > 240 {
            documentView.scroll(NSPoint(x: 0, y: totalListContentHeight - 240))
        }
        visualEffect.addSubview(scrollView)

        // 6. Кнопка "+ Добавить аккаунт" с лоадером
        let addY = listY - 10 - 36
        let addBtn = ActionIconButton(frame: NSRect(x: 20, y: addY, width: width - 40, height: 36))
        addBtn.layer?.cornerRadius = 10
        addBtn.title = "＋  Добавить аккаунт"
        addBtn.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        addBtn.contentTintColor = .labelColor
        addBtn.hoverColor = NSColor.controlAccentColor.withAlphaComponent(0.25)
        addBtn.target = self
        addBtn.action = #selector(didClickAddSlot(_:))
        visualEffect.addSubview(addBtn)

        let spinner = NSProgressIndicator(frame: NSRect(x: (width - 40 - 18) / 2, y: (36 - 18) / 2, width: 18, height: 18))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isHidden = true
        addBtn.addSubview(spinner)

        // 7. Подсказка горячих клавиш внизу
        let hintLabel = NSTextField(frame: NSRect(x: 16, y: 12, width: width - 32, height: 16))
        let maxSlotsHint = min(slots.count, 9)
        hintLabel.stringValue = "[ 1\(maxSlotsHint > 1 ? "..\(maxSlotsHint)" : "") ] Выбор   •   [ Esc ] Отмена"
        hintLabel.isEditable = false
        hintLabel.isBezeled = false
        hintLabel.drawsBackground = false
        hintLabel.alignment = .center
        hintLabel.font = NSFont.systemFont(ofSize: 10.5, weight: .regular)
        hintLabel.textColor = .secondaryLabelColor
        visualEffect.addSubview(hintLabel)
    }

    private func setupKeyMonitor() {
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyMonitor = nil
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, !self.isCreatingSlot else { return event }

            // Esc -> Отмена
            if event.keyCode == 53 {
                self.cancelPicker()
                return nil
            }

            let slots = self.loadProfiles()
            if let idx = self.detectSlotIndex(eventCharacters: event.characters, keyCode: event.keyCode, maxSlots: slots.count) {
                self.selectSlot(slots[idx])
                return nil
            }

            return event
        }
    }

    private func detectSlotIndex(eventCharacters: String?, keyCode: UInt16, maxSlots: Int) -> Int? {
        if keyCode == 36 || keyCode == 76 { // Return / Enter
            return maxSlots > 0 ? 0 : nil
        }
        if let ch = eventCharacters?.first, let digit = Int(String(ch)), digit >= 1 && digit <= maxSlots {
            return digit - 1
        }
        let codeMap: [UInt16: Int] = [
            18: 0, 83: 0,
            19: 1, 84: 1,
            20: 2, 85: 2,
            21: 3, 86: 3,
            23: 4, 87: 4,
            22: 5, 88: 5,
            26: 6, 89: 6,
            28: 7, 91: 7,
            25: 8, 92: 8
        ]
        if let idx = codeMap[keyCode], idx < maxSlots {
            return idx
        }
        return nil
    }

    @objc private func didSelectSlotButton(_ sender: NSButton) {
        let slots = loadProfiles()
        if sender.tag >= 0 && sender.tag < slots.count {
            selectSlot(slots[sender.tag])
        }
    }

    @objc private func didClickDeleteSlot(_ sender: NSButton) {
        let slots = loadProfiles()
        if sender.tag >= 0 && sender.tag < slots.count {
            confirmAndDeleteSlot(slot: slots[sender.tag])
        }
    }

    @objc private func didClickAddSlot(_ sender: NSButton) {
        guard !isCreatingSlot else { return }
        isCreatingSlot = true

        sender.title = ""
        sender.isEnabled = false

        if let spinner = sender.subviews.compactMap({ $0 as? NSProgressIndicator }).first {
            spinner.isHidden = false
            spinner.startAnimation(nil)
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            Thread.sleep(forTimeInterval: 0.35) // визуальная индикация лоадера

            let creationError: Error?
            do { try self.createNewSlot(); creationError = nil }
            catch { creationError = error }

            DispatchQueue.main.async {
                self.isCreatingSlot = false
                self.refreshPickerUI()
                if let creationError {
                    self.showErrorAlert(title: "Не удалось создать профиль", message: creationError.localizedDescription)
                }
            }
        }
    }

    private func refreshPickerUI() {
        guard let window = profilePickerWindow else { return }

        let slots = loadProfiles()
        let newHeight = computeWindowHeight(for: slots.count)
        let curFrame = window.frame
        let newY = curFrame.midY - newHeight / 2
        let newFrame = NSRect(x: curFrame.origin.x, y: newY, width: curFrame.width, height: newHeight)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            window.animator().setFrame(newFrame, display: true)
            self.visualEffectView?.frame = NSRect(x: 0, y: 0, width: newFrame.width, height: newFrame.height)
        } completionHandler: {
            self.buildPickerContent()
            self.setupKeyMonitor()
        }
    }

    private func createNewSlot() throws {
        var slots = loadProfiles()
        let nextIndex = slots.count + 1
        let newId = "slot_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let newName = "Аккаунт \(nextIndex)"
        let newSlot = ProfileSlot(id: newId, name: newName, icon: "👤")

        let profileDir = profileStore.profiles.appendingPathComponent(newId, isDirectory: true)
        try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: false)
        do {
            try "{}".write(to: profileDir.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
            slots.append(newSlot)
            try saveProfiles(slots)
        } catch {
            try? FileManager.default.removeItem(at: profileDir)
            throw error
        }
    }

    private func confirmAndDeleteSlot(slot: ProfileSlot) {
        var slots = loadProfiles()
        guard slots.count > 1 else {
            showErrorAlert(title: "Удаление невозможно", message: "Нельзя удалить единственный оставшийся слот.")
            return
        }

        if isClaudeEngineRunning() {
            showErrorAlert(title: "Claude запущен", message: "Невозможно удалить слот во время работы Claude. Сначала закройте Claude.")
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Точно удалить слот «\(slot.name)»?"
        if let email = getProfileEmail(profileId: slot.id) {
            alert.informativeText = "Привязанный аккаунт: \(email)\n\nВсе данные авторизации, сессии и локальные файлы этого слота будут безвозвратно удалены."
        } else {
            alert.informativeText = "Слот пустой (не авторизован). Профиль будет удален безвозвратно."
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Удалить")
        alert.addButton(withTitle: "Отмена")

        if alert.runModal() == .alertFirstButtonReturn {
            do {
                try profileStore.acquireLock()
                defer { profileStore.releaseLock() }
                guard !isClaudeEngineRunning() else { throw ProfileStoreError.busy }
                let currentActive = try profileStore.validateLinks()
                if currentActive == slot.id, let next = slots.first(where: { $0.id != slot.id }) {
                    try profileStore.switchProfile(to: next.id)
                }
                let remaining = slots.filter { $0.id != slot.id }
                try saveProfiles(remaining)
                let dirToDelete = profileStore.profiles.appendingPathComponent(slot.id, isDirectory: true)
                try FileManager.default.removeItem(at: dirToDelete)
                slots = remaining
                refreshPickerUI()
            } catch {
                showErrorAlert(title: "Не удалось удалить профиль", message: error.localizedDescription)
            }
        }
    }

    @objc private func cancelPicker() {
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyMonitor = nil
        }
        profilePickerWindow?.orderOut(nil)
        profilePickerWindow = nil
        profileStore.releaseLock()
        NSApp.terminate(nil)
    }

    private func selectSlot(_ slot: ProfileSlot) {
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyMonitor = nil
        }
        profilePickerWindow?.orderOut(nil)
        profilePickerWindow = nil

        do {
            try profileStore.acquireLock()
            guard !isClaudeEngineRunning() else { throw ProfileStoreError.busy }
            try profileStore.switchProfile(to: slot.id)
        } catch {
            profileStore.releaseLock()
            showErrorAlert(title: "Ошибка переключения", message: error.localizedDescription)
            NSApp.terminate(nil)
            return
        }

        connectionFinished = false
        launchDeadline = Date().addingTimeInterval(10)
        disconnectDefaultVpn()
        loadSecureVpnManager { [weak self] manager in
            guard let self = self else { return }
            guard let manager else {
                self.connectionFailed(reason: "Не удалось загрузить настройки защищённого VPN")
                return
            }
            let status = manager.connection.status

            if status == .connected {
                self.launchClaudeEngine()
                return
            }

            self.showConnectingHUD(profileName: slot.name)
            self.beginSecureConnection(manager: manager)
        }
    }

    // MARK: - Profile Engine & Storage

    private func loadProfiles() -> [ProfileSlot] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let jsonPath = "\(home)/.claude-vpn-guard/profiles.json"
        let profilesDir = "\(home)/.claude-vpn-guard/profiles"
        let fm = FileManager.default

        var slots: [ProfileSlot] = []

        if let data = try? Data(contentsOf: URL(fileURLWithPath: jsonPath)),
           let loaded = try? JSONDecoder().decode([ProfileSlot].self, from: data) {
            slots = loaded
        } else {
            if fm.fileExists(atPath: "\(profilesDir)/work") {
                slots.append(ProfileSlot(id: "work", name: "Рабочий", icon: "🏢"))
            }
            if fm.fileExists(atPath: "\(profilesDir)/personal") {
                slots.append(ProfileSlot(id: "personal", name: "Личный", icon: "👤"))
            }
        }

        if let subdirs = try? fm.contentsOfDirectory(atPath: profilesDir) {
            for dir in subdirs {
                guard !dir.hasPrefix(".") else { continue }
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: "\(profilesDir)/\(dir)", isDirectory: &isDir), isDir.boolValue {
                    if !slots.contains(where: { $0.id == dir }) {
                        slots.append(ProfileSlot(id: dir, name: dir.capitalized, icon: "👤"))
                    }
                }
            }
        }

        if slots.isEmpty {
            slots = [
                ProfileSlot(id: "work", name: "Рабочий", icon: "🏢"),
                ProfileSlot(id: "personal", name: "Личный", icon: "👤")
            ]
        }

        return slots
    }

    private func saveProfiles(_ slots: [ProfileSlot]) throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let jsonPath = "\(home)/.claude-vpn-guard/profiles.json"
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(slots)
        try data.write(to: URL(fileURLWithPath: jsonPath), options: .atomic)
    }

    private func getProfileEmail(profileId: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let profileDir = "\(home)/.claude-vpn-guard/profiles/\(profileId)"

        // 1. Проверяем .claude.json
        let jsonPath = "\(profileDir)/.claude.json"
        if let data = try? Data(contentsOf: URL(fileURLWithPath: jsonPath)) {
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let oauth = obj["oauthAccount"] as? [String: Any],
                   let email = oauth["emailAddress"] as? String, !email.isEmpty {
                    return email
                }
                if let email = obj["emailAddress"] as? String, !email.isEmpty {
                    return email
                }
            }
            if let str = String(data: data, encoding: .utf8) {
                let pattern = "\"emailAddress\"\\s*:\\s*\"([^\"]+)\""
                if let regex = try? NSRegularExpression(pattern: pattern),
                   let match = regex.firstMatch(in: str, range: NSRange(str.startIndex..., in: str)),
                   let range = Range(match.range(at: 1), in: str) {
                    return String(str[range])
                }
            }
        }

        // 2. Проверяем IndexedDB blob storage (Google auth, Apple auth, SSO сессии)
        let fm = FileManager.default
        let blobDir = "\(profileDir)/IndexedDB/https_claude.ai_0.indexeddb.blob"
        let emailPattern = "email_address[^a-zA-Z0-9._%+-]+([a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,})"
        let regex = try? NSRegularExpression(pattern: emailPattern)

        if let enumerator = fm.enumerator(atPath: blobDir) {
            while let file = enumerator.nextObject() as? String {
                let fullPath = "\(blobDir)/\(file)"
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: fullPath, isDirectory: &isDir), !isDir.boolValue else { continue }

                guard let data = try? Data(contentsOf: URL(fileURLWithPath: fullPath)) else { continue }
                if let str = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
                    if let match = regex?.firstMatch(in: str, range: NSRange(str.startIndex..., in: str)),
                       let range = Range(match.range(at: 1), in: str) {
                        let email = String(str[range])
                        return email
                    }
                }
            }
        }

        // 3. Резервный поиск в LevelDB логах
        let leveldbDir = "\(profileDir)/IndexedDB/https_claude.ai_0.indexeddb.leveldb"
        if let enumerator = fm.enumerator(atPath: leveldbDir) {
            while let file = enumerator.nextObject() as? String {
                let fullPath = "\(leveldbDir)/\(file)"
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: fullPath, isDirectory: &isDir), !isDir.boolValue else { continue }

                guard let data = try? Data(contentsOf: URL(fileURLWithPath: fullPath)) else { continue }
                if let str = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
                    if let match = regex?.firstMatch(in: str, range: NSRange(str.startIndex..., in: str)),
                       let range = Range(match.range(at: 1), in: str) {
                        let email = String(str[range])
                        return email
                    }
                }
            }
        }

        return nil
    }

    private func getCurrentProfileDisplayName() -> String {
        let currentId = (try? profileStore.currentProfileId()) ?? "неизвестный"

        let slots = loadProfiles()
        if let found = slots.first(where: { $0.id == currentId }) {
            return found.name
        }
        return currentId
    }

    private func isClaudeEngineRunning() -> Bool {
        let runningApps = NSWorkspace.shared.runningApplications
        for app in runningApps {
            if app.bundleIdentifier == claudeBundleId && app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                return true
            }
            if let bundleUrl = app.bundleURL, bundleUrl.path.contains("Claude-Engine.app") {
                return true
            }
        }
        let task = Process()
        task.launchPath = "/usr/bin/pgrep"
        task.arguments = ["-f", "Claude-Engine.app/Contents/MacOS/Claude"]
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run()
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    private func activateRunningEngine() {
        let runningApps = NSWorkspace.shared.runningApplications
        for app in runningApps {
            if app.bundleIdentifier == claudeBundleId && app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                app.activate(options: [.activateIgnoringOtherApps])
                return
            }
        }
    }

    private func showAlreadyRunningAlert(profileName: String) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Claude уже запущен"
        alert.informativeText = "В данный момент активен профиль: \(profileName).\n\nЧтобы переключиться на другой аккаунт, пожалуйста, сначала полностью закройте Claude (Cmd+Q)."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Понятно")
        alert.runModal()
    }

    // MARK: - Secure Connection Flow

    private func beginSecureConnection(manager: NEVPNManager) {
        disconnectDefaultVpn()

        NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: manager.connection,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            let status = manager.connection.status
            if status == .connected {
                self.connectionSucceeded()
            }
        }

        do {
            try manager.connection.startVPNTunnel()
        } catch {
            self.connectionFailed(reason: "Ошибка старта VPN: \(error.localizedDescription)")
            return
        }

        connectionTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: false) { [weak self] _ in
            self?.connectionFailed(reason: "Таймаут подключения к защищённому VPN (15 сек).")
        }
    }

    private func connectionSucceeded() {
        guard !connectionFinished else { return }
        connectionFinished = true
        connectionTimer?.invalidate()
        connectionTimer = nil

        DispatchQueue.main.async { [weak self] in
            self?.hudWindow?.orderOut(nil)
            self?.launchClaudeEngine()
        }
    }

    private func connectionFailed(reason: String) {
        guard !connectionFinished else { return }
        connectionFinished = true
        connectionTimer?.invalidate()
        connectionTimer = nil

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.hudWindow?.orderOut(nil)

            self.connectDefaultVpn()

            self.showErrorAlert(
                title: "Защита VPN: Запуск Claude отменен",
                message: "Не удалось подключиться к защищенному VPN.\nПричина: \(reason)\n\nClaude не был запущен."
            )
            self.profileStore.releaseLock()
            NSApp.terminate(nil)
        }
    }

    private func launchClaudeEngine() {
        guard NEVPNManager.shared().connection.status == .connected else {
            connectionFinished = false
            connectionFailed(reason: "VPN отключился до запуска Claude")
            return
        }
        guard getDefaultVpnStatus() == "Disconnected" else {
            if Date() < launchDeadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.launchClaudeEngine()
                }
            } else {
                connectionFinished = false
                connectionFailed(reason: "Повседневный VPN не отключился перед запуском Claude")
            }
            return
        }
        let engineUrl = URL(fileURLWithPath: enginePath)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true

        NSWorkspace.shared.openApplication(at: engineUrl, configuration: config) { app, error in
            DispatchQueue.main.async {
                if let error = error {
                    self.showErrorAlert(title: "Ошибка запуска Claude", message: error.localizedDescription)
                }
                self.profileStore.releaseLock()
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: - UI

    private func showConnectingHUD(profileName: String) {
        NSApp.setActivationPolicy(.regular)

        let width: CGFloat = 340
        let height: CGFloat = 170

        let screenRect = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let windowRect = NSRect(
            x: screenRect.midX - width / 2,
            y: screenRect.midY - height / 2,
            width: width,
            height: height
        )

        let window = NSWindow(
            contentRect: windowRect,
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating

        let visualEffect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        visualEffect.material = .hudWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 20
        visualEffect.layer?.masksToBounds = true

        let iconView = NSImageView(frame: NSRect(x: (width - 56) / 2, y: 94, width: 56, height: 56))
        if let icon = Bundle.main.image(forResource: "electron.icns") ?? (NSWorkspace.shared.icon(forFile: enginePath) as NSImage?) {
            iconView.image = icon
        }
        visualEffect.addSubview(iconView)

        let titleLabel = NSTextField(frame: NSRect(x: 16, y: 64, width: width - 32, height: 22))
        titleLabel.stringValue = "Подключение к защищенному VPN..."
        titleLabel.isEditable = false
        titleLabel.isBezeled = false
        titleLabel.drawsBackground = false
        titleLabel.alignment = .center
        titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .labelColor
        visualEffect.addSubview(titleLabel)

        let subLabel = NSTextField(frame: NSRect(x: 16, y: 44, width: width - 32, height: 18))
        subLabel.stringValue = "Профиль: \(profileName) • Защита соединения"
        subLabel.isEditable = false
        subLabel.isBezeled = false
        subLabel.drawsBackground = false
        subLabel.alignment = .center
        subLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        subLabel.textColor = .secondaryLabelColor
        visualEffect.addSubview(subLabel)

        let spinner = NSProgressIndicator(frame: NSRect(x: (width - 20) / 2, y: 16, width: 20, height: 20))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        visualEffect.addSubview(spinner)

        window.contentView = visualEffect
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.hudWindow = window
    }

    private func showErrorAlert(title: String, message: String) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Понятно")
        alert.runModal()
    }

    // MARK: - Helpers

    private func loadSecureVpnManager(completion: @escaping (NEVPNManager?) -> Void) {
        let manager = NEVPNManager.shared()
        manager.loadFromPreferences { error in
            DispatchQueue.main.async {
                if let error = error {
                    print("Ошибка загрузки NEVPNManager: \(error)")
                    completion(nil)
                } else {
                    completion(manager)
                }
            }
        }
    }

    private func disconnectDefaultVpn() {
        guard let serviceName = guardSettings?.defaultVpnServiceName else { return }
        let task = Process()
        task.launchPath = "/usr/sbin/scutil"
        task.arguments = ["--nc", "stop", serviceName]
        try? task.run()
        task.waitUntilExit()
    }

    private func connectDefaultVpn() {
        guard let serviceName = guardSettings?.defaultVpnServiceName else { return }
        let task = Process()
        task.launchPath = "/usr/sbin/scutil"
        task.arguments = ["--nc", "start", serviceName]
        try? task.run()
        task.waitUntilExit()
    }

    private func getDefaultVpnStatus() -> String {
        guard let serviceName = guardSettings?.defaultVpnServiceName else { return "" }
        let task = Process()
        task.launchPath = "/usr/sbin/scutil"
        task.arguments = ["--nc", "status", serviceName]
        let pipe = Pipe()
        task.standardOutput = pipe
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return ""
        }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return output.components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
