import Cocoa
import Carbon.HIToolbox
import MediaPlayer
import ApplicationServices

// MARK: - Placement
//
// Keeps the floating player in the largest open pocket that does not cover
// vibe-coding or AI windows — especially the frontmost editor and the focused
// text input. When no clear pocket exists, the player shrinks, goes ghost, and
// parks in the least-bad corner instead of sitting on active code.

struct WeightedObstacle {
    let frame: NSRect
    let weight: CGFloat
    let pad: CGFloat
}

enum VibePlacer {
    static let margin: CGFloat = 14
    static let keepOut: CGFloat = 18
    static let stripGap: CGFloat = 6
    static let stripHeight: CGFloat = FloatingPlayerLayout.height

    struct Decision {
        let frame: NSRect
        let overlap: CGFloat
        let footprintArea: CGFloat

        var isClear: Bool {
            overlap < max(footprintArea * 0.06, 500)
        }
    }

    static func stripFrame(video: NSRect, screen: NSRect) -> NSRect {
        let height = stripHeight
        var y = video.minY - height - stripGap
        if y < screen.minY + 4 {
            let above = video.maxY + stripGap
            if above + height <= screen.maxY - 4 {
                y = above
            } else {
                y = max(screen.minY + 4, min(y, screen.maxY - height - 4))
            }
        }
        var x = video.minX
        if x + video.width > screen.maxX - 4 { x = screen.maxX - video.width - 4 }
        if x < screen.minX + 4 { x = screen.minX + 4 }
        return NSRect(x: x, y: y, width: video.width, height: height)
    }

    static func footprint(video: NSRect, screen: NSRect) -> NSRect {
        video.union(stripFrame(video: video, screen: screen))
    }

    /// Best frame for an arbitrary size (maximize / initial place).
    static func bestFrame(
        size: NSSize,
        screen: NSRect,
        obstacles: [WeightedObstacle]
    ) -> Decision? {
        decide(current: NSRect(origin: .zero, size: size), screen: screen, obstacles: obstacles, force: true)
    }

    /// Returns a new video frame decision, or nil when the current spot is already clear and stable.
    static func chooseVideoFrame(
        current: NSRect,
        screen: NSRect,
        obstacles: [WeightedObstacle]
    ) -> Decision? {
        decide(current: current, screen: screen, obstacles: obstacles, force: false)
    }

    private static func decide(
        current: NSRect,
        screen: NSRect,
        obstacles: [WeightedObstacle],
        force: Bool
    ) -> Decision? {
        let onScreen = obstacles.filter { $0.frame.intersects(screen.insetBy(dx: -12, dy: -12)) }
        guard !onScreen.isEmpty else { return nil }

        let size = current.size
        guard screen.width >= size.width + margin * 2,
              screen.height >= size.height + stripHeight + margin else { return nil }

        let plain = onScreen.map(\.frame)
        let centroid = clusterCentroid(plain)
        let spots = candidates(screen: screen, size: size, obstacles: plain)
        guard !spots.isEmpty else { return nil }

        let ranked = spots.map { origin -> (NSRect, CGFloat, CGFloat) in
            let video = NSRect(origin: origin, size: size)
            let foot = footprint(video: video, screen: screen)
            let overlap = totalOverlap(foot, onScreen)
            let value = score(video: video, screen: screen, obstacles: onScreen, centroid: centroid, overlap: overlap)
            return (video, value, overlap)
        }.sorted { $0.1 > $1.1 }

        guard let best = ranked.first else { return nil }
        let footArea = area(footprint(video: best.0, screen: screen))
        let decision = Decision(frame: best.0, overlap: best.2, footprintArea: footArea)

        if force { return decision }

        let currentOverlap = totalOverlap(footprint(video: current, screen: screen), onScreen)
        let currentScore = score(
            video: current,
            screen: screen,
            obstacles: onScreen,
            centroid: centroid,
            overlap: currentOverlap
        )

        if currentOverlap < max(footArea * 0.06, 500) {
            let dx = abs(best.0.minX - current.minX)
            let dy = abs(best.0.minY - current.minY)
            if dx < 24 && dy < 24 { return nil }
            if best.1 - currentScore < 220 { return nil }
        }
        if abs(best.0.minX - current.minX) < 8 && abs(best.0.minY - current.minY) < 8 {
            return nil
        }
        return decision
    }

