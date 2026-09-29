import Cocoa

@main
struct DaemonMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        ClaudeVPNGuard.shared.start()
        RunLoop.main.run()
    }
}
