import Foundation

@main
struct GuardControlTests {
    static func main() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let control = GuardControl(base: base)
        precondition(control.load().enabled)
        let disabled = try control.setEnabled(false)
        precondition(!GuardControl(base: base).load().enabled)
        precondition(control.load() == disabled)
        let enabled = try control.setEnabled(true)
        precondition(enabled.enabled && enabled.revision != disabled.revision)
        let permissions = try FileManager.default.attributesOfItem(atPath: control.url.path)[.posixPermissions] as! NSNumber
        precondition(permissions.intValue == 0o600)
        try Data("invalid".utf8).write(to: control.url)
        precondition(control.load().enabled)
        try FileManager.default.removeItem(at: control.url)
        precondition(control.load().enabled)
        let missing = GuardControl(base: base.appendingPathComponent("missing"))
        do {
            try missing.setEnabled(false)
            preconditionFailure("A failed save must not silently disable protection")
        } catch { precondition(missing.load().enabled) }
        print("GuardControl: defaults, persistence, enable/disable revisions, permissions and failed writes passed")
    }
}