    private static func candidates(screen s: NSRect, size: NSSize, obstacles: [NSRect]) -> [NSPoint] {
        let w = size.width
        let h = size.height
        let m = margin
        var pts: [NSPoint] = [
            NSPoint(x: s.maxX - w - m, y: s.maxY - h - m),
            NSPoint(x: s.minX + m, y: s.maxY - h - m),
            NSPoint(x: s.maxX - w - m, y: s.minY + m + stripHeight + stripGap),
            NSPoint(x: s.minX + m, y: s.minY + m + stripHeight + stripGap),
            NSPoint(x: s.midX - w / 2, y: s.maxY - h - m),
            NSPoint(x: s.midX - w / 2, y: s.minY + m + stripHeight + stripGap),
        ]
        for o in obstacles {
            pts.append(NSPoint(x: o.maxX + keepOut, y: s.maxY - h - m))
            pts.append(NSPoint(x: o.minX - w - keepOut, y: s.maxY - h - m))
            pts.append(NSPoint(x: s.maxX - w - m, y: o.maxY + keepOut))
            pts.append(NSPoint(x: s.minX + m, y: o.maxY + keepOut))
            pts.append(NSPoint(x: s.maxX - w - m, y: o.minY - h - stripHeight - keepOut))
            pts.append(NSPoint(x: s.minX + m, y: o.minY - h - stripHeight - keepOut))
            pts.append(NSPoint(x: o.midX - w / 2, y: o.maxY + keepOut))
            pts.append(NSPoint(x: o.midX - w / 2, y: o.minY - h - stripHeight - keepOut))
        }
        let sorted = obstacles.sorted { $0.minX < $1.minX }
        var cursor = s.minX + m
        for o in sorted {
            let gapEnd = o.minX - keepOut
            if gapEnd - cursor >= w {
                pts.append(NSPoint(x: cursor, y: s.maxY - h - m))
                pts.append(NSPoint(x: gapEnd - w, y: s.maxY - h - m))
            }
            cursor = max(cursor, o.maxX + keepOut)
        }
        if s.maxX - m - cursor >= w {
            pts.append(NSPoint(x: cursor, y: s.maxY - h - m))
        }
        return pts.map { clamp($0, screen: s, size: size) }
    }

    private static func clamp(_ origin: NSPoint, screen s: NSRect, size: NSSize) -> NSPoint {
        let maxX = s.maxX - size.width - 4
        let minX = s.minX + 4
        let maxY = s.maxY - size.height - 4
        let minY = s.minY + 4
        return NSPoint(
            x: min(max(origin.x, minX), max(minX, maxX)),
            y: min(max(origin.y, minY), max(minY, maxY))
        )
    }

    private static func score(
        video: NSRect,
        screen: NSRect,
        obstacles: [WeightedObstacle],
        centroid: NSPoint,
        overlap: CGFloat
    ) -> CGFloat {
        if overlap > 1 { return -overlap }
        var value: CGFloat = 1_000_000
        let foot = footprint(video: video, screen: screen)
        let nearest = obstacles.map { gap($0.frame, foot) }.min() ?? 200
        value += min(nearest, 280)
        let wantRight = centroid.x < screen.midX
        let onRight = video.midX >= screen.midX
        if obstacles.count == 1 || abs(centroid.x - screen.midX) > screen.width * 0.08 {
            if wantRight == onRight { value += 520 }
        }
        // Prefer upper corners so the player stays above the typical editor caret band.
        value += ((video.maxY - screen.minY) / max(screen.height, 1)) * 220
        return value
    }

    private static func clusterCentroid(_ obstacles: [NSRect]) -> NSPoint {
        let areaSum = obstacles.reduce(CGFloat(0)) { $0 + max($1.width * $1.height, 1) }
        guard areaSum > 0 else { return .zero }
        let x = obstacles.reduce(CGFloat(0)) { $0 + $1.midX * max($1.width * $1.height, 1) } / areaSum
        let y = obstacles.reduce(CGFloat(0)) { $0 + $1.midY * max($1.width * $1.height, 1) } / areaSum
        return NSPoint(x: x, y: y)
    }

