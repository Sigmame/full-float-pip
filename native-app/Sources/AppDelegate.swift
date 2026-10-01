import Cocoa
import WebKit
import AVFoundation

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate, AVAudioPlayerDelegate {

    var floatWindow: FloatWindow?
    var httpServer: LocalHTTPServer?
    var catalog: CatalogWindowController?
    var catalogStorage: CatalogStorage?
    var menuBar: MenuBarController?
    let hotkeys = VibeHotkeys()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Start local HTTP server (provides valid Referer for YouTube embed + Vibe-Sync REST API)
        httpServer = LocalHTTPServer()
        httpServer?.onCommand = { [weak self] command, params in
            self?.runNativeCommand(command, params: params) ?? ["success": false, "error": "App not ready"]
        }

        httpServer?.start { port in
            NSLog("[FloatVideo] HTTP server started on port \(port)")
        }

        // Hotkeys are registered per floating window in openFloatWindow(), not
        // here: at launch there is no player to control, and registering now
        // would swallow ⌘⇧G / ⌘⇧B / ⌘⇧D system-wide for nothing.

        startStandalone()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if catalog != nil, catalog?.window.isVisible != true { showCatalog() }
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        menuBar?.buildMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        catalogStorage?.flush()
    }

    /// Player and preference commands shared by the local HTTP API and the catalogue window.
    /// Some branches wait on the main thread, so never call this from it.
    func runNativeCommand(_ command: String, params: [String: String]) -> [String: Any] {
        // Ghost preference + status work even when no float window is open.
        switch command {
        case "ghost", "toggleGhost":
            var ghostState = false
            DispatchQueue.main.sync {
                ghostState = self.toggleGhostPreferringWindow()
            }
            return ["success": true, "isGhost": ghostState]
        case "open":
            // Open a player from a JSON payload (the same fields the catalogue sends). The usual address
            // checks in performOpen apply; this exists for scripts and the end-to-end checks.
            guard let raw = params["payload"], let data = raw.data(using: .utf8),
                  let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return ["success": false, "error": "Missing or invalid payload"]
            }
            var failure: String?
            DispatchQueue.main.sync { failure = self.performOpen(payload) }
            if let failure = failure { return ["success": false, "error": failure] }
            return ["success": true]
        case "status":
            if let win = self.floatWindow {
                var progress: [String: Any] = [:]
                DispatchQueue.main.sync { progress = win.progressPayload() }
                return [
                    "success": true,
                    "title": win.videoTitle,
                    "isPlaying": win.isPlaying,
                    "isGhost": win.isGhostMode,
                    "isAIDubEnabled": win.isAIDubbingEnabled,
                    "dubVoice": EdgeTTSManager.shared.selectedVoice.rawValue,
                    "dubVoiceName": EdgeTTSManager.shared.selectedVoice.displayName,
                    "autoNext": FloatWindow.preferredAutoNextEpisode,
                    "skipIntro": FloatWindow.preferredAutoSkipIntro,
                    "sizePreset": FloatWindow.savedSizePreset.rawValue,
                    "opacity": win.alphaValue,
                    "volume": win.currentVolume,
                    "width": win.frame.width,
                    "height": win.frame.height,
                    "currentTime": win.playbackElapsed,
                    "duration": win.playbackDuration,
                    "progress": progress
                ]
            }
            return [
                "success": true,
                "title": "",
                "isPlaying": false,
                "isGhost": FloatWindow.preferredGhostMode,
                "isAIDubEnabled": false,
                "opacity": 1.0,
                "volume": 1.0,
                "width": 0,
                "height": 0,
                "currentTime": 0,
                "duration": 0,
                "progress": [:] as [String: Any]
            ]
        default:
            break
        }

        guard let win = self.floatWindow else {
            return ["success": false, "error": "No active window"]
        }
        switch command {
        case "toggle", "togglePlayPause":
            DispatchQueue.main.async { win.togglePlayPause() }
            return ["success": true, "isPlaying": win.isPlaying]
        case "pause":
            DispatchQueue.main.async { win.pause() }
            return ["success": true, "paused": true]
        case "play":
            DispatchQueue.main.async { win.play() }
            return ["success": true, "playing": true]
        case "forward":
            DispatchQueue.main.async { win.skipForward() }
            return ["success": true]
        case "backward":
            DispatchQueue.main.async { win.skipBackward() }
            return ["success": true]
        case "duck":
            DispatchQueue.main.async { win.duckVolume() }
            return ["success": true, "ducked": true]
        case "unduck":
            DispatchQueue.main.async { win.unduckVolume() }
            return ["success": true, "ducked": false]
        case "aidub", "aiDub", "toggleAIDub":
            var state = false
            DispatchQueue.main.sync {
                win.toggleAIDubbing()
                state = win.isAIDubbingEnabled
            }
            return ["success": true, "isAIDubEnabled": state]
        case "dubVoice", "edgeVoice", "setDubVoice":
            if let voiceParam = params["voice"] ?? params["val"] {
                if voiceParam.lowercased().contains("nam") {
                    EdgeTTSManager.shared.selectedVoice = .namMinh
                } else {
                    EdgeTTSManager.shared.selectedVoice = .hoaiMy
                }
            }
            let voice = EdgeTTSManager.shared.selectedVoice
            DispatchQueue.main.async {
                win.showHUD("Giọng đọc Edge AI: \(voice.displayName)")
            }
            return ["success": true, "voice": voice.rawValue, "name": voice.displayName]
        case "opacity":
            if let valStr = params["val"], let val = Double(valStr) {
                DispatchQueue.main.async { win.setOpacity(val) }
                return ["success": true, "opacity": val]
            }
            return ["success": false, "error": "Missing val parameter"]
        case "bigger", "grow", "sizeup":
            var size = NSSize.zero
            DispatchQueue.main.sync { size = win.adjustWindowScale(by: 1.18) }
            return ["success": true, "width": size.width, "height": size.height]
        case "smaller", "shrink", "sizedown":
            var size = NSSize.zero
            DispatchQueue.main.sync { size = win.adjustWindowScale(by: 1.0 / 1.18) }
            return ["success": true, "width": size.width, "height": size.height]
        case "size", "resize":
            if let wStr = params["w"] ?? params["width"], let w = Double(wStr) {
                var size = NSSize.zero
                DispatchQueue.main.sync { size = win.setWindowWidth(CGFloat(w)) }
                return ["success": true, "width": size.width, "height": size.height]
            }
            if let factorStr = params["factor"] ?? params["scale"], let factor = Double(factorStr), factor > 0 {
                var size = NSSize.zero
                DispatchQueue.main.sync { size = win.adjustWindowScale(by: CGFloat(factor)) }
                return ["success": true, "width": size.width, "height": size.height]
            }
            return [
                "success": true,
                "width": win.frame.width,
                "height": win.frame.height
            ]
        case "boss":
            var visible = false
            DispatchQueue.main.sync {
                win.toggleBossHide()
                visible = win.isWindowVisible
            }
            return ["success": true, "visible": visible]
        case "nextEpisode", "next":
            var ok = false
            DispatchQueue.main.sync { ok = win.switchEpisode(by: 1) }
            return ["success": ok]
        case "prevEpisode", "prev", "previousEpisode":
            var ok = false
            DispatchQueue.main.sync { ok = win.switchEpisode(by: -1) }
            return ["success": ok]
        case "autoNext", "autonext":
            if let val = params["val"] ?? params["on"] {
                let enabled = ["1","true","on","yes"].contains(val.lowercased())
                DispatchQueue.main.sync {
                    _ = FloatWindow.setPreferredAutoNextEpisode(enabled)
                    win.refreshWatchAssistFromAPI()
                }
                return ["success": true, "autoNext": enabled]
            } else {
                var enabled = false
                DispatchQueue.main.sync {
                    win.toggleAutoNextEpisode()
                    enabled = FloatWindow.preferredAutoNextEpisode
                }
                return ["success": true, "autoNext": enabled]
            }
        case "skipIntro", "skipintro", "autoSkipIntro":
            if let val = params["val"] ?? params["on"] {
                let enabled = ["1","true","on","yes"].contains(val.lowercased())
                DispatchQueue.main.sync {
                    _ = FloatWindow.setPreferredAutoSkipIntro(enabled)
                    win.refreshWatchAssistFromAPI()
                }
                return ["success": true, "skipIntro": enabled]
            } else {
                var enabled = false
                DispatchQueue.main.sync {
                    win.toggleAutoSkipIntro()
                    enabled = FloatWindow.preferredAutoSkipIntro
                }
                return ["success": true, "skipIntro": enabled]
            }
        case "skipIntroNow", "skipintronow":
            DispatchQueue.main.sync { win.manualSkipIntro() }
            return ["success": true]
        case "preset", "sizePreset":
            let name = (params["val"] ?? params["name"] ?? params["id"] ?? "").lowercased()
            let map: [String: FloatWindow.SizePreset] = [
                "mini": .mini, "nho": .mini, "small": .mini,
                "standard": .standard, "vua": .standard, "medium": .standard,
                "wide": .wide, "rong": .wide,
                "pocket": .pocket, "lon": .pocket, "max": .pocket
            ]
            guard let preset = map[name] else {
                return ["success": false, "error": "Unknown preset. Use mini|standard|wide|pocket"]
            }
            var width: CGFloat = 0
            DispatchQueue.main.sync {
                win.applySizePreset(preset)
                width = win.frame.width
            }
            return ["success": true, "preset": preset.rawValue, "width": width]
        default:
            return ["success": false, "error": "Unknown command \(command)"]
        }
    
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false  // Don't quit when window closes
    }

    /// Validate and open a floating player. Returns an error message, or nil when it opened.
    func performOpen(_ msg: [String: Any]) -> String? {
        let url = msg["url"] as? String ?? ""
        let videoSrc = msg["videoSrc"] as? String ?? ""
        let embedUrl = msg["embedUrl"] as? String ?? ""
        // Nothing to play: refuse here rather than open an empty player.
        if url.isEmpty && videoSrc.isEmpty && embedUrl.isEmpty { return "Thiếu địa chỉ video." }
        // Every entry point (catalogue, local API) gets the same document boundary.
        // Direct media may use a CDN, but arbitrary web pages are never opened.
        let curatedMovieID = FloatWindow.curatedYouTubeMovieID(url)
        let curatedYouTubeEmbed = msg["site"] as? String == "youtube"
            && msg["preferEmbed"] as? Bool == true
            && curatedMovieID != nil
            && FloatWindow.curatedYouTubeMovieID(embedUrl) == curatedMovieID
        if !curatedYouTubeEmbed && ((!url.isEmpty && FloatWindow.validateMediaURL(url) == nil
            && !(url == videoSrc && FloatWindow.isSafeMediaSource(videoSrc)))
            || (!embedUrl.isEmpty && FloatWindow.validateMediaURL(embedUrl) == nil)) {
            return "Chỉ được mở các trang xem phim trong danh sách cho phép."
        }
        let title = msg["title"] as? String ?? "VibeFloat"
        let site = msg["site"] as? String ?? "generic"
        let width = msg["width"] as? CGFloat
            ?? CGFloat(msg["width"] as? Int ?? 640)
        let height = msg["height"] as? CGFloat
            ?? CGFloat(msg["height"] as? Int ?? 360)
        let currentTime = msg["currentTime"] as? Double ?? 0
        let movieContext = (msg["movieContext"] as? [String: Any]).flatMap { MovieContext(dict: $0) }
        let preferEmbed = (msg["preferEmbed"] as? Bool) == true
            || (msg["preferEmbed"] as? NSNumber)?.boolValue == true
            || (msg["preferEmbed"] as? String)?.lowercased() == "true"
        let focusSession = (msg["focusSession"] as? Bool) == true
            || (msg["focusSession"] as? NSNumber)?.boolValue == true
            || (msg["focusSession"] as? String)?.lowercased() == "true"
        let aiDubEnabled = (msg["aiDubEnabled"] as? Bool) == true
            || (msg["aiDubEnabled"] as? NSNumber)?.boolValue == true
            || (msg["aiDubEnabled"] as? String)?.lowercased() == "true"

        // Parse cookies
        var cookies: [[String: Any]] = []
        if let rawCookies = msg["cookies"] as? [[String: Any]] {
            cookies = rawCookies
        }

        openFloatWindow(
            url: url, videoSrc: videoSrc.isEmpty ? nil : videoSrc,
            embedUrl: embedUrl.isEmpty ? nil : embedUrl,
            title: title, width: width, height: height,
            currentTime: currentTime, site: site,
            cookies: cookies,
            playerPrefs: msg["playerPrefs"] as? [String: Any],
            movieContext: movieContext,
            preferEmbed: preferEmbed,
            focusSession: focusSession,
            aiDubEnabled: aiDubEnabled
        )
        return nil
    }

    /// Live window state when open; otherwise the persisted preference (default ON).
    func currentGhostState() -> Bool {
        floatWindow?.isGhostMode ?? FloatWindow.preferredGhostMode
    }

    /// Toggle on the open window, or flip+persist preference when no window exists.
    @discardableResult
    func toggleGhostPreferringWindow() -> Bool {
        if let win = floatWindow {
            win.toggleGhostMode()
            return win.isGhostMode
        }
        return FloatWindow.togglePreferredGhostMode()
    }

    /// Registers the global hotkeys. Safe to call repeatedly — it no-ops when the
    /// set is already live, so an open message arriving mid-session cannot
    /// double-register.
    private func installHotkeys() {
        guard FloatWindow.preferredHotkeysEnabled, !hotkeys.isInstalled else { return }
        // Consumed hotkeys so they do not also type into Cursor / the terminal.
        hotkeys.onRegisterFailed = { [weak self] label in
            DispatchQueue.main.async {
                self?.floatWindow?.showHUD("Phím tắt \(label) lỗi")
            }
        }
        hotkeys.install(
            playPause: { [weak self] in self?.floatWindow?.togglePlayPause() },
            ghost: { [weak self] in
                guard let self = self else { return }
                let state = self.toggleGhostPreferringWindow()
                self.tellCatalog(["type": "NATIVE_STATUS_BROADCAST", "connected": true, "isGhost": state])
            },
            boss: { [weak self] in self?.floatWindow?.toggleBossHide() },
            duck: { [weak self] in self?.floatWindow?.toggleDuck() },
            back: { [weak self] in self?.floatWindow?.skipBackward() },
            forward: { [weak self] in self?.floatWindow?.skipForward() },
            volumeUp: { [weak self] in self?.floatWindow?.adjustVolume(by: 0.08) },
            volumeDown: { [weak self] in self?.floatWindow?.adjustVolume(by: -0.08) },
            sizeUp: { [weak self] in self?.floatWindow?.growWindow() },
            sizeDown: { [weak self] in self?.floatWindow?.shrinkWindow() },
            prevEpisode: { [weak self] in self?.floatWindow?.prevEpisode() },
            nextEpisode: { [weak self] in self?.floatWindow?.nextEpisode() },
            sizeMini: { [weak self] in self?.floatWindow?.applySizePreset(.mini) },
            sizeStandard: { [weak self] in self?.floatWindow?.applySizePreset(.standard) },
            sizeWide: { [weak self] in self?.floatWindow?.applySizePreset(.wide) }
        )
    }

    func openFloatWindow(url: String, videoSrc: String?, embedUrl: String?,
                         title: String, width: CGFloat, height: CGFloat,
                         currentTime: Double, site: String,
                         cookies: [[String: Any]] = [],
                         playerPrefs: [String: Any]? = nil,
                         movieContext: MovieContext? = nil,
                         preferEmbed: Bool = false,
                         focusSession: Bool = false,
                         aiDubEnabled: Bool = false) {
        closeFloatWindow()
        stopBrowserAIDub()

        floatWindow = FloatWindow(
            videoWidth: width,
            videoHeight: height,
            videoTitle: title
        )

        let effectiveAIDub = aiDubEnabled || FloatWindow.preferredAIDubEnabled
        floatWindow?.applyMovieContext(movieContext)
        floatWindow?.setPreferYouTubeEmbed(preferEmbed)

        // Hotkeys live exactly as long as the window does.
        floatWindow?.onToggleHotkeys = { [weak self] in
            guard let self = self else { return false }
            if FloatWindow.preferredHotkeysEnabled {
                self.installHotkeys()
            } else {
                self.hotkeys.uninstall()
            }
            return FloatWindow.preferredHotkeysEnabled
        }
        installHotkeys()

        floatWindow?.loadVideo(
            url: url, videoSrc: videoSrc, embedUrl: embedUrl,
            currentTime: currentTime, site: site,
            // Provider, not a snapshot: the HTTP server starts asynchronously and
            // its port is still 0 when the first open message arrives.
            httpServerPortProvider: { [weak self] in self?.httpServer?.port ?? 0 },
            httpServerPlayCapabilityProvider: { [weak self] in self?.httpServer?.localPlayCapability },
            cookies: cookies,
            playerPrefs: playerPrefs
        )

        // Offline Dub must not pause or inspect the WebView before its media
        // document exists. Start it shortly after loadVideo so the player gets
        // first chance to resolve the manifest and install its subtitle tracks.
        if effectiveAIDub {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.floatWindow?.setAIDubEnabled(true)
            }
        }

        floatWindow?.onProgress = { [weak self] payload in
            // "Tiếp tục xem" is saved here, so it works with the window closed.
            if let self = self, let storage = self.catalogStorage {
                CatalogProgress.apply(payload, to: storage)
                self.tellCatalog(payload)
            }
        }

        floatWindow?.onClose = { [weak self] in
            self?.floatWindow = nil
            // The window was closed directly (not replaced), so release the
            // hotkeys too — otherwise ⌘⇧G stays swallowed until the app quits.
            self?.hotkeys.uninstall()
            self?.tellCatalog(["type": "NATIVE_STATUS_BROADCAST", "connected": true, "isGhost": self?.currentGhostState() ?? false])
        }

        floatWindow?.show()
        if focusSession {
            // Background playback never changes the user's click-through choice.
            floatWindow?.duckVolume()
            floatWindow?.showHUD("Nhạc nền — tiếng nhỏ")
        }
    }

    func closeFloatWindow() {
        // Prefer closeWindow so PROGRESS + cleanup run. Clear onClose first so a
        // replace-open does not spam status:closed to Chrome mid-handoff.
        if let win = floatWindow {
            win.onClose = nil
            win.closeWindow()
        }
        floatWindow = nil
        hotkeys.uninstall()
    }

    // MARK: - Standalone Browser Dubbing (For Chrome tabs)

    private struct BrowserDubItem {
        let text: String
        let normalized: String
        let audioURL: URL
        let createdAt: Date
        let cueDuration: Double
    }

    private var browserAudioPlayer: AVAudioPlayer?
    private var browserDubQueue: [BrowserDubItem] = []
    private var browserCurrentPlayingItem: BrowserDubItem?
    private var browserDubGeneration = 0
    private var browserDubSequence = 0
    private var browserLastRequestedSource = ""
    private var browserLastRequestedAt = Date.distantPast
    private let browserDeduplicator = SubtitleDeduplicator(windowSeconds: 12.0)

    func prefetchBrowserAIDubText(_ text: String) {
        let clean = SubtitleClassifier.cleanSubtitleText(text)
        guard clean.count >= 2 else { return }
        DubbingTranslator.shared.translateToVietnamese(text: clean) { viText in
            EdgeTTSManager.shared.prefetch(text: viText)
        }
    }

    func prefetchBatchBrowserAIDubTexts(_ texts: [String]) {
        let cleaned = texts.map { SubtitleClassifier.cleanSubtitleText($0) }.filter { $0.count >= 2 }
        guard !cleaned.isEmpty else { return }
        DubbingTranslator.shared.translateBatch(texts: cleaned) { dict in
            for vi in dict.values {
                EdgeTTSManager.shared.prefetch(text: vi)
            }
        }
    }

    private func speakBrowserAIDub(text: String, duration: Double) {
        let clean = SubtitleClassifier.cleanSubtitleText(text)
        guard clean.count >= 2 else { return }
        let sourceKey = SubtitleClassifier.normalizedForDubbing(clean)
        if sourceKey == browserLastRequestedSource && Date().timeIntervalSince(browserLastRequestedAt) < 1.0 { return }
        browserLastRequestedSource = sourceKey
        browserLastRequestedAt = Date()
        let generation = browserDubGeneration
        browserDubSequence &+= 1
        let sequence = browserDubSequence
        let requestedAt = Date()

        DubbingTranslator.shared.translateToVietnamese(text: clean) { [weak self] viText in
            DispatchQueue.main.async {
                guard let self = self, self.browserDubGeneration == generation, self.browserDubSequence == sequence else { return }
                self.speakBrowserAIDubVietnamese(text: viText, duration: duration, generation: generation, sequence: sequence, requestedAt: requestedAt)
            }
        }
    }

    private func speakBrowserAIDubVietnamese(text: String, duration: Double, generation: Int, sequence: Int, requestedAt: Date) {
        guard browserDeduplicator.shouldDub(text: text) else {
            return
        }

        let clean = SubtitleClassifier.cleanSubtitleText(text)
        guard clean.count >= 2 else { return }
        let norm = SubtitleClassifier.normalizedForDubbing(clean)

        // Use the same rate as prefetch; the player handles cue-time compression.
        let edgeRate = EdgeTTSManager.calculateSubtitleRate(text: clean)

        EdgeTTSManager.shared.synthesize(text: clean, rate: edgeRate) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, self.browserDubGeneration == generation, self.browserDubSequence == sequence else { return }
                switch result {
                case .success(let url):
                    if duration > 0.4 && Date().timeIntervalSince(requestedAt) >= duration {
                        NSLog("[AIDub] Dropped browser audio after cue expired (%.2fs)", Date().timeIntervalSince(requestedAt))
                        return
                    }
                    // Queue-level deduplication:
                    if let playing = self.browserCurrentPlayingItem {
                        if playing.normalized == norm || SubtitleClassifier.isNearDuplicate(clean, of: playing.text) {
                            return
                        }
                    }
                    self.browserAudioPlayer?.stop()
                    self.browserAudioPlayer = nil
                    self.browserCurrentPlayingItem = nil
                    self.browserDubQueue.removeAll()

                    let item = BrowserDubItem(text: clean, normalized: norm, audioURL: url, createdAt: requestedAt, cueDuration: duration)
                    self.browserDubQueue.append(item)
                    self.drainBrowserDubQueueIfNeeded()

                case .failure(let err):
                    NSLog("[FloatVideo] Standalone Edge TTS error: %@", err.localizedDescription)
                }
            }
        }
    }

    private func drainBrowserDubQueueIfNeeded() {
        if let player = browserAudioPlayer, player.isPlaying {
            return
        }

        let now = Date()
        browserDubQueue.removeAll { now.timeIntervalSince($0.createdAt) > 2.5 }

        if browserDubQueue.count > 1 {
            let newest = browserDubQueue.removeLast()
            browserDubQueue.removeAll()
            browserDubQueue.append(newest)
        }

        guard !browserDubQueue.isEmpty else {
            browserCurrentPlayingItem = nil
            return
        }

        let nextItem = browserDubQueue.removeFirst()
        do {
            let player = try AVAudioPlayer(contentsOf: nextItem.audioURL)
            player.delegate = self
            player.enableRate = true

            let audioDuration = player.duration
            let targetDuration = nextItem.cueDuration > 0.4 ? nextItem.cueDuration : max(1.2, Double(nextItem.text.count) / 13.0)
            let maxAllowedTime = targetDuration * 1.15

            if audioDuration > maxAllowedTime {
                let requiredRate = Float(audioDuration / maxAllowedTime)
                player.rate = min(1.65, max(1.10, requiredRate))
            } else {
                player.rate = 1.15
            }

            player.volume = 1.0
            player.prepareToPlay()
            player.play()
            self.browserAudioPlayer = player
            self.browserCurrentPlayingItem = nextItem
            if ProcessInfo.processInfo.environment["VIBEFLOAT_DUB_DEBUG"] == "1" {
                NSLog("[AIDub] browser audio started %.3fs after cue", Date().timeIntervalSince(nextItem.createdAt))
            }
        } catch {
            NSLog("[FloatVideo] Standalone AVAudioPlayer error: %@", error.localizedDescription)
            self.browserAudioPlayer = nil
            self.browserCurrentPlayingItem = nil
            drainBrowserDubQueueIfNeeded()
        }
    }

    private func stopBrowserAIDub() {
        browserDubGeneration &+= 1
        browserLastRequestedSource = ""
        browserDubQueue.removeAll()
        browserCurrentPlayingItem = nil
        browserDeduplicator.reset()
        EdgeTTSManager.shared.cancelAll()
        if let player = browserAudioPlayer, player.isPlaying {
            player.stop()
        }
        browserAudioPlayer = nil
    }

    // MARK: - AVAudioPlayerDelegate

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            guard let self = self else { return }
            if self.browserAudioPlayer === player {
                self.browserAudioPlayer = nil
                self.browserCurrentPlayingItem = nil
                self.drainBrowserDubQueueIfNeeded()
            }
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.browserAudioPlayer === player {
                self.browserAudioPlayer = nil
                self.browserCurrentPlayingItem = nil
                self.drainBrowserDubQueueIfNeeded()
            }
        }
    }
}
