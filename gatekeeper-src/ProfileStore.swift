import Foundation
import Darwin

enum ProfileStoreError: LocalizedError {
    case invalidProfile(String)
    case missingProfile(String)
    case unexpectedPath(String)
    case busy
    case system(String)

    var errorDescription: String? {
        switch self {
        case .invalidProfile(let id): return "Недопустимый идентификатор профиля: \(id)"
        case .missingProfile(let id): return "Профиль \(id) не найден или повреждён. Данные не изменены."
        case .unexpectedPath(let path): return "Неожиданный путь \(path). Проверьте установку перед запуском Claude."
        case .busy: return "Другой запуск Claude уже переключает профиль. Повторите попытку позже."
        case .system(let message): return message
        }
    }
}

/// All public links are stable. Only `active` changes when the selected account changes.
final class ProfileStore {
    let base: URL
    let profiles: URL
    let active: URL
    let appSupport: URL
    let claudeJSON: URL
    let marker: URL
    private let lockFile: URL
    private var lockFD: Int32 = -1
    private let fm = FileManager.default

    init(base: URL? = nil, appSupport: URL? = nil, claudeJSON: URL? = nil) {
        let home = fm.homeDirectoryForCurrentUser
        self.base = base ?? home.appendingPathComponent(".claude-vpn-guard", isDirectory: true)
        self.profiles = self.base.appendingPathComponent("profiles", isDirectory: true)
        self.active = self.base.appendingPathComponent("active")
        self.appSupport = appSupport ?? home.appendingPathComponent("Library/Application Support/Claude")
        self.claudeJSON = claudeJSON ?? home.appendingPathComponent(".claude.json")
        self.marker = self.base.appendingPathComponent("current_profile.txt")
        self.lockFile = self.base.appendingPathComponent("profile-switch.lock")
    }

    deinit { releaseLock() }

    func acquireLock() throws {
        guard lockFD < 0 else { return }
        let fd = open(lockFile.path, O_CREAT | O_RDWR, mode_t(0o600))
        guard fd >= 0 else { throw ProfileStoreError.system("Не удалось открыть блокировку профилей: \(String(cString: strerror(errno)))") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw ProfileStoreError.busy
        }
        lockFD = fd
    }

    func releaseLock() {
        guard lockFD >= 0 else { return }
        flock(lockFD, LOCK_UN)
        close(lockFD)
        lockFD = -1
    }

    private func validId(_ id: String) -> Bool {
        !id.isEmpty && id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
    }

    private func profileURL(_ id: String) throws -> URL {
        guard validId(id) else { throw ProfileStoreError.invalidProfile(id) }
        let dir = profiles.appendingPathComponent(id, isDirectory: true)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue,
              fm.fileExists(atPath: dir.appendingPathComponent(".claude.json").path) else {
            throw ProfileStoreError.missingProfile(id)
        }
        return dir
    }

    private func linkTarget(_ url: URL) throws -> String? {
        do { return try fm.destinationOfSymbolicLink(atPath: url.path) }
        catch CocoaError.fileReadNoSuchFile { return nil }
        catch {
            if !fm.fileExists(atPath: url.path) { return nil }
            throw ProfileStoreError.unexpectedPath(url.path)
        }
    }

    private func replaceLink(at path: URL, with target: String) throws {
        let temporary = path.deletingLastPathComponent().appendingPathComponent(".\(path.lastPathComponent).\(UUID().uuidString).tmp")
        guard symlink(target, temporary.path) == 0 else {
            throw ProfileStoreError.system("Не удалось создать ссылку \(path.path): \(String(cString: strerror(errno)))")
        }
        guard rename(temporary.path, path.path) == 0 else {
            let message = String(cString: strerror(errno))
            unlink(temporary.path)
            throw ProfileStoreError.system("Не удалось переключить ссылку \(path.path): \(message)")
        }
    }

    private func profileId(forTarget target: String) throws -> String {
        let url = URL(fileURLWithPath: target).standardizedFileURL
        guard url.deletingLastPathComponent().path == profiles.standardizedFileURL.path else {
            throw ProfileStoreError.unexpectedPath(target)
        }
        let id = url.lastPathComponent
        _ = try profileURL(id)
        return id
    }

    func currentProfileId() throws -> String {
        guard let target = try linkTarget(active) else {
            throw ProfileStoreError.unexpectedPath(active.path)
        }
        return try profileId(forTarget: target)
    }

    func validateLinks() throws -> String {
        let id = try currentProfileId()
        guard try linkTarget(appSupport) == active.path,
              try linkTarget(claudeJSON) == active.path + "/.claude.json" else {
            throw ProfileStoreError.unexpectedPath("ссылки Claude указывают на разные профили")
        }
        return id
    }

    /// Used by the installer while Claude is stopped. Migrates legacy direct links once.
    func prepareLinks(preferredId: String = "work") throws {
        try acquireLock()
        defer { releaseLock() }

        let oldActive = try linkTarget(active)
        let oldApp = try linkTarget(appSupport)
        let oldJSON = try linkTarget(claudeJSON)
        let id: String
        if let oldActive { id = try profileId(forTarget: oldActive) }
        else if let oldApp, oldApp != active.path { id = try profileId(forTarget: oldApp) }
        else { id = preferredId }
        let directory = try profileURL(id)

        // Refuse to replace a real directory or a link to data outside this installation.
        if let oldApp, oldApp != active.path { _ = try profileId(forTarget: oldApp) }
        if let oldJSON, oldJSON != active.path + "/.claude.json",
           oldJSON != directory.appendingPathComponent(".claude.json").path {
            throw ProfileStoreError.unexpectedPath(oldJSON)
        }
        guard oldApp != nil || !fm.fileExists(atPath: appSupport.path),
              oldJSON != nil || !fm.fileExists(atPath: claudeJSON.path) else {
            throw ProfileStoreError.unexpectedPath("существующий каталог Claude или ~/.claude.json")
        }

        do {
            if oldActive == nil { try replaceLink(at: active, with: directory.path) }
            if oldApp != active.path { try replaceLink(at: appSupport, with: active.path) }
            if oldJSON != active.path + "/.claude.json" {
                try replaceLink(at: claudeJSON, with: active.path + "/.claude.json")
            }
            try writeMarker(id)
            _ = try validateLinks()
        } catch {
            if let oldApp { try? replaceLink(at: appSupport, with: oldApp) }
            else { unlink(appSupport.path) }
            if let oldJSON { try? replaceLink(at: claudeJSON, with: oldJSON) }
            else { unlink(claudeJSON.path) }
            if oldActive == nil { unlink(active.path) }
            throw error
        }
    }

    /// Caller retains the lock until engine launch succeeds or fails.
    func switchProfile(to id: String) throws {
        guard lockFD >= 0 else { throw ProfileStoreError.system("Не получена блокировка профилей") }
        let oldId = try validateLinks()
        let directory = try profileURL(id)
        if oldId == id { return }
        try replaceLink(at: active, with: directory.path)
        do {
            try writeMarker(id)
            _ = try validateLinks()
        } catch {
            try? replaceLink(at: active, with: profiles.appendingPathComponent(oldId).path)
            try? writeMarker(oldId)
            throw error
        }
    }

    private func writeMarker(_ id: String) throws {
        try (id + "\n").write(to: marker, atomically: true, encoding: .utf8)
    }
}