    private static func totalOverlap(_ footprint: NSRect, _ obstacles: [WeightedObstacle]) -> CGFloat {
        obstacles.reduce(CGFloat(0)) { sum, obstacle in
            let padded = obstacle.frame.insetBy(dx: -obstacle.pad, dy: -obstacle.pad)
            return sum + area(footprint.intersection(padded)) * obstacle.weight
        }
    }

    private static func area(_ rect: NSRect) -> CGFloat {
        if rect.isNull || rect.isEmpty { return 0 }
        return max(0, rect.width) * max(0, rect.height)
    }

    private static func gap(_ a: NSRect, _ b: NSRect) -> CGFloat {
        let dx = max(0, max(a.minX, b.minX) - min(a.maxX, b.maxX))
        let dy = max(0, max(a.minY, b.minY) - min(a.maxY, b.maxY))
        return hypot(dx, dy)
    }
}

// MARK: - Dock controller

final class VibeDock {
    private weak var window: FloatWindow?
    private var timer: Timer?
    private var userHoldUntil: Date?
    private var userHoldCoarse: String?
    private var appCache: [Int32: (name: String, bundle: String)] = [:]
    private let userHoldSeconds: TimeInterval = 75

    func attach(_ window: FloatWindow) {
        self.window = window
        userHoldUntil = nil
        userHoldCoarse = nil
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.7, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        window = nil
    }

    /// Synchronous first placement before the window is shown over an IDE.
    func placeImmediately(_ window: FloatWindow) {
        self.window = window
        applyPlacement(to: window, animated: false, force: true)
    }

    func noteUserDidPlace() {
        let obstacles = scanWeightedObstacles()
        userHoldCoarse = coarseSignature(obstacles)
        userHoldUntil = Date().addingTimeInterval(userHoldSeconds)
    }

    private func tick() {
        guard let window = window, window.isWindowVisible else { return }
        if window.isPinned || window.autoDockPaused || window.isResizeActive || window.isUserExpanded { return }
        let obstacles = scanWeightedObstacles()
        if shouldHold(against: obstacles) { return }
        applyPlacement(to: window, animated: true, force: false, scannedObstacles: obstacles)
    }

    private func applyPlacement(to window: FloatWindow, animated: Bool, force: Bool,
                                scannedObstacles: [WeightedObstacle]? = nil) {
        guard !window.isPinned, !window.isUserExpanded else { return }
        guard let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let obstacles = (scannedObstacles ?? scanWeightedObstacles()).filter {
            $0.frame.intersects(visible.insetBy(dx: -16, dy: -16))
        }
        if obstacles.isEmpty { return }

        let decision: VibePlacer.Decision?
        if force {
            decision = VibePlacer.bestFrame(size: window.frame.size, screen: visible, obstacles: obstacles)
        } else {
            decision = VibePlacer.chooseVideoFrame(current: window.frame, screen: visible, obstacles: obstacles)
        }
        guard let decision = decision else { return }

        if decision.isClear {
            window.applyDock(videoFrame: decision.frame, animated: animated)
            window.exitCodingSafeModeIfClear()
        } else {
            window.applyCodingSafeMode(preferred: decision.frame)
        }
    }

    private func shouldHold(against obstacles: [WeightedObstacle]) -> Bool {
        guard let until = userHoldUntil, Date() < until else {
            userHoldUntil = nil
            userHoldCoarse = nil
            return false
        }
        let coarse = coarseSignature(obstacles)
        if let old = userHoldCoarse, isMajorLayoutChange(from: old, to: coarse) {
            userHoldUntil = nil
            userHoldCoarse = nil
            return false
        }
        return true
    }

    private func coarseSignature(_ obstacles: [WeightedObstacle]) -> String {
        let count = obstacles.count
        let areaBucket = Int(obstacles.reduce(CGFloat(0)) { $0 + $1.frame.width * $1.frame.height } / 80_000)
        let heavy = obstacles.filter { $0.weight >= 3 }.map { o in
            "\(Int(o.frame.minX / 80)),\(Int(o.frame.minY / 80)),\(Int(o.frame.width / 80))"
        }.sorted().joined(separator: ";")
        return "\(count)|\(areaBucket)|\(heavy)"
    }

