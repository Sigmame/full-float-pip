import Cocoa

/// A visual fixture displays the production strip in a regular window so UI
/// inspection can capture a nonactivating accessory panel independently.
@main
struct FloatingPlayerPreview {
    static var player: FloatWindow!
    static var preview: NSWindow!
    static func checkMaximize() {
        FloatWindow.persistSizePreset(.mini)
        for pinned in [false, true] {
            let window = FloatWindow(videoWidth: 640, videoHeight: 360, videoTitle: "Maximize integration check")
            window.show()
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            window.isPinned = pinned
            let before = window.frame
            let visible = window.screen!.visibleFrame
            guard let button = NSApplication.shared.windows.flatMap({
                $0.contentView?.subviews.compactMap({ $0 as? NSButton }) ?? []
            }).first(where: {
                $0.action == NSSelectorFromString("toggleMaximize") && ($0.target as AnyObject?) === window
            }) else { fatalError("Production maximize button missing") }
            button.performClick(nil)
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            let expanded = window.frame
            precondition(expanded.width > before.width + 100, "Button must visibly enlarge the player")
            precondition(window.isUserExpanded)
            precondition(visible.contains(expanded), "Expanded video must stay on screen, including when pinned")
            precondition(abs(expanded.width / expanded.height - 16 / 9) < 0.001)
            window.applyCodingSafeMode(preferred: NSRect(x: visible.minX, y: visible.minY, width: 380, height: 214))
            window.placeAwayFromCode()
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
            precondition(window.frame == expanded, "Automatic placement must not overwrite explicit maximize")
            button.performClick(nil)
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            precondition(!window.isUserExpanded)
            precondition(abs(window.frame.width - before.width) < 1 && abs(window.frame.height - before.height) < 1,
                         "Second click must restore the previous size")
            if pinned { precondition(window.frame.origin == before.origin, "Pinned restore must recover its anchor") }
            window.close()
        }
        print("Native maximize button passed: click, expansion, aspect ratio, obstacle immunity, restore, and pinned windows")
    }
    static func checkPresets() {
        var players: [FloatWindow] = []
        for preset in [FloatWindow.SizePreset.mini, .standard, .wide] {
            FloatWindow.persistSizePreset(preset)
            let window = FloatWindow(videoWidth: 640, videoHeight: 360, videoTitle: "Preset integration check")
            players.append(window)
            window.show()
            let expected = preset.fittedSize(aspectRatio: 640 / 360,
                screen: window.screen!.visibleFrame.size, minimumWidth: 380, maximumWidth: 1920,
                stripHeight: VibePlacer.stripHeight, stripGap: VibePlacer.stripGap)
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            precondition(abs(window.frame.width - expected.width) < 1, "Open must restore \(preset)")
            window.applyCodingSafeMode(preferred: window.frame)
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            precondition(abs(window.frame.width - expected.width) < 1, "Obstacle placement must preserve \(preset)")
            window.exitCodingSafeModeIfClear()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            precondition(abs(window.frame.width - expected.width) < 1, "Leaving obstacle mode must preserve \(preset)")
            window.applySizePreset(.mini)
            let changedWidth = window.frame.width
            window.applyCodingSafeMode(preferred: window.frame)
            window.exitCodingSafeModeIfClear()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            precondition(abs(window.frame.width - changedWidth) < 1, "A new selection must replace old restore geometry")
            precondition(FloatWindow.savedSizePreset == .mini)
            window.close()
        }
        let reopened = FloatWindow(videoWidth: 640, videoHeight: 360, videoTitle: "Reopen check")
        players.append(reopened)
        reopened.show()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        precondition(abs(reopened.frame.width - 480) < 1, "Reopen must remember the last selected preset")
        reopened.close()
        print("Native preset integration passed: restore on open, obstacle placement, changed selection, and reopen")
    }

    static func main() {
        UserDefaults.standard.set(true, forKey: "FloatVideoKeepControlsVisible")
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        if CommandLine.arguments.contains("--check-maximize") {
            checkMaximize()
            return
        }
        if CommandLine.arguments.contains("--check-presets") {
            checkPresets()
            return
        }
        player = FloatWindow(videoWidth: 380, videoHeight: 214,
                             videoTitle: "Chiến binh của Thiên Chúa — Samson")
        player.isPlaying = false
        player.show()
        guard let strip = app.windows.first(where: { $0 !== player && $0.frame.height == FloatingPlayerLayout.height }),
              let controls = strip.contentView else { fatalError("Production strip not mounted") }
        strip.contentView = NSView()
        strip.orderOut(nil)
        player.orderOut(nil)
        preview = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: FloatingPlayerLayout.height),
                           styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        preview.title = "VibeFloat — Kiểm tra thanh điều khiển"
        preview.minSize = NSSize(width: 280, height: FloatingPlayerLayout.height + 28)
        preview.contentView = controls
        // Example clock content only; live playback is verified separately.
        for field in controls.subviews.compactMap({ $0 as? NSTextField }) where field.stringValue == "--:--" {
            field.stringValue = "2:05 / 1:43:34"
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification,
            object: preview, queue: .main) { _ in
                var frame = player.frame
                frame.size.width = controls.bounds.width
                player.setFrame(frame, display: false)
                strip.orderOut(nil)
                player.orderOut(nil)
            }
        preview.appearance = NSAppearance(named: .darkAqua)
        preview.center()
        preview.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        app.run()
    }
}
