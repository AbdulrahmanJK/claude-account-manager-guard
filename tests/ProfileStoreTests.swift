import Foundation

@main
struct ProfileStoreTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-guard-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let base = root.appendingPathComponent("guard")
        let app = root.appendingPathComponent("Application Support/Claude")
        let json = root.appendingPathComponent(".claude.json")
        let fm = FileManager.default
        try fm.createDirectory(at: base.appendingPathComponent("profiles/work"), withIntermediateDirectories: true)
        try fm.createDirectory(at: base.appendingPathComponent("profiles/personal"), withIntermediateDirectories: true)
        try fm.createDirectory(at: app.deletingLastPathComponent(), withIntermediateDirectories: true)
        for id in ["work", "personal"] {
            try "{}".write(to: base.appendingPathComponent("profiles/\(id)/.claude.json"), atomically: true, encoding: .utf8)
        }
        let work = base.appendingPathComponent("profiles/work")
        let personal = base.appendingPathComponent("profiles/personal")
        try fm.createSymbolicLink(at: app, withDestinationURL: work)
        try fm.createSymbolicLink(at: json, withDestinationURL: work.appendingPathComponent(".claude.json"))
        let store = ProfileStore(base: base, appSupport: app, claudeJSON: json)
        try store.prepareLinks()
        assert((try? store.validateLinks()) == "work")
        try store.acquireLock()
        let other = ProfileStore(base: base, appSupport: app, claudeJSON: json)
        do { try other.acquireLock(); assertionFailure("second lock succeeded") }
        catch ProfileStoreError.busy { }
        try store.switchProfile(to: "personal")
        assert((try? store.validateLinks()) == "personal")
        assert(app.resolvingSymlinksInPath().path == personal.path)
        assert(json.resolvingSymlinksInPath().path == personal.appendingPathComponent(".claude.json").path)
        do { try store.switchProfile(to: "../work"); assertionFailure("unsafe ID accepted") }
        catch ProfileStoreError.invalidProfile { }
        assert((try? store.validateLinks()) == "personal")
        try store.switchProfile(to: "work")
        try fm.removeItem(at: personal.appendingPathComponent(".claude.json"))
        do { try store.switchProfile(to: "personal"); assertionFailure("missing data accepted") }
        catch ProfileStoreError.missingProfile { }
        assert((try? store.validateLinks()) == "work")
        try "{}".write(to: personal.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        try fm.removeItem(at: store.marker)
        try fm.createDirectory(at: store.marker, withIntermediateDirectories: false)
        do { try store.switchProfile(to: "personal"); assertionFailure("marker failure ignored") }
        catch { }
        assert((try? store.validateLinks()) == "work")
        store.releaseLock()

        let splitRoot = root.appendingPathComponent("split")
        let splitBase = splitRoot.appendingPathComponent("guard")
        let splitApp = splitRoot.appendingPathComponent("Library/Claude")
        let splitJSON = splitRoot.appendingPathComponent(".claude.json")
        try fm.createDirectory(at: splitBase.appendingPathComponent("profiles/work"), withIntermediateDirectories: true)
        try fm.createDirectory(at: splitBase.appendingPathComponent("profiles/personal"), withIntermediateDirectories: true)
        try fm.createDirectory(at: splitApp.deletingLastPathComponent(), withIntermediateDirectories: true)
        for id in ["work", "personal"] {
            try "{}".write(to: splitBase.appendingPathComponent("profiles/\(id)/.claude.json"), atomically: true, encoding: .utf8)
        }
        try fm.createSymbolicLink(at: splitApp, withDestinationURL: splitBase.appendingPathComponent("profiles/work"))
        try fm.createSymbolicLink(at: splitJSON, withDestinationURL: splitBase.appendingPathComponent("profiles/personal/.claude.json"))
        let splitStore = ProfileStore(base: splitBase, appSupport: splitApp, claudeJSON: splitJSON)
        do { try splitStore.prepareLinks(); assertionFailure("split links accepted") }
        catch ProfileStoreError.unexpectedPath { }
        assert(!fm.fileExists(atPath: splitStore.active.path))
        print("ProfileStore: migration, switching, rollback and split-link checks passed")
    }
}