    private func isMajorLayoutChange(from old: String, to new: String) -> Bool {
        if old == new { return false }
        let oldParts = old.split(separator: "|")
        let newParts = new.split(separator: "|")
        guard oldParts.count >= 2, newParts.count >= 2,
              let oldCount = Int(oldParts[0]), let newCount = Int(newParts[0]),
              let oldArea = Int(oldParts[1]), let newArea = Int(newParts[1]) else {
            return true
        }
        if abs(oldCount - newCount) >= 1 { return true }
        if abs(oldArea - newArea) >= 2 { return true }
        // Frontmost cluster jumped to another region of the screen.
        if oldParts.count >= 3, newParts.count >= 3, oldParts[2] != newParts[2] {
            return true
        }
        return false
    }

    func liveObstacles(on screen: NSRect) -> [WeightedObstacle] {
        scanWeightedObstacles().filter { $0.frame.intersects(screen.insetBy(dx: -16, dy: -16)) }
    }

    private func scanWeightedObstacles() -> [WeightedObstacle] {
        guard let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var frames: [WeightedObstacle] = []
        for info in infoList {
            let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            if pid == selfPID || pid == 0 { continue }
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            if layer != 0 { continue }
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            if alpha < 0.05 { continue }
            guard let bounds = cgRect(info[kCGWindowBounds as String]) else { continue }
            if bounds.width < 260 || bounds.height < 150 { continue }
            let title = info[kCGWindowName as String] as? String ?? ""
            let identity = appIdentity(pid: pid, fallback: info[kCGWindowOwnerName as String] as? String ?? "")
            if !Self.isVibeWindow(appName: identity.name, bundleID: identity.bundle, title: title) {
                continue
            }
            let frame = appKitRect(fromQuartz: bounds)
            if frame.width < 260 || frame.height < 150 { continue }
            let isFront = frontPID != nil && pid == frontPID
            frames.append(WeightedObstacle(
                frame: frame,
                weight: isFront ? 4.5 : 1.0,
                pad: isFront ? 28 : 18
            ))
        }

        // Hard keep-out around the focused typing / code-input region when Accessibility is granted.
        if let input = Self.focusedTypingRect() {
            let padded = input.insetBy(dx: -48, dy: -72)
            frames.append(WeightedObstacle(frame: padded, weight: 9.0, pad: 20))
        }
        return frames
    }

