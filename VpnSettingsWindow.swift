import AppKit
import UniformTypeIdentifiers

/// Окно «Настройки VPN». Общее для окна запуска Claude и агента в строке меню, поэтому ничего
/// не знает о Claude и его процессах: только редактирует vpn-config.json. Изменения применяются
/// по кнопке «Сохранить», чтобы агент не начал переключать VPN на полпути редактирования.
final class VpnSettingsWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let store: VpnConfigStore
    private var config: VpnConfig
    private let onClose: (Bool) -> Void
    private var didSave = false

    private let table = NSTableView()
    private let workPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let otherPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let addServiceButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let removeButton = NSButton(title: "Удалить", target: nil, action: nil)

    init(store: VpnConfigStore = VpnConfigStore(), level: NSWindow.Level = .normal, onClose: @escaping (Bool) -> Void) {
        self.store = store
        self.config = store.load()
        self.onClose = onClose
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 470),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Настройки VPN — Claude Guard"
        // Окно выбора аккаунта висит на уровне .floating; настройки, открытые из него,
        // должны быть на том же уровне, иначе окажутся под ним.
        window.level = level
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildContent()
        reloadAll()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present() {
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Layout

    private func buildContent() {
        guard let content = window?.contentView else { return }
        let width = content.bounds.width

        content.addSubview(label("Какой VPN включать", frame: NSRect(x: 20, y: 432, width: 400, height: 20), bold: true))

        content.addSubview(label("Пока работает Claude:", frame: NSRect(x: 20, y: 400, width: 180, height: 20)))
        workPopup.frame = NSRect(x: 200, y: 395, width: width - 220, height: 28)
        workPopup.target = self
        workPopup.action = #selector(rolesChanged)
        content.addSubview(workPopup)

        content.addSubview(label("Когда Claude закрыт:", frame: NSRect(x: 20, y: 368, width: 180, height: 20)))
        otherPopup.frame = NSRect(x: 200, y: 363, width: width - 220, height: 28)
        otherPopup.target = self
        otherPopup.action = #selector(rolesChanged)
        content.addSubview(otherPopup)

        let hint = label(
            "Пока Claude запущен, все остальные VPN выключаются, а при обрыве рабочего VPN Claude приостанавливается до его восстановления.",
            frame: NSRect(x: 20, y: 318, width: width - 40, height: 32), small: true
        )
        content.addSubview(hint)

        content.addSubview(label("Список VPN", frame: NSRect(x: 20, y: 288, width: 300, height: 20), bold: true))

        let scroll = NSScrollView(frame: NSRect(x: 20, y: 110, width: width - 40, height: 172))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        for (id, title, columnWidth, editable) in [
            ("name", "Название (двойной клик)", 210.0, true),
            ("kind", "Тип", 110.0, false),
            ("detail", "Чем управляется", 200.0, false),
        ] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = columnWidth
            column.isEditable = editable
            table.addTableColumn(column)
        }
        table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        content.addSubview(scroll)

        addServiceButton.frame = NSRect(x: 18, y: 72, width: 190, height: 28)
        content.addSubview(addServiceButton)

        let addApp = NSButton(title: "＋ Приложение…", target: self, action: #selector(addApplication))
        addApp.bezelStyle = .rounded
        addApp.frame = NSRect(x: 212, y: 72, width: 150, height: 28)
        content.addSubview(addApp)

        removeButton.bezelStyle = .rounded
        removeButton.target = self
        removeButton.action = #selector(removeSelected)
        removeButton.frame = NSRect(x: 366, y: 72, width: 100, height: 28)
        content.addSubview(removeButton)

        content.addSubview(label(
            "Системный VPN guard включает через scutil и проверяет по статусу туннеля. Приложение guard только запускает и закрывает — сам туннель в этом случае не проверяется.",
            frame: NSRect(x: 20, y: 40, width: width - 40, height: 30), small: true
        ))

        let cancel = NSButton(title: "Отмена", target: self, action: #selector(cancelClicked))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.frame = NSRect(x: width - 230, y: 8, width: 100, height: 30)
        content.addSubview(cancel)

        let save = NSButton(title: "Сохранить", target: self, action: #selector(saveClicked))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        save.frame = NSRect(x: width - 122, y: 8, width: 104, height: 30)
        content.addSubview(save)
    }

    private func label(_ text: String, frame: NSRect, bold: Bool = false, small: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.frame = frame
        field.font = bold ? .systemFont(ofSize: 13, weight: .semibold) : .systemFont(ofSize: small ? 11 : 13)
        if small { field.textColor = .secondaryLabelColor }
        return field
    }

    // MARK: Data

    private func reloadAll() {
        table.reloadData()
        rebuildRolePopups()
        rebuildAddServiceMenu()
        removeButton.isEnabled = !config.entries.isEmpty
    }

    private func rebuildRolePopups() {
        workPopup.removeAllItems()
        if config.entries.isEmpty {
            workPopup.addItem(withTitle: "Сначала добавьте VPN в список ниже")
            workPopup.lastItem?.representedObject = nil
        } else if config.work == nil {
            // Явный пустой пункт: без него попап молча показал бы первый VPN как выбранный,
            // хотя в конфиге рабочий VPN не задан.
            workPopup.addItem(withTitle: "— выберите —")
            workPopup.lastItem?.representedObject = nil
        }
        for entry in config.entries {
            workPopup.addItem(withTitle: entry.name)
            workPopup.lastItem?.representedObject = entry.id
        }
        select(config.workVpnId, in: workPopup)

        otherPopup.removeAllItems()
        otherPopup.addItem(withTitle: "Ничего не менять")
        otherPopup.lastItem?.representedObject = nil
        for entry in config.entries {
            otherPopup.addItem(withTitle: entry.name)
            otherPopup.lastItem?.representedObject = entry.id
        }
        select(config.otherVpnId, in: otherPopup)
    }

    private func select(_ id: String?, in popup: NSPopUpButton) {
        let index = popup.itemArray.firstIndex { ($0.representedObject as? String) == id } ?? 0
        popup.selectItem(at: index)
    }

    private func rebuildAddServiceMenu() {
        let menu = NSMenu()
        // Первый пункт pull-down меню — это заголовок кнопки, в списке он не показывается.
        menu.addItem(withTitle: "＋ VPN из системы", action: nil, keyEquivalent: "")
        let known = Set(config.entries.compactMap { $0.kind == .service ? $0.serviceName : nil })
        let fresh = SystemVpnServices.discover().filter { !known.contains($0.name) }
        if fresh.isEmpty {
            let item = menu.addItem(withTitle: "Все системные VPN уже добавлены", action: nil, keyEquivalent: "")
            item.isEnabled = false
        }
        for service in fresh {
            let appName = service.providerBundleId.flatMap(appDisplayName(bundleId:))
            let title = appName.map { "\($0) — «\(service.name)»" } ?? service.name
            let item = menu.addItem(withTitle: title, action: #selector(addService(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = service.name
        }
        addServiceButton.menu = menu
    }

    private func appDisplayName(bundleId: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    // MARK: Actions

    @objc private func rolesChanged() {
        config.workVpnId = workPopup.selectedItem?.representedObject as? String
        config.otherVpnId = otherPopup.selectedItem?.representedObject as? String
        // После выбора рабочего VPN убираем пункт «— выберите —».
        rebuildRolePopups()
    }

    @objc private func addService(_ sender: NSMenuItem) {
        guard let serviceName = sender.representedObject as? String,
              let service = SystemVpnServices.discover().first(where: { $0.name == serviceName }) else { return }
        let appName = service.providerBundleId.flatMap(appDisplayName(bundleId:))
        // Имя сервиса вроде «user-1» само по себе ничего не говорит, поэтому по умолчанию называем по приложению;
        // имя потом можно поменять двойным кликом.
        let name = appName.map { $0 == service.name ? $0 : "\($0) (\(service.name))" } ?? service.name
        appendEntry(VpnEntry(
            id: UUID().uuidString,
            name: name,
            kind: .service,
            serviceName: service.name,
            bundleId: service.providerBundleId,
            appPath: service.providerBundleId.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)?.path }
        ))
    }

    @objc private func addApplication() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.message = "Выберите приложение VPN"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.appendApplication(at: url)
        }
    }

    private func appendApplication(at url: URL) {
        guard let window else { return }
        let bundleId = Bundle(url: url)?.bundleIdentifier
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        let appEntry = VpnEntry(id: UUID().uuidString, name: name, kind: .app, serviceName: nil, bundleId: bundleId, appPath: url.path)

        // Многие VPN-приложения (на WireGuard, Xray и т. п.) создают системный сервис. Управлять им надёжнее:
        // guard видит реальный статус туннеля, а не просто «процесс запущен».
        let services = SystemVpnServices.discover().filter { bundleId != nil && $0.providerBundleId == bundleId }
        guard let service = services.first else {
            appendEntry(appEntry)
            return
        }
        let alert = NSAlert()
        alert.messageText = "У «\(name)» есть системный VPN «\(service.name)»"
        alert.informativeText = "Рекомендуется добавить его как системный VPN: тогда guard проверяет, что туннель действительно поднят. Как приложение guard только запускает и закрывает программу."
        alert.addButton(withTitle: "Как системный VPN")
        alert.addButton(withTitle: "Как приложение")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn {
                self?.appendEntry(VpnEntry(
                    id: UUID().uuidString,
                    name: name == service.name ? name : "\(name) (\(service.name))",
                    kind: .service,
                    serviceName: service.name,
                    bundleId: bundleId,
                    appPath: url.path
                ))
            } else {
                self?.appendEntry(appEntry)
            }
        }
    }

    private func appendEntry(_ entry: VpnEntry) {
        config.entries.append(entry)
        reloadAll()
        table.selectRowIndexes(IndexSet(integer: config.entries.count - 1), byExtendingSelection: false)
    }

    @objc private func removeSelected() {
        let row = table.selectedRow
        guard row >= 0, row < config.entries.count else { return }
        let removed = config.entries.remove(at: row)
        if config.workVpnId == removed.id { config.workVpnId = nil }
        if config.otherVpnId == removed.id { config.otherVpnId = nil }
        reloadAll()
    }

    @objc private func cancelClicked() {
        window?.close()
    }

    @objc private func saveClicked() {
        guard let window else { return }
        // Завершаем редактирование ячейки: иначе введённое, но не подтверждённое Enter имя потеряется.
        window.makeFirstResponder(nil)

        if let problem = validationProblem() {
            let alert = NSAlert()
            alert.messageText = "Настройки не сохранены"
            alert.informativeText = problem
            alert.beginSheetModal(for: window)
            return
        }
        do {
            try store.save(config)
            didSave = true
            window.close()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Не удалось сохранить настройки VPN"
            alert.informativeText = error.localizedDescription
            alert.beginSheetModal(for: window)
        }
    }

    private func validationProblem() -> String? {
        guard config.work != nil else {
            return "Выберите VPN, который должен работать вместе с Claude. Без него VPN Guard не запустит Claude."
        }
        if config.otherVpnId != nil && config.otherVpnId == config.workVpnId {
            return "VPN для Claude и VPN без Claude должны быть разными. Если после Claude ничего переключать не нужно, выберите «Ничего не менять»."
        }
        if config.entries.contains(where: { $0.name.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return "У каждого VPN в списке должно быть название."
        }
        return nil
    }

    func windowWillClose(_ notification: Notification) {
        onClose(didSave)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { config.entries.count }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard row < config.entries.count else { return nil }
        let entry = config.entries[row]
        switch tableColumn?.identifier.rawValue {
        case "name": return entry.name
        case "kind": return entry.kindTitle
        default: return entry.detail
        }
    }

    func tableView(_ tableView: NSTableView, setObjectValue object: Any?, for tableColumn: NSTableColumn?, row: Int) {
        guard tableColumn?.identifier.rawValue == "name", row < config.entries.count,
              let name = (object as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return }
        config.entries[row].name = name
        rebuildRolePopups()
    }
}
