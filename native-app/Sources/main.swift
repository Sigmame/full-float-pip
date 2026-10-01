import Cocoa

// MARK: - Application Entry Point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

// Chrome's native-messaging host stays an accessory (no Dock icon). Standalone launches
// switch to a regular app in AppDelegate.startStandalone().
app.setActivationPolicy(.accessory)
app.run()