    /// AX focused text field / editor caret band. Returns nil without Accessibility permission.
    static func focusedTypingRect() -> NSRect? {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        guard AXIsProcessTrustedWithOptions(opts) else { return nil }

        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef else { return nil }
        let element = focused as! AXUIElement

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = (roleRef as? String) ?? ""
        let typingRoles: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String,
            "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField",
            "AXWebArea", // browser / Electron editors often report this while typing
        ]
        // Always treat the focused element of a frontmost vibe app as an input keep-out,
        // even when the role is a custom editor (Cursor/VS Code).
        let frontIsVibe: Bool = {
            guard let front = NSWorkspace.shared.frontmostApplication else { return false }
            return isVibeWindow(
                appName: front.localizedName ?? "",
                bundleID: front.bundleIdentifier ?? "",
                title: ""
            )
        }()
        if !typingRoles.contains(role) && !frontIsVibe { return nil }

        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posVal = posRef, let sizeVal = sizeRef else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posVal as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeVal as! AXValue, .cgSize, &size),
              size.width > 20, size.height > 12 else { return nil }

        // AX uses top-left Quartz coordinates (origin = top-left of main display).
        let quartz = CGRect(origin: position, size: size)
        var appKit = appKitRectStatic(fromQuartz: quartz)

        // Use the screen that actually contains the focused element — not
        // NSScreen.main / primary only — so caret keep-out works on monitor 2+.
        let screen = screenContaining(appKitRect: appKit) ?? NSScreen.main
        if let screen = screen {
            let screenArea = screen.frame.width * screen.frame.height
            let focusedArea = appKit.width * appKit.height
            // Electron IDEs often report the whole window as AXWebArea — only keep a
            // band around the caret region when the focused rect is huge.
            if focusedArea > screenArea * 0.55 {
                let bandHeight = min(appKit.height * 0.55, screen.frame.height * 0.5)
                let bandY = appKit.midY - bandHeight / 2
                appKit = NSRect(
                    x: appKit.minX + appKit.width * 0.08,
                    y: bandY,
                    width: appKit.width * 0.84,
                    height: bandHeight
                )
            }
        }
        return appKit
    }

    /// AX / CGWindowList top-left global → AppKit bottom-left global.
    /// Y flip is always against the primary display's maxY so secondary
    /// monitors (negative X, Y above/below primary) convert correctly.
    private static func appKitRectStatic(fromQuartz bounds: CGRect) -> NSRect {
        let primary = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main
        let primaryMaxY = primary?.frame.maxY ?? bounds.height
        return NSRect(
            x: bounds.origin.x,
            y: primaryMaxY - bounds.origin.y - bounds.height,
            width: bounds.width,
            height: bounds.height
        )
    }

    private static func screenContaining(appKitRect: NSRect) -> NSScreen? {
        let mid = NSPoint(x: appKitRect.midX, y: appKitRect.midY)
        if let hit = NSScreen.screens.first(where: { $0.frame.contains(mid) }) {
            return hit
        }
        return NSScreen.screens
            .map { screen -> (NSScreen, CGFloat) in
                let inter = screen.frame.intersection(appKitRect)
                let area = max(0, inter.width) * max(0, inter.height)
                return (screen, area)
            }
            .filter { $0.1 > 0 }
            .max(by: { $0.1 < $1.1 })?
            .0
    }

    private func appIdentity(pid: Int32, fallback: String) -> (name: String, bundle: String) {
        if let cached = appCache[pid] { return cached }
        let app = NSRunningApplication(processIdentifier: pid)
        let identity = (app?.localizedName ?? fallback, app?.bundleIdentifier ?? "")
        appCache[pid] = identity
        return identity
    }

    private func cgRect(_ value: Any?) -> CGRect? {
        if let dict = value as? NSDictionary {
            return CGRect(dictionaryRepresentation: dict)
        }
        return nil
    }

    private func appKitRect(fromQuartz bounds: CGRect) -> NSRect {
        Self.appKitRectStatic(fromQuartz: bounds)
    }

    static func isVibeWindow(appName: String, bundleID: String, title: String) -> Bool {
        let app = appName.lowercased()
        let bundle = bundleID.lowercased()
        let titled = title.lowercased()
        let exact: Set<String> = [
            // IDEs / editors
            "cursor", "code", "visual studio code", "code - insiders", "windsurf", "zed",
            "trae", "void", "kiro", "qoder", "antigravity", "pearai", "xcode", "nova",
            "sublime text", "intellij idea", "pycharm", "webstorm", "goland",
            "android studio", "clion", "phpstorm", "rider", "rubymine", "datagrip",
            // Agent desktops / orchestrators
            "orca", "onorca", "termic", "factory", "devin", "replit", "bolt",
            // AI chat / coding surfaces
            "claude", "chatgpt", "codex", "gemini", "openai", "chatgpt atlas",
            "perplexity", "dia", "comet", "lm studio", "ollama", "jan",
            // Terminal coding agents (GUI wrappers / branded windows)
            "pi", "omp", "oh my pi", "oh-my-pi", "opencode", "aider", "amp",
            "roo code", "continue", "cline", "auggie", "goose", "hermes",
            "kilocode", "kilo code", "droid", "openclaude", "mistral vibe",
            "qwen code", "rovo dev", "autohand", "codebuff",
            // Terminals
            "terminal", "iterm2", "iterm", "warp", "ghostty",
            "kitty", "alacritty", "wezterm", "hyper", "tabby"
        ]
        if exact.contains(app) { return true }
        if app.hasPrefix("cursor") || app.hasPrefix("windsurf") || app.hasPrefix("claude")
            || app.hasPrefix("orca") || app.hasPrefix("antigravity") {
            return true
        }
        let bundleHints = [
            "todesktop", "vscode", "visualstudio.code", "windsurf", "exafunction",
            "zed.zed", "warp", "iterm", "ghostty", "apple.terminal", "dt.xcode",
            "sublime", "panic.nova", "jetbrains", "anthropic", "openai", "lmstudio",
            "ollama", "wezterm", "alacritty", "kitty", "stably", "onorca", "orca",
            "antigravity", "google.antigravity", "factory", "termic", "opencode",
            "continue", "cline", "kilocode", "oh-my-pi", "ohmypi", "mariozechner.pi"
        ]
        if bundleHints.contains(where: { bundle.contains($0) }) { return true }

        // Terminal / IDE tabs often expose the agent CLI in the window title.
        let terminals = [
            "terminal", "iterm", "warp", "ghostty", "kitty", "alacritty", "wezterm",
            "hyper", "tabby", "orca", "termic"
        ]
        let isTerminalish = terminals.contains { app.contains($0) || bundle.contains($0) }
        if isTerminalish {
            let agentHints = [
                " pi ", "pi ", " omp", "omp ", "oh-my-pi", "oh my pi", "ohmypi",
                "claude", "codex", "opencode", "aider", "goose", "hermes",
                "auggie", "cline", "kilocode", "droid", "factory", "antigravity",
                "cursor-agent", "amp ", "roo", "continue"
            ]
            let padded = " \(titled) "
            if agentHints.contains(where: { padded.contains($0) }) { return true }
        }

        let browsers = ["chrome", "safari", "firefox", "arc", "edge", "brave", "orion", "vivaldi", "opera", "dia", "comet"]
        let isBrowser = browsers.contains { app.contains($0) || bundle.contains($0) }
        guard isBrowser else { return false }
        let hints = [
            "claude", "chatgpt", "openai", "gemini", "copilot", "perplexity", "phind",
            "cursor", "windsurf", "deepseek", "grok", "notebooklm", "aistudio", "v0",
            "bolt.new", "lovable", "replit", "poe.com", "qwen", "kimi", "claude.ai",
            "chat.openai", "gemini.google", "codex", "antigravity", "onorca", "orca",
            "oh-my-pi", "ohmypi", "pi coding", "opencode", "aistudio.google"
        ]
        return hints.contains { titled.contains($0) }
    }
}

