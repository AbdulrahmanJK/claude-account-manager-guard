import Foundation

@main
struct ProfileCtl {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        let environment = ProcessInfo.processInfo.environment
        let home = URL(fileURLWithPath: environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path)
        let base = URL(fileURLWithPath: environment["CLAUDE_GUARD_HOME"] ?? home.appendingPathComponent(".claude-vpn-guard").path)
        let store = ProfileStore(base: base,
                                 appSupport: home.appendingPathComponent("Library/Application Support/Claude"),
                                 claudeJSON: home.appendingPathComponent(".claude.json"))
        do {
            switch args.first {
            case "prepare":
                try store.prepareLinks(preferredId: args.count > 1 ? args[1] : "work")
                print("Активный профиль: \(try store.validateLinks())")
            case "status":
                print(try store.validateLinks())
            case "switch":
                guard args.count == 2 else { throw ProfileStoreError.system("Использование: ProfileCtl switch <id>") }
                try store.acquireLock()
                defer { store.releaseLock() }
                try store.switchProfile(to: args[1])
                print(try store.validateLinks())
            default:
                throw ProfileStoreError.system("Использование: ProfileCtl prepare [id] | status | switch <id>")
            }
        } catch {
            fputs("Ошибка профиля: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