// MARK: - Hotkeys that do not type into the editor

final class VibeHotkeys {
    private var hotKeyRefs: [EventHotKeyRef?] = []
    private var handler: EventHandlerRef?
    private var actions: [UInt32: () -> Void] = [:]
    var onRegisterFailed: ((String) -> Void)?

    func install(playPause: @escaping () -> Void,
                 ghost: @escaping () -> Void,
                 boss: @escaping () -> Void,
                 duck: @escaping () -> Void,
                 back: @escaping () -> Void,
                 forward: @escaping () -> Void,
                 volumeUp: @escaping () -> Void,
                 volumeDown: @escaping () -> Void,
                 sizeUp: @escaping () -> Void = {},
                 sizeDown: @escaping () -> Void = {},
                 prevEpisode: @escaping () -> Void = {},
                 nextEpisode: @escaping () -> Void = {},
                 sizeMini: @escaping () -> Void = {},
                 sizeStandard: @escaping () -> Void = {},
                 sizeWide: @escaping () -> Void = {}) {
        actions = [
            1: playPause,
            2: ghost,
            3: boss,
            4: duck,
            5: back,
            6: forward,
            7: volumeUp,
            8: volumeDown,
            9: sizeUp,
            10: sizeDown,
            11: prevEpisode,
            12: nextEpisode,
            13: sizeMini,
            14: sizeStandard,
            15: sizeWide,
        ]
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let event = event, let userData = userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            let size = MemoryLayout<EventHotKeyID>.size
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                size,
                nil,
                &hotKeyID
            )
            if status == noErr {
                let owner = Unmanaged<VibeHotkeys>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    owner.actions[hotKeyID.id]?()
                }
            }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)

        let cmdShift = UInt32(cmdKey | shiftKey)
        let ctrlOpt = UInt32(controlKey | optionKey)
        register(id: 1, key: UInt32(kVK_Space), mods: cmdShift, label: "⌘⇧Space")
        register(id: 2, key: UInt32(kVK_ANSI_G), mods: cmdShift, label: "⌘⇧G")
        register(id: 3, key: UInt32(kVK_ANSI_B), mods: cmdShift, label: "⌘⇧B")
        register(id: 4, key: UInt32(kVK_ANSI_D), mods: cmdShift, label: "⌘⇧D")
        register(id: 5, key: UInt32(kVK_LeftArrow), mods: ctrlOpt, label: "⌃⌥←")
        register(id: 6, key: UInt32(kVK_RightArrow), mods: ctrlOpt, label: "⌃⌥→")
        register(id: 7, key: UInt32(kVK_UpArrow), mods: ctrlOpt, label: "⌃⌥↑")
        register(id: 8, key: UInt32(kVK_DownArrow), mods: ctrlOpt, label: "⌃⌥↓")
        register(id: 9, key: UInt32(kVK_ANSI_Equal), mods: ctrlOpt, label: "⌃⌥=")
        register(id: 10, key: UInt32(kVK_ANSI_Minus), mods: ctrlOpt, label: "⌃⌥-")
        register(id: 11, key: UInt32(kVK_ANSI_LeftBracket), mods: ctrlOpt, label: "⌃⌥[")
        register(id: 12, key: UInt32(kVK_ANSI_RightBracket), mods: ctrlOpt, label: "⌃⌥]")
        register(id: 13, key: UInt32(kVK_ANSI_1), mods: ctrlOpt, label: "⌃⌥1")
        register(id: 14, key: UInt32(kVK_ANSI_2), mods: ctrlOpt, label: "⌃⌥2")
        register(id: 15, key: UInt32(kVK_ANSI_3), mods: ctrlOpt, label: "⌃⌥3")
    }

    /// Releases every registered hotkey and tears the event handler down. Called
    /// when the floating window closes: these combinations (⌘⇧G, ⌘⇧B, ⌘⇧D, …)
    /// belong to whatever app is frontmost — Xcode's "Find Previous", Chrome's
    /// find bar — and must not stay swallowed while no player is on screen.
    func uninstall() {
        for ref in hotKeyRefs {
            if let ref = ref { UnregisterEventHotKey(ref) }
        }
        hotKeyRefs.removeAll()
        if let handler = handler {
            RemoveEventHandler(handler)
            self.handler = nil
        }
        actions.removeAll()
    }

    var isInstalled: Bool { !hotKeyRefs.isEmpty }

    private func register(id: UInt32, key: UInt32, mods: UInt32, label: String) {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: fourCC("VIBE"), id: id)
        let status = RegisterEventHotKey(key, mods, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            hotKeyRefs.append(ref)
        } else {
            NSLog("[FloatVideo] Hotkey \(label) (\(id)) failed: \(status)")
            onRegisterFailed?(label)
        }
    }

    private func fourCC(_ string: String) -> OSType {
        var result: OSType = 0
        for byte in string.utf8.prefix(4) {
            result = (result << 8) + OSType(byte)
        }
        return result
    }
}

// MARK: - Headset / media keys

enum VibeNowPlaying {
    private static var installed = false
    private static weak var target: FloatWindow?

    static func install(target window: FloatWindow) {
        target = window
        guard !installed else { return }
        installed = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.skipForwardCommand.isEnabled = true
        center.skipBackwardCommand.isEnabled = true
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.preferredIntervals = [10]
        center.changePlaybackPositionCommand.isEnabled = true

        center.playCommand.addTarget { _ in
            DispatchQueue.main.async { target?.play() }
            return .success
        }
        center.pauseCommand.addTarget { _ in
            DispatchQueue.main.async { target?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { _ in
            DispatchQueue.main.async { target?.togglePlayPause() }
            return .success
        }
        center.skipForwardCommand.addTarget { _ in
            DispatchQueue.main.async { target?.skipForward() }
            return .success
        }
        center.skipBackwardCommand.addTarget { _ in
            DispatchQueue.main.async { target?.skipBackward() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let seconds = event.positionTime
            DispatchQueue.main.async {
                target?.seekTo(seconds: seconds)
            }
            return .success
        }
    }

    static func clear() {
        target = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    static func update(title: String, elapsed: Double, duration: Double, playing: Bool, rate: Double) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? rate : 0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        if duration.isFinite && duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = playing ? .playing : .paused
    }
}
