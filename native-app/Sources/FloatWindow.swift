import Cocoa
import WebKit
import QuartzCore

// MARK: - LoadingOverlayView — Loading overlay (auto-centered spinner)

private class LoadingOverlayView: NSView {
    var spinnerLayer: CALayer?

    override func layout() {
        super.layout()
        guard let spinner = spinnerLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spinner.position = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
        CATransaction.commit()
    }
}

// MARK: - DraggableTitleBar — Title bar that supports drag-to-move window

private class DraggableTitleBar: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

// MARK: - ProgressClickView — Progress bar click area

private class ProgressClickView: NSView {
    var onSeek: ((Double) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        let percent = max(0, min(1, Double(loc.x / bounds.width)))
        onSeek?(percent)
    }
}

// MARK: - FloatWindow — Always-on-top floating video window

class FloatWindow: NSPanel, WKNavigationDelegate {

    private var webView: WKWebView!
    private var titleBarView: NSView!
    private var titleLabel: NSTextField!
    private var controlBarView: NSView!
    private var playPauseButton: NSButton!
    private var skipButton: NSButton!
    private var volumeButton: NSButton!
    private var volumeSlider: NSSlider!
    private var timeLabel: NSTextField!
    private var progressBg: NSView!
    private var progressPlayed: NSView!
    private var updateTimer: Timer?
    private var videoTitle: String
    private var isPlaying = true
    private var userWantsMute = false
    private var videoAspectRatio: CGFloat = 16.0 / 9.0

    // Video loading parameters (used by WKNavigationDelegate callbacks)
    private var currentSite: String = "generic"
    private var currentVideoTime: Double = 0
    private var hasInjectedJS = false
    private var hasInjectedAdSkip = false
    private var lastAdSkipCount = 0
    private var lastAdFFCount = 0
    private var isPostingSyntheticClick = false
    private var playerPrefs: [String: Any]?
    private var prefsApplyDeadline: Date?
    private var lastPrefsStatus = "never-ran"
    private var currentPageURL: String = ""
    // Queried lazily: the local HTTP server starts asynchronously and its port
    // is still 0 when the open message arrives, so a snapshot taken in
    // loadVideo would permanently disable the YouTube embed fallback.
    private var httpServerPortProvider: (() -> UInt16)?
    private var loadingOverlay: NSView?
    private var hasTriedYouTubeEmbedFallback = false
    private var youtubeEmbedFallbackURL: URL?
    private var youtubeFallbackWorkItem: DispatchWorkItem?
    private var reinjectLayoutWorkItem: DispatchWorkItem?

    private enum LoadingStrategy {
        case directVideo, youtubeEmbed, siteEmbed, fullPageInject
    }
    private var loadingStrategy: LoadingStrategy = .fullPageInject

    private static let frameKey = "FloatVideoWindowFrame"

    var onClose: (() -> Void)?

    // For hover show/hide control bar (cursor-position polling)
    private var isHovering = false
    private var hideTimer: DispatchWorkItem?
    private var cursorPollTimer: Timer?
    private var cursorWasInside = false

    // For window resize dragging
    private var initialMouseLocation: NSPoint = .zero
    private var initialWindowFrame: NSRect = .zero

    // For window resizing
    private var isResizing = false
    private var resizeEdge: ResizeEdge = .none
    private let resizeBorderWidth: CGFloat = 12

    enum ResizeEdge {
        case none
        case left, right, top, bottom
        case topLeft, topRight, bottomLeft, bottomRight
    }

    init(videoWidth: CGFloat, videoHeight: CGFloat, videoTitle: String) {
        self.videoTitle = videoTitle

        let titleBarHeight: CGFloat = 30
        let windowWidth = max(videoWidth, 320)
        let windowHeight = max(videoHeight, 180)

        self.videoAspectRatio = windowWidth / windowHeight

        let contentRect = NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight)

        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )

        self.contentAspectRatio = NSSize(width: windowWidth, height: windowHeight)
        configureWindow()
        setupUI(width: windowWidth, height: windowHeight, titleBarHeight: titleBarHeight)
        positionWindow()
    }

    // MARK: - Window Configuration

    private func configureWindow() {
        // Key setting 1: Very high window level -- overlay fullscreen apps
        self.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) + 1)

        // Key setting 2: Collection behavior -- visible on all Spaces/desktops
        self.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
        ]

        // Save position after drag ends (performDrag does not trigger mouseUp)
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification,
            object: self, queue: .main) { [weak self] _ in
            self?.saveWindowFrame()
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification,
            object: self, queue: .main) { [weak self] _ in
            self?.scheduleInjectedLayoutRefresh()
        }

        // Key setting 3: Floating panel properties
        self.isFloatingPanel = true
        self.hidesOnDeactivate = false
        self.isMovableByWindowBackground = false
        self.hasShadow = true
        self.isOpaque = false
        self.backgroundColor = .clear

        // Window size constraints (based on video aspect ratio, prevent minSize from breaking locked aspect ratio)
        let minW: CGFloat = 200
        let maxW: CGFloat = 1920
        self.minSize = NSSize(width: minW, height: minW / videoAspectRatio)
        self.maxSize = NSSize(width: maxW, height: maxW / videoAspectRatio)
    }

    // MARK: - UI Setup

    private func setupUI(width: CGFloat, height: CGFloat, titleBarHeight: CGFloat) {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.masksToBounds = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        container.layer?.borderColor = NSColor(white: 1.0, alpha: 0.1).cgColor
        container.layer?.borderWidth = 0.5

        // Title bar (using DraggableTitleBar for drag support)
        titleBarView = DraggableTitleBar(frame: NSRect(
            x: 0, y: height - titleBarHeight,
            width: width, height: titleBarHeight
        ))
        titleBarView.wantsLayer = true
        titleBarView.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.95).cgColor
        titleBarView.autoresizingMask = [.width, .minYMargin]

        // Close button
        let closeBtn = createCircleButton(
            frame: NSRect(x: 10, y: 7, width: 16, height: 16),
            color: NSColor(red: 1.0, green: 0.38, blue: 0.35, alpha: 1.0),
            action: #selector(closeWindow)
        )
        titleBarView.addSubview(closeBtn)

        // Opacity button
        let miniBtn = createCircleButton(
            frame: NSRect(x: 32, y: 7, width: 16, height: 16),
            color: NSColor(red: 1.0, green: 0.82, blue: 0.28, alpha: 1.0),
            action: #selector(toggleOpacity)
        )
        titleBarView.addSubview(miniBtn)

        // Always-on-top indicator
        let pinBtn = createCircleButton(
            frame: NSRect(x: 54, y: 7, width: 16, height: 16),
            color: NSColor(red: 0.27, green: 0.85, blue: 0.46, alpha: 1.0),
            action: nil
        )
        titleBarView.addSubview(pinBtn)

        // Title text
        titleLabel = NSTextField(frame: NSRect(
            x: 78, y: 5,
            width: width - 88, height: 20
        ))
        titleLabel.stringValue = videoTitle
        titleLabel.isEditable = false
        titleLabel.isBordered = false
        titleLabel.drawsBackground = false
        titleLabel.backgroundColor = .clear
        titleLabel.textColor = NSColor(white: 0.85, alpha: 1.0)
        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.autoresizingMask = [.width]
        titleBarView.addSubview(titleLabel)

        // WKWebView (fills entire window, title bar overlays on top)
        let webConfig = WKWebViewConfiguration()
        webConfig.mediaTypesRequiringUserActionForPlayback = []
        webConfig.websiteDataStore = .nonPersistent()

        let webFrame = NSRect(x: 0, y: 0, width: width, height: height)
        webView = WKWebView(frame: webFrame, configuration: webConfig)
        webView.autoresizingMask = [.width, .height]
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = self

        // Use native Safari User-Agent to avoid JS engine fingerprint mismatch triggering YouTube's "fake browser" bot detection
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.3 Safari/605.1.15"


        container.addSubview(webView)

        // Loading overlay (covers webView during loading)
        let overlay = LoadingOverlayView(frame: webFrame)
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.black.cgColor
        overlay.autoresizingMask = [.width, .height]

        let spinnerSize: CGFloat = 36.0
        let spinnerContainer = CALayer()
        spinnerContainer.bounds = CGRect(x: 0, y: 0, width: spinnerSize, height: spinnerSize)
        spinnerContainer.position = CGPoint(x: webFrame.width / 2, y: webFrame.height / 2)

        let arcPath = CGMutablePath()
        arcPath.addArc(
            center: CGPoint(x: spinnerSize / 2, y: spinnerSize / 2),
            radius: spinnerSize / 2 - 2,
            startAngle: 0,
            endAngle: .pi * 1.5,
            clockwise: false
        )
        let arcLayer = CAShapeLayer()
        arcLayer.frame = spinnerContainer.bounds
        arcLayer.path = arcPath
        arcLayer.strokeColor = NSColor(white: 0.5, alpha: 0.8).cgColor
        arcLayer.fillColor = nil
        arcLayer.lineWidth = 2.5
        arcLayer.lineCap = .round
        spinnerContainer.addSublayer(arcLayer)

        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = 2 * Double.pi
        rotation.duration = 1.0
        rotation.repeatCount = .infinity
        spinnerContainer.add(rotation, forKey: "spin")

        overlay.layer?.addSublayer(spinnerContainer)
        overlay.spinnerLayer = spinnerContainer
        container.addSubview(overlay)
        self.loadingOverlay = overlay

        // Title bar (overlays on top of webView and overlay, shown on hover)
        container.addSubview(titleBarView)

        // Bottom control bar (shown on hover, YouTube-style)
        let barH: CGFloat = 44
        controlBarView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: barH))
        controlBarView.wantsLayer = true
        controlBarView.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.85).cgColor
        controlBarView.autoresizingMask = [.width, .maxYMargin]
        controlBarView.alphaValue = 0

        // -- Progress bar (top, full-width 4px)
        progressBg = NSView(frame: NSRect(x: 0, y: barH - 4, width: width, height: 4))
        progressBg.wantsLayer = true
        progressBg.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.15).cgColor
        progressBg.autoresizingMask = [.width]
        controlBarView.addSubview(progressBg)

        progressPlayed = NSView(frame: NSRect(x: 0, y: barH - 4, width: 0, height: 4))
        progressPlayed.wantsLayer = true
        progressPlayed.layer?.backgroundColor = NSColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0).cgColor
        controlBarView.addSubview(progressPlayed)

        // Progress bar click area (larger hit target)
        let progressHit = ProgressClickView(frame: NSRect(x: 0, y: barH - 12, width: width, height: 12))
        progressHit.autoresizingMask = [.width]
        progressHit.onSeek = { [weak self] percent in self?.seekTo(percent: percent) }
        controlBarView.addSubview(progressHit)

        // -- Control button row (y=0 to barH-4)
        var x: CGFloat = 8

        // Play/Pause
        let ppBtn = makeControlButton(x: x, symbolName: "pause.fill", action: #selector(togglePlayPause))
        self.playPauseButton = ppBtn
        controlBarView.addSubview(ppBtn)
        x += 32

        // Skip 10s
        let skipBtn = makeControlButton(x: x, symbolName: "goforward.10", action: #selector(skipForward))
        self.skipButton = skipBtn
        controlBarView.addSubview(skipBtn)
        x += 32

        // Volume
        let volBtn = makeControlButton(x: x, symbolName: "speaker.wave.2.fill", action: #selector(toggleMute))
        self.volumeButton = volBtn
        controlBarView.addSubview(volBtn)
        x += 28

        // Volume slider
        let slider = NSSlider(frame: NSRect(x: x, y: 10, width: 60, height: 20))
        slider.minValue = 0
        slider.maxValue = 1
        slider.doubleValue = 1
        slider.target = self
        slider.action = #selector(volumeChanged(_:))
        slider.isContinuous = true
        slider.controlSize = .small
        controlBarView.addSubview(slider)
        self.volumeSlider = slider
        x += 64

        // Time label (right-aligned, left of the track menu button)
        let tLabel = NSTextField(frame: NSRect(x: width - 136, y: 8, width: 92, height: 20))
        tLabel.stringValue = "0:00 / 0:00"
        tLabel.isEditable = false
        tLabel.isBordered = false
        tLabel.drawsBackground = false
        tLabel.textColor = NSColor(white: 0.9, alpha: 1.0)
        tLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        tLabel.alignment = .right
        tLabel.lineBreakMode = .byClipping
        tLabel.autoresizingMask = [.minXMargin]
        self.timeLabel = tLabel
        controlBarView.addSubview(tLabel)

        // Playback settings menu (far right, clear of the resize border)
        let tracksBtn = makeControlButton(x: width - 44, symbolName: "gearshape.fill",
                                          action: #selector(showTrackMenu(_:)))
        tracksBtn.autoresizingMask = [.minXMargin]
        tracksBtn.toolTip = "Playback settings"
        controlBarView.addSubview(tracksBtn)

        container.addSubview(controlBarView)

        // Hide title bar by default (PiP-style: shown on hover)
        titleBarView.alphaValue = 0

        // Add resize indicator (bottom-right corner)
        let resizeIndicator = NSTextField(frame: NSRect(
            x: width - 20, y: 0, width: 16, height: 16
        ))
        resizeIndicator.stringValue = "⟋"
        resizeIndicator.isEditable = false
        resizeIndicator.isBordered = false
        resizeIndicator.drawsBackground = false
        resizeIndicator.textColor = NSColor(white: 0.5, alpha: 0.6)
        resizeIndicator.font = NSFont.systemFont(ofSize: 12)
        resizeIndicator.autoresizingMask = [.minXMargin, .maxYMargin]
        container.addSubview(resizeIndicator)

        self.contentView = container

        // Add tracking area for the entire window (for setting resize cursors)
        let trackingArea = NSTrackingArea(
            rect: container.bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        container.addTrackingArea(trackingArea)
    }

    private func createCircleButton(frame: NSRect, color: NSColor, action: Selector?) -> NSView {
        let btn = NSButton(frame: frame)
        btn.bezelStyle = .circular
        btn.title = ""
        btn.isBordered = false
        btn.wantsLayer = true
        btn.layer?.backgroundColor = color.cgColor
        btn.layer?.cornerRadius = frame.width / 2

        if let action = action {
            btn.target = self
            btn.action = action
        }

        return btn
    }

    // MARK: - Window Positioning

    private func positionWindow() {
        // Try to restore the last saved window position and size
        if let dict = UserDefaults.standard.dictionary(forKey: Self.frameKey),
           let x = dict["x"] as? CGFloat, let y = dict["y"] as? CGFloat,
           let w = dict["w"] as? CGFloat, dict["h"] is CGFloat {
            let restoredW = max(w, self.minSize.width)
            let savedFrame = NSRect(x: x, y: y, width: restoredW, height: restoredW / videoAspectRatio)
            // Ensure the saved position is still on a visible screen
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(savedFrame) }) {
                self.setFrame(savedFrame, display: false)
                return
            }
        }
        // Default position: bottom-right corner of the screen
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.maxX - self.frame.width - 24
        let y = screenFrame.minY + 24
        self.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func saveWindowFrame() {
        let frame = self.frame
        let dict: [String: CGFloat] = [
            "x": frame.origin.x, "y": frame.origin.y,
            "w": frame.size.width, "h": frame.size.height
        ]
        UserDefaults.standard.set(dict, forKey: Self.frameKey)
    }

    // MARK: - Video Loading

    func loadVideo(url: String, videoSrc: String?, embedUrl: String?,
                   currentTime: Double, site: String,
                   httpServerPortProvider: (() -> UInt16)? = nil,
                   cookies: [[String: Any]] = [],
                   playerPrefs: [String: Any]? = nil) {
        // Save parameters for NavigationDelegate use
        self.currentSite = site
        self.currentVideoTime = currentTime
        self.currentPageURL = url
        self.httpServerPortProvider = httpServerPortProvider
        self.playerPrefs = playerPrefs
        self.hasInjectedJS = false
        self.loadingStrategy = .fullPageInject
        resetYouTubeFallbackState()
        installPlayerPrefsSeedScript()

        if site == "youtube" {
            // One-line capture summary so caption/audio problems are attributable
            // at a glance: was the track (incl. translation) captured at all?
            // "off" = tab had CC off; "none" = nothing captured.
            var trackDesc = (playerPrefs?["captionsOff"] as? Bool == true) ? "off" : "none"
            if let track = playerPrefs?["captionTrack"] as? [String: Any],
               let lang = track["languageCode"] as? String {
                if let tl = track["translationLanguage"] as? [String: Any],
                   let tlang = tl["languageCode"] as? String {
                    trackDesc = "\(lang)->\(tlang)"
                } else {
                    trackDesc = lang
                }
            }
            let audioDesc = (playerPrefs?["audioTrack"] as? [String: Any])?["id"] as? String ?? "default"
            let lsCount = (playerPrefs?["localStorage"] as? [String: Any])?.count ?? 0
            let rate = (playerPrefs?["playbackRate"] as? NSNumber)?.doubleValue ?? 1.0
            NSLog("%@", "[FloatVideo] playerPrefs received: track=\(trackDesc) audio=\(audioDesc) lsKeys=\(lsCount) rate=\(rate)")
        }

        // Suspend all media playback while overlay is visible, prevent audio during loading
        webView.setAllMediaPlaybackSuspended(true, completionHandler: nil)

        // Priority 1: Direct video source URL
        if let videoSrc = videoSrc, !videoSrc.isEmpty {
            self.loadingStrategy = .directVideo
            let html = buildVideoHTML(videoSrc: videoSrc, currentTime: currentTime)
            webView.loadHTMLString(html, baseURL: URL(string: videoSrc))
            NSLog("%@", "[FloatVideo] Loading direct video: \(logSafeURL(videoSrc))")
            return
        }

        // Priority 2: YouTube -- prefer watch page + JS injection, keep embed as fallback
        if site == "youtube" {
            refreshYouTubeEmbedFallbackURLIfNeeded()

            if !url.isEmpty, let pageURL = URL(string: url) {
                let loadPage = { [weak self] in
                    self?.loadingStrategy = .fullPageInject
                    self?.webView.load(URLRequest(url: pageURL))
                    NSLog("%@", "[FloatVideo] Loading YouTube full page for JS injection: \(logSafeURL(url))")
                }

                if !cookies.isEmpty {
                    injectCookies(cookies) {
                        loadPage()
                    }
                } else {
                    loadPage()
                }
                return
            }

            if startYouTubeEmbedFallback(reason: "missing-full-page-url") {
                return
            }
        }

        // Priority 3: Embed URL -- wrap in iframe (non-YouTube sites)
        if let embedUrl = embedUrl, !embedUrl.isEmpty {
            self.loadingStrategy = .siteEmbed
            let html = buildEmbedHTML(embedUrl: embedUrl)
            webView.loadHTMLString(html, baseURL: nil)
            NSLog("%@", "[FloatVideo] Loading embed via iframe: \(logSafeURL(embedUrl))")
            return
        }

        // Priority 4: Load full page and inject JS
        if !url.isEmpty, let pageURL = URL(string: url) {
            webView.load(URLRequest(url: pageURL))
            NSLog("%@", "[FloatVideo] Loading full page: \(logSafeURL(url))")
        }
    }

    // MARK: - Cookie Injection

    private func injectCookies(_ cookies: [[String: Any]], completion: @escaping () -> Void) {
        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        let group = DispatchGroup()

        for cookieData in cookies {
            guard let name = cookieData["name"] as? String,
                  let value = cookieData["value"] as? String else { continue }

            let domain = cookieData["domain"] as? String ?? ".youtube.com"
            let path = cookieData["path"] as? String ?? "/"
            let secure = cookieData["secure"] as? Bool ?? false

            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name,
                .value: value,
                .domain: domain,
                .path: path,
            ]
            if secure {
                properties[.secure] = "TRUE"
            }
            if cookieData["httpOnly"] as? Bool == true {
                properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE"
            }

            if let cookie = HTTPCookie(properties: properties) {
                group.enter()
                cookieStore.setCookie(cookie) {
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) {
            NSLog("[FloatVideo] All cookies injected")
            completion()
        }
    }

    private func extractYouTubeVideoId(from url: String) -> String? {
        // youtube.com/watch?v=VIDEO_ID
        if let range = url.range(of: "v=") {
            let start = range.upperBound
            let remaining = String(url[start...])
            let videoId = remaining.components(separatedBy: CharacterSet(charactersIn: "&# ")).first
            if let id = videoId, !id.isEmpty { return id }
        }
        // youtube.com/shorts/VIDEO_ID
        if let range = url.range(of: "/shorts/") {
            let start = range.upperBound
            let remaining = String(url[start...])
            let videoId = remaining.components(separatedBy: CharacterSet(charactersIn: "?&# /")).first
            if let id = videoId, !id.isEmpty { return id }
        }
        return nil
    }

    private func buildYouTubeEmbedFallbackURL(pageURL: String, currentTime: Double,
                                              httpServerPort: UInt16) -> URL? {
        guard httpServerPort > 0,
              let videoId = extractYouTubeVideoId(from: pageURL) else {
            return nil
        }

        let startSeconds = Int(currentTime)
        let safeViewport = youtubeSafeViewportSize()
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(httpServerPort)
        components.path = "/play"
        components.queryItems = [
            URLQueryItem(name: "v", value: videoId),
            URLQueryItem(name: "t", value: String(startSeconds)),
            URLQueryItem(name: "w", value: String(Int(safeViewport.width))),
            URLQueryItem(name: "h", value: String(Int(safeViewport.height))),
        ]
        return components.url
    }

    private func youtubeSafeViewportSize() -> NSSize {
        let ratio = max(videoAspectRatio, 0.1)
        let minViewport: CGFloat = 200
        let recommendedLongEdge: CGFloat = 480
        let recommendedShortEdge: CGFloat = 270

        if ratio >= 1 {
            let height = max(recommendedShortEdge, recommendedLongEdge / ratio, minViewport)
            let width = max(height * ratio, recommendedLongEdge, minViewport)
            return NSSize(width: ceil(width), height: ceil(height))
        }

        let width = max(recommendedShortEdge, recommendedLongEdge * ratio, minViewport)
        let height = max(width / ratio, recommendedLongEdge, minViewport)
        return NSSize(width: ceil(width), height: ceil(height))
    }

    private func resetYouTubeFallbackState() {
        youtubeFallbackWorkItem?.cancel()
        youtubeFallbackWorkItem = nil
        reinjectLayoutWorkItem?.cancel()
        reinjectLayoutWorkItem = nil
        youtubeEmbedFallbackURL = nil
        hasTriedYouTubeEmbedFallback = false
    }

    /// Builds the embed fallback URL if it couldn't be built earlier. The HTTP
    /// server usually isn't ready yet when loadVideo runs (port still 0), so
    /// callers that need the fallback URL retry here with the live port.
    private func refreshYouTubeEmbedFallbackURLIfNeeded() {
        guard currentSite == "youtube", youtubeEmbedFallbackURL == nil else { return }
        youtubeEmbedFallbackURL = buildYouTubeEmbedFallbackURL(
            pageURL: currentPageURL,
            currentTime: currentVideoTime,
            httpServerPort: httpServerPortProvider?() ?? 0
        )
    }

    private func shouldUseYouTubeFullPagePrimary() -> Bool {
        currentSite == "youtube"
            && loadingStrategy == .fullPageInject
            && youtubeEmbedFallbackURL != nil
    }

    /// Mirrors the Chrome tab's `yt-player-*` localStorage (caption stickiness,
    /// quality, playback rate, volume) into this fresh WKWebView session BEFORE
    /// YouTube's code boots, so the floating player starts with the same player
    /// settings the user had in the browser tab.
    private func installPlayerPrefsSeedScript() {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        guard currentSite == "youtube",
              let raw = playerPrefs?["localStorage"] as? [String: Any] else { return }
        let ls = raw.compactMapValues { $0 as? String }
        guard !ls.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: ls) else { return }
        let b64 = data.base64EncodedString()
        let source = """
        try {
            var d = JSON.parse(atob('\(b64)'));
            for (var k in d) { try { localStorage.setItem(k, d[k]); } catch (e) {} }
        } catch (e) {}
        """
        controller.addUserScript(WKUserScript(source: source,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true))
    }

    /// Re-applies the exact per-video player state captured from the Chrome tab
    /// at float time: the audio track (dubbed videos), the caption track
    /// (including auto-translate target language) or captions explicitly off,
    /// and the playback rate. Retries until YouTube's player + caption module
    /// are ready; the localStorage seed above already covers the sticky
    /// defaults, this covers the current video's explicit selection. Without it
    /// the WKWebView session (different language than Chrome) gets YouTube's
    /// own picks — e.g. an auto-dubbed track and auto-enabled captions.
    private func scheduleApplyPlayerPrefs() {
        guard currentSite == "youtube", loadingStrategy == .fullPageInject,
              playerPrefs != nil else { return }
        // Deadline, not a retry count: a pre-roll ad (or a re-serve loop) can
        // occupy the player for tens of seconds, during which the caption
        // tracklist is the AD's (empty) one. Attempts during ads don't count.
        prefsApplyDeadline = Date().addingTimeInterval(60)
        attemptApplyPlayerPrefs(after: 2.0)
    }

    private func attemptApplyPlayerPrefs(after delay: TimeInterval) {
        guard let deadline = prefsApplyDeadline else { return }
        guard Date() < deadline else {
            NSLog("%@", "[FloatVideo] Player prefs give-up after 60s (last status: \(lastPrefsStatus))")
            prefsApplyDeadline = nil
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, let prefs = self.playerPrefs else { return }
            var sync: [String: Any] = [
                "rate": (prefs["playbackRate"] as? NSNumber)?.doubleValue ?? 1.0
            ]
            if let track = prefs["captionTrack"] as? [String: Any] {
                sync["captionTrack"] = track
            } else if prefs["captionsOff"] as? Bool == true {
                sync["captionsOff"] = true
            }
            if let audioId = (prefs["audioTrack"] as? [String: Any])?["id"] as? String {
                sync["audioId"] = audioId
            }
            self.runMediaTracksJS(["action": "sync", "prefs": sync]) { [weak self] result in
                guard let self = self else { return }
                let status = result as? String ?? "retry"
                self.lastPrefsStatus = status
                switch status {
                case "applied":
                    NSLog("[FloatVideo] Player prefs applied (audio/captions/rate)")
                    self.prefsApplyDeadline = nil
                case "ad":
                    // Ad occupying the player: extend patience past the ad
                    // without counting against the deadline meaningfully.
                    self.prefsApplyDeadline = max(self.prefsApplyDeadline ?? Date(),
                                                  Date().addingTimeInterval(30))
                    self.attemptApplyPlayerPrefs(after: 1.5)
                case "retry":
                    self.attemptApplyPlayerPrefs(after: 1.5)
                default:
                    self.prefsApplyDeadline = nil // 'done' or unexpected
                }
            }
        }
    }

    private func scheduleInjectedLayoutRefresh(after delay: TimeInterval = 0.05) {
        guard hasInjectedJS, loadingStrategy == .fullPageInject else { return }
        reinjectLayoutWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.refreshInjectedLayout()
        }
        reinjectLayoutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func refreshInjectedLayout() {
        guard hasInjectedJS, loadingStrategy == .fullPageInject else { return }
        let js = "if (window.__floatVideoApplyLayout) { window.__floatVideoApplyLayout(); true } else { false }"
        webView.evaluateJavaScript(js) { [weak self] result, error in
            if let error = error {
                NSLog("%@", "[FloatVideo] Layout refresh JS error: \(logSafeError(error))")
                return
            }
            if let ok = result as? Bool, !ok {
                self?.injectVideoMaximize(site: self?.currentSite ?? "generic",
                                          currentTime: self?.currentVideoTime ?? 0)
            }
        }
    }

    private func scheduleYouTubeEmbedFallbackCheck(after delay: TimeInterval) {
        guard shouldUseYouTubeFullPagePrimary() else { return }
        youtubeFallbackWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self,
                  self.shouldUseYouTubeFullPagePrimary(),
                  !self.hasInjectedJS else { return }
            _ = self.startYouTubeEmbedFallback(reason: "inject-timeout")
        }
        youtubeFallbackWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    @discardableResult
    private func startYouTubeEmbedFallback(reason: String) -> Bool {
        guard !hasTriedYouTubeEmbedFallback,
              let fallbackURL = youtubeEmbedFallbackURL else {
            return false
        }

        hasTriedYouTubeEmbedFallback = true
        youtubeFallbackWorkItem?.cancel()
        youtubeFallbackWorkItem = nil
        loadingStrategy = .youtubeEmbed
        hasInjectedJS = false
        webView.load(URLRequest(url: fallbackURL))
        NSLog("%@", "[FloatVideo] Switching YouTube to embed fallback (\(reason)): \(logSafeURL(fallbackURL.absoluteString))")
        return true
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        NSLog("%@", "[FloatVideo] Page loaded (strategy: \(loadingStrategy), site: \(currentSite)), webView: \(webView.frame), container: \(self.contentView?.frame ?? .zero)")

        if loadingStrategy == .fullPageInject {
            // Full page load + JS inject: delay removing overlay after injection to let DOM operations complete
            guard !hasInjectedJS else { return }
            refreshYouTubeEmbedFallbackURLIfNeeded()
            injectVideoMaximize(site: currentSite, currentTime: currentVideoTime)
            // Auto-skip YouTube ads. Idempotent in-page guard (installs a single
            // interval); safe to call alongside the injection retries below.
            // Deliberately NOT gated on shouldUseYouTubeFullPagePrimary(): the
            // guard has no dependency on the embed fallback URL.
            if currentSite == "youtube" {
                injectAdSkip()
                scheduleApplyPlayerPrefs()
            }
            // VK Video can take 8+ s after didFinish to give its player a source.
            for delay in [1.5, 3.0, 5.0, 8.0, 12.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self = self, self.loadingStrategy == .fullPageInject,
                          !self.hasInjectedJS else { return }
                    self.injectVideoMaximize(site: self.currentSite,
                                             currentTime: self.currentVideoTime)
                }
            }
            // The overlay stays until the video is isolated (or show()'s 8 s safety), so the raw page never flashes.
            if shouldUseYouTubeFullPagePrimary() {
                scheduleYouTubeEmbedFallbackCheck(after: 5.5)
            }
        } else {
            // Other strategies (direct video, YouTube embed, site embed) have built-in autoplay, remove overlay directly
            hideLoadingOverlay()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        NSLog("%@", "[FloatVideo] Page load failed: \(logSafeError(error))")
        refreshYouTubeEmbedFallbackURLIfNeeded()
        if shouldUseYouTubeFullPagePrimary() && startYouTubeEmbedFallback(reason: "didFail") {
            return
        }
        hideLoadingOverlay()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        NSLog("%@", "[FloatVideo] Provisional page load failed: \(logSafeError(error))")
        refreshYouTubeEmbedFallbackURLIfNeeded()
        if shouldUseYouTubeFullPagePrimary() && startYouTubeEmbedFallback(reason: "didFailProvisional") {
            return
        }
        hideLoadingOverlay()
    }

    private func htmlEscaped(_ s: String) -> String {
        return s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func buildVideoHTML(videoSrc: String, currentTime: Double) -> String {
        return """
        <!DOCTYPE html>
        <html><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <style>
            * { margin: 0; padding: 0; }
            html, body { width: 100%; height: 100%; background: #000; overflow: hidden; }
            video {
                position: fixed; top: 0; left: 0;
                width: 100vw; height: 100vh;
                object-fit: cover;
                background: #000;
            }
        </style>
        </head><body>
        <video src="\(htmlEscaped(videoSrc))" autoplay playsinline></video>
        <script>
            const v = document.querySelector('video');
            v.currentTime = \(currentTime);
            v.addEventListener('dblclick', () => {
                if (document.fullscreenElement) {
                    document.exitFullscreen();
                } else {
                    v.requestFullscreen();
                }
            });
        </script>
        </body></html>
        """
    }

    private func buildEmbedHTML(embedUrl: String) -> String {
        return """
        <!DOCTYPE html>
        <html><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <style>
            * { margin: 0; padding: 0; }
            html, body { width: 100%; height: 100%; background: #000; overflow: hidden; }
            iframe {
                position: fixed; top: 0; left: 0;
                width: 100vw; height: 100vh;
                border: none;
            }
        </style>
        </head><body>
        <iframe src="\(htmlEscaped(embedUrl))"
                allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share"
                referrerpolicy="strict-origin-when-cross-origin"
                allowfullscreen>
        </iframe>
        </body></html>
        """
    }

    private func injectVideoMaximize(site: String, currentTime: Double) {
        // Thorough JS injection: recursively traverse DOM tree, hide all elements not in the video's ancestor chain
        let js = """
        (function() {
            const site = '\(site)';
            const initialTime = \(currentTime);

            function findMainVideo() {
                const cached = window.__floatVideoMainVideo;
                if (cached && cached.isConnected && (cached.currentSrc || cached.srcObject)) {
                    return cached;
                }

                const videos = [];
                function collectVideos(root) {
                    videos.push(...root.querySelectorAll('video'));
                    root.querySelectorAll('*').forEach(el => {
                        if (el.shadowRoot) collectVideos(el.shadowRoot);
                    });
                }
                collectVideos(document);

                // Skip videos without a source: VK Video's empty ad slot exists before the real player.
                let mainVideo = null;
                let maxArea = -1;
                videos.forEach(v => {
                    if (!v.currentSrc && !v.srcObject) return;
                    const rect = v.getBoundingClientRect();
                    const area = rect.width * rect.height;
                    if (area > maxArea) {
                        maxArea = area;
                        mainVideo = v;
                    }
                });
                if (mainVideo) window.__floatVideoMainVideo = mainVideo;
                return mainVideo;
            }

            function ensureFloatVideoStyle() {
                const styleId = '__floatvideo-style';
                let styleEl = document.getElementById(styleId);
                if (!styleEl) {
                    styleEl = document.createElement('style');
                    styleEl.id = styleId;
                    (document.head || document.documentElement).appendChild(styleEl);
                }

                const youtubeCss = site === 'youtube' ? `
                    ytd-app, ytd-watch-flexy, #page-manager, #content, #columns, #primary,
                    #primary-inner, #player, #player-container, #player-full-bleed-container,
                    #full-bleed-container, #movie_player, .html5-video-player,
                    .html5-video-container {
                        margin: 0 !important;
                        padding: 0 !important;
                        background: #000 !important;
                        transform: none !important;
                        filter: none !important;
                        transition: none !important;
                        overflow: hidden !important;
                    }
                    #secondary, #masthead-container, #below, #related, #chat,
                    .ytp-chrome-top, .ytp-chrome-bottom, .ytp-gradient-top,
                    .ytp-gradient-bottom, .ytp-ce-element, .ytp-pause-overlay,
                    .ytp-cards-teaser, .ytp-paid-content-overlay, [class*="ytp-ce-"] {
                        display: none !important;
                        visibility: hidden !important;
                        opacity: 0 !important;
                    }
                    /* Caption overlay: sibling of the <video>, so it must be
                       explicitly kept and painted ABOVE the fullscreen video
                       (same z-index, later in DOM order => on top). Our layout
                       forces the player to viewport size, so YouTube's own
                       caption-window positioning stays valid. */
                    .ytp-caption-window-container {
                        display: block !important;
                        visibility: visible !important;
                        opacity: 1 !important;
                        position: fixed !important;
                        left: 0 !important;
                        top: 0 !important;
                        width: 100vw !important;
                        height: 100vh !important;
                        z-index: 2147483647 !important;
                        pointer-events: none !important;
                        background: transparent !important;
                    }
                ` : '';

                styleEl.textContent = `
                    html, body {
                        margin: 0 !important;
                        padding: 0 !important;
                        overflow: hidden !important;
                        background: #000 !important;
                        width: 100% !important;
                        height: 100% !important;
                    }
                    .__floatvideo-ancestor {
                        display: block !important;
                        visibility: visible !important;
                        opacity: 1 !important;
                        position: static !important;
                        overflow: visible !important;
                        max-width: none !important;
                        max-height: none !important;
                        width: 100% !important;
                        height: 100% !important;
                        margin: 0 !important;
                        padding: 0 !important;
                        background: #000 !important;
                        transform: none !important;
                        filter: none !important;
                        transition: none !important;
                        /* contain: paint/strict makes the fixed video position against the ancestor (VK Video). */
                        contain: none !important;
                    }
                    video.__floatvideo-main-video {
                        position: fixed !important;
                        inset: 0 !important;
                        width: 100vw !important;
                        height: 100vh !important;
                        left: 0 !important;
                        top: 0 !important;
                        right: auto !important;
                        bottom: auto !important;
                        margin: 0 !important;
                        padding: 0 !important;
                        min-width: 0 !important;
                        min-height: 0 !important;
                        max-width: none !important;
                        max-height: none !important;
                        object-fit: contain !important;
                        object-position: center center !important;
                        transform: none !important;
                        background: #000 !important;
                        z-index: 2147483647 !important;
                    }
                    ${youtubeCss}
                `;
                return styleEl;
            }

            function hideNonAncestors(element, ancestors, mainVideo, shadowRoots) {
                if (!element) return;
                const root = shadowRoots.has(element.shadowRoot) ? element.shadowRoot : element;
                if (!root.children) return;
                Array.from(root.children).forEach(child => {
                    if (child === mainVideo) return;
                    if (ancestors.has(child)) {
                        child.style.setProperty('display', '', 'important');
                        child.style.setProperty('visibility', 'visible', 'important');
                        child.style.setProperty('opacity', '1', 'important');
                        child.style.setProperty('position', 'static', 'important');
                        child.style.setProperty('overflow', 'visible', 'important');
                        child.style.setProperty('max-height', 'none', 'important');
                        child.style.setProperty('max-width', 'none', 'important');
                        child.style.setProperty('width', '100%', 'important');
                        child.style.setProperty('height', '100%', 'important');
                        child.style.setProperty('margin', '0', 'important');
                        child.style.setProperty('padding', '0', 'important');
                        hideNonAncestors(child, ancestors, mainVideo, shadowRoots);
                    } else {
                        // Caption overlay DOM is a SIBLING of the <video>, not an
                        // ancestor — never hide it, or captions can't render.
                        // The youtubeCss block overlays it above the video.
                        var cls = (typeof child.className === 'string') ? child.className : '';
                        if (cls.indexOf('ytp-caption-window-container') >= 0 ||
                            cls.indexOf('caption-window') >= 0) {
                            return;
                        }
                        child.style.setProperty('display', 'none', 'important');
                    }
                });
            }

            function applyLayout() {
                if (window.__floatVideoApplyingLayout) return false;
                const mainVideo = findMainVideo();
                if (!mainVideo) return false;
                window.__floatVideoApplyingLayout = true;

                try {
                    const styleEl = ensureFloatVideoStyle();

                    (window.__floatVideoLayoutElements || []).forEach(el => {
                        el.classList.remove('__floatvideo-ancestor', '__floatvideo-main-video');
                    });

                    const ancestors = new Set();
                    const shadowRoots = new Set();
                    let current = mainVideo;
                    while (current) {
                        ancestors.add(current);
                        if (current.classList) {
                            current.classList.add('__floatvideo-ancestor');
                        }
                        const parent = current.parentNode;
                        if (parent instanceof ShadowRoot) shadowRoots.add(parent);
                        current = current.parentElement || (parent instanceof ShadowRoot ? parent.host : null);
                    }
                    window.__floatVideoLayoutElements = Array.from(ancestors);
                    shadowRoots.forEach(root => {
                        if (!root.getElementById('__floatvideo-style')) {
                            root.appendChild(styleEl.cloneNode(true));
                        }
                    });

                    document.documentElement.style.cssText = 'margin:0!important;padding:0!important;overflow:hidden!important;background:#000!important;width:100%!important;height:100%!important;';
                    document.body.style.cssText = 'margin:0!important;padding:0!important;overflow:hidden!important;background:#000!important;width:100%!important;height:100%!important;';

                    hideNonAncestors(document.body, ancestors, mainVideo, shadowRoots);

                    if (site === 'youtube') {
                        ancestors.forEach(el => {
                            if (el !== mainVideo) {
                                el.style.setProperty('transform', 'none', 'important');
                                el.style.setProperty('filter', 'none', 'important');
                                el.style.setProperty('transition', 'none', 'important');
                                el.style.setProperty('background', '#000', 'important');
                            }
                        });
                    }

                    mainVideo.classList.add('__floatvideo-main-video');
                    mainVideo.style.setProperty('position', 'fixed', 'important');
                    mainVideo.style.setProperty('inset', '0', 'important');
                    mainVideo.style.setProperty('width', '100vw', 'important');
                    mainVideo.style.setProperty('height', '100vh', 'important');
                    mainVideo.style.setProperty('left', '0', 'important');
                    mainVideo.style.setProperty('top', '0', 'important');
                    mainVideo.style.setProperty('object-fit', 'contain', 'important');
                    mainVideo.style.setProperty('object-position', 'center center', 'important');
                    mainVideo.style.setProperty('transform', 'none', 'important');
                    mainVideo.style.setProperty('margin', '0', 'important');
                    mainVideo.style.setProperty('padding', '0', 'important');
                    mainVideo.style.setProperty('background', '#000', 'important');
                    mainVideo.setAttribute('playsinline', '');

                    if (!window.__floatVideoInitialSeekDone && initialTime > 0) {
                        window.__floatVideoInitialSeekDone = true;
                        // VK Video's player stalls on a black frame if seeked while it is still starting.
                        const seekOncePlaying = () => {
                            if (site !== 'youtube' && mainVideo.currentTime <= 0) return;
                            mainVideo.removeEventListener('timeupdate', seekOncePlaying);
                            try {
                                mainVideo.currentTime = initialTime;
                            } catch (e) {}
                        };
                        mainVideo.addEventListener('timeupdate', seekOncePlaying);
                        seekOncePlaying();
                    }

                    mainVideo.play().catch(() => {});
                    // The native control bar replaces WebKit's, which would overlap it.
                    mainVideo.controls = false;
                    window.__floatVideoMainVideo = mainVideo;
                    return true;
                } finally {
                    window.__floatVideoApplyingLayout = false;
                }
            }

            window.__floatVideoApplyLayout = applyLayout;

            if (!window.__floatVideoResizeHookInstalled) {
                window.__floatVideoResizeHookInstalled = true;
                let delayedLayoutPass = null;
                window.addEventListener('resize', () => {
                    if (delayedLayoutPass) {
                        clearTimeout(delayedLayoutPass);
                    }
                    delayedLayoutPass = setTimeout(() => {
                        if (window.__floatVideoApplyLayout) {
                            window.__floatVideoApplyLayout();
                        }
                    }, 0);
                    setTimeout(() => {
                        if (window.__floatVideoApplyLayout) {
                            window.__floatVideoApplyLayout();
                        }
                    }, 120);
                });
            }

            return applyLayout();
        })();
        """
        webView.evaluateJavaScript(js) { [weak self] result, err in
            if let err = err {
                NSLog("%@", "[FloatVideo] JS injection error: \(logSafeError(err))")
            } else if let found = result as? Bool, found {
                self?.hasInjectedJS = true
                self?.youtubeFallbackWorkItem?.cancel()
                self?.youtubeFallbackWorkItem = nil
                self?.hideLoadingOverlay()
            }
        }
    }

    /// Installs a self-contained, idempotent in-page guard that auto-clicks
    /// YouTube's "Skip Ad" button the instant it becomes available.
    ///
    /// Why this is needed: the full-page isolation injection (`injectVideoMaximize`)
    /// hides every element that isn't an ancestor of the <video>, which includes
    /// YouTube's ad container and the Skip button it creates ~15s into an ad. The
    /// button still exists in the DOM, so `HTMLElement.click()` fires its handler
    /// even while it is `display:none` — no CSS/z-index/layout changes required.
    ///
    /// Limitation: this only reaches the same-origin YouTube watch page loaded via
    /// the `.fullPageInject` primary path. The cross-origin IFrame-API fallback
    /// (LocalHTTPServer) hosts YouTube in an <iframe> whose ad DOM is unreachable,
    /// so auto-skip does not apply there.
    private func injectAdSkip() {
        let js = """
        (function() {
            if (window.__floatVideoAdSkipInstalled) return 'already';
            window.__floatVideoAdSkipInstalled = true;
            window.__floatVideoAdSkipCount = window.__floatVideoAdSkipCount || 0;
            window.__floatVideoAdFFCount = window.__floatVideoAdFFCount || 0;

            // Covers old + modern YouTube ad-skip markup.
            var SKIP_SELECTORS = [
                '.ytp-ad-skip-button-modern',
                '.ytp-ad-skip-button',
                '.ytp-skip-ad-button',
                '.ytp-skip-ad button',
                '.ytp-ad-skip-button-slot button',
                '.ytp-ad-skip-button-container button'
            ];

            function findSkipButton() {
                for (var i = 0; i < SKIP_SELECTORS.length; i++) {
                    var el = document.querySelector(SKIP_SELECTORS[i]);
                    if (!el) continue;
                    // Only click a genuinely enabled skip control. YouTube only
                    // inserts the real button once skipping is allowed, but guard
                    // against disabled/aria-disabled states just in case.
                    if (el.disabled) continue;
                    if (el.getAttribute('aria-disabled') === 'true') continue;
                    return el;
                }
                return null;
            }

            // --- Trusted-click support -----------------------------------
            // YouTube now ignores untrusted (JS-synthesized) clicks on the
            // skip button, so the actual press is performed by the native app
            // as a real mouse event. To make that possible the button must be
            // renderable and hit-testable: reveal its ancestor chain (siblings
            // stay hidden — they carry their own inline display:none), keep
            // the button itself at 2% opacity so nothing is visible over the
            // video, then publish its center point for the Swift side, which
            // consumes it via the state poll and posts real mouse events.
            var revealed = [];

            function prepareForTrustedClick(btn) {
                try {
                    var node = btn;
                    while (node && node !== document.body) {
                        // The chain shared with the <video> is already visible
                        // and must keep receiving pointer events — skip it.
                        if (node.classList && node.classList.contains('__floatvideo-ancestor')) {
                            node = node.parentElement;
                            continue;
                        }
                        node.style.setProperty('display', 'block', 'important');
                        node.style.setProperty('visibility', 'visible', 'important');
                        if (node === btn) {
                            node.style.setProperty('opacity', '0.02', 'important');
                            node.style.setProperty('pointer-events', 'auto', 'important');
                            node.style.setProperty('position', 'relative', 'important');
                            node.style.setProperty('z-index', '2147483647', 'important');
                        } else {
                            node.style.setProperty('pointer-events', 'none', 'important');
                        }
                        if (revealed.indexOf(node) < 0) revealed.push(node);
                        node = node.parentElement;
                    }
                    var r = btn.getBoundingClientRect();
                    if (!r || r.width < 2 || r.height < 2) return null;
                    var x = r.left + r.width / 2;
                    var y = r.top + r.height / 2;
                    if (x < 1 || y < 1 || x > window.innerWidth - 1 || y > window.innerHeight - 1) return null;
                    return { x: x, y: y };
                } catch (e) { return null; }
            }

            function restoreRevealed() {
                while (revealed.length) {
                    var n = revealed.pop();
                    try {
                        n.style.setProperty('display', 'none', 'important');
                        n.style.removeProperty('pointer-events');
                        n.style.removeProperty('z-index');
                    } catch (e) {}
                }
                window.__floatVideoPendingTrustedClick = null;
            }

            // Per-ad-break state machine. Clicking Skip too early (before a real
            // user ever could, ~5s) makes YouTube's ad server treat the ad as
            // improperly delivered and RE-SERVE it — observed as the same break
            // looping 6-7 ads of 1-2s each. Strategy: instance 1 in a break keeps
            // the instant skip (most ads tolerate it); each detected re-serve
            // backs the next click off progressively past human timing.
            var lastAdT = 0;          // ad video currentTime last tick
            var instanceCount = 0;    // ad instances in the current logical break
            var clicks = 0;           // clicks for the current instance (max 3)
            var lastClickAt = 0;
            var ffDone = false;
            var coolOffUntil = 0;     // break-level circuit breaker
            var lastCoolInstance = 0; // instance that last triggered a cool-off
            var adGoneTicks = 0;      // consecutive ticks with no ad showing

            function resetInstance() {
                clicks = 0;
                lastClickAt = 0;
                ffDone = false;
            }

            window.__floatVideoAdSkipTimer = setInterval(function() {
                var player = document.querySelector('#movie_player, .html5-video-player');
                var adShowing = !!(player && (player.classList.contains('ad-showing') ||
                                              player.classList.contains('ad-interrupting')));
                if (!adShowing) {
                    restoreRevealed();
                    // Between re-serves YouTube drops out of ad state for a few
                    // hundred ms (observed in logs), so only treat the break as
                    // over after 3s without an ad. Real content stretches are
                    // minutes long; a re-serve gap never is.
                    if (++adGoneTicks >= 6 && instanceCount > 0) {
                        instanceCount = 0;
                        lastAdT = 0;
                        coolOffUntil = 0;
                        lastCoolInstance = 0;
                        resetInstance();
                    }
                    return;
                }
                var gapTicks = adGoneTicks;
                adGoneTicks = 0;

                var v = player.querySelector('video') || document.querySelector('video');
                if (!v) return;

                // New ad instance: break just started, ad state came back after
                // a short gap (re-serve), or the ad video's clock jumped
                // backwards (pod advance within continuous ad state).
                if (instanceCount === 0 || gapTicks > 0 || v.currentTime < lastAdT - 1.0) {
                    restoreRevealed();
                    instanceCount++;
                    resetInstance();
                }
                lastAdT = v.currentTime;

                var now = Date.now();
                if (now < coolOffUntil) return;
                if (instanceCount >= 5 && instanceCount > lastCoolInstance) {
                    // Pathological re-serve loop: pause once per new instance and
                    // let the ad play legitimately for a while before retrying,
                    // instead of locking out (or hammering) for the whole break.
                    lastCoolInstance = instanceCount;
                    coolOffUntil = now + 20000;
                    return;
                }

                // Instance 1: click immediately. Re-served instances: wait 5.2s,
                // 9.2s, 13.2s into the ad — walks past longer skip-offsets
                // (e.g. 15s campaigns) instead of re-triggering the loop.
                var minAdTime = (instanceCount === 1)
                    ? 0
                    : Math.min(5.2 + 4.0 * (instanceCount - 2), 30);
                if (v.currentTime < minAdTime) return;

                var btn = findSkipButton();
                if (!btn) return; // unskippable or button not yet inserted

                if (clicks < 3) {
                    if (now - lastClickAt < 2000) return;
                    // Free first shot: some player builds expose an internal
                    // skipAd(); harmless no-op elsewhere.
                    try { if (typeof player.skipAd === 'function') player.skipAd(); } catch (e) {}
                    var pt = prepareForTrustedClick(btn);
                    if (pt) {
                        // Native side consumes this via the state poll and posts
                        // a real (trusted) mouse click at these page coordinates.
                        window.__floatVideoPendingTrustedClick = { x: pt.x, y: pt.y, ts: now };
                    } else {
                        // Could not obtain a hit-testable rect — fall back to the
                        // untrusted click (better than nothing).
                        btn.click();
                    }
                    lastClickAt = now;
                    if (++clicks === 1) window.__floatVideoAdSkipCount++;
                } else if (!ffDone && now - lastClickAt >= 2000) {
                    // 3 clicks ignored. Only for SKIPPABLE ads (button present):
                    // jump to just before the end and let 'ended' fire naturally,
                    // which the ad pipeline credits as a completion far more
                    // reliably than a hard seek to duration (fewer re-serves).
                    // Main content is never touched (adShowing gate).
                    if (isFinite(v.duration) && v.duration > 0.5) {
                        restoreRevealed();
                        v.currentTime = Math.max(0, v.duration - 0.15);
                        window.__floatVideoAdFFCount++;
                        ffDone = true;
                    }
                }
            }, 500);

            return 'installed';
        })();
        """
        webView.evaluateJavaScript(js) { [weak self] result, err in
            if let err = err {
                NSLog("%@", "[FloatVideo] Ad-skip guard injection error: \(logSafeError(err))")
            } else {
                self?.hasInjectedAdSkip = true
                // Only log fresh installs; the poll-driven self-heal re-invokes
                // this until the flag is visible, which would otherwise spam.
                if (result as? String) == "installed" {
                    NSLog("[FloatVideo] Ad-skip guard installed")
                }
            }
        }
    }

    /// Posts a real mouse down/up pair at the given page coordinates (CSS px,
    /// top-left origin) inside the WKWebView. Real AppKit events produce
    /// TRUSTED DOM events in WebKit — required because YouTube now ignores
    /// untrusted (JS-synthesized) clicks on the ad Skip button.
    private func performTrustedClick(pageX: Double, pageY: Double) {
        let bounds = webView.bounds
        guard pageX >= 1, pageY >= 1,
              pageX <= Double(bounds.width) - 1,
              pageY <= Double(bounds.height) - 1 else { return }

        // Page Y grows downward; AppKit view coordinates grow upward.
        let viewPoint = NSPoint(x: pageX, y: bounds.height - CGFloat(pageY))

        // Never click through our own overlay UI; the guard retries in <=2s,
        // by which time the hover bars are usually hidden again.
        if let container = webView.superview {
            let containerPoint = webView.convert(viewPoint, to: container)
            if titleBarView.alphaValue > 0.01, titleBarView.frame.contains(containerPoint) { return }
            if controlBarView.alphaValue > 0.01, controlBarView.frame.contains(containerPoint) { return }
        }

        let windowPoint = webView.convert(viewPoint, to: nil)
        let time = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: windowPoint,
                                            modifierFlags: [], timestamp: time,
                                            windowNumber: windowNumber, context: nil,
                                            eventNumber: 0, clickCount: 1, pressure: 1),
              let up = NSEvent.mouseEvent(with: .leftMouseUp, location: windowPoint,
                                          modifierFlags: [], timestamp: time + 0.05,
                                          windowNumber: windowNumber, context: nil,
                                          eventNumber: 0, clickCount: 1, pressure: 1) else { return }

        isPostingSyntheticClick = true
        sendEvent(down)
        sendEvent(up)
        isPostingSyntheticClick = false
        NSLog("[FloatVideo] Trusted click at page (\(Int(pageX)), \(Int(pageY)))")
    }

    // MARK: - Window Actions

    func show() {
        // Show title bar during loading (user can see title and close button)
        titleBarView.alphaValue = 1.0
        self.orderFrontRegardless()
        self.makeKeyAndOrderFront(nil)
        // Start cursor-position polling for reliable auto-hide (event-based
        // approaches fail on non-activating panels and under WKWebView).
        startCursorPolling()
        // Safety: hide loading overlay after 8s regardless
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { [weak self] in
            self?.hideLoadingOverlay()
        }
    }

    private func startCursorPolling() {
        cursorPollTimer?.invalidate()
        cursorPollTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.pollCursorPosition()
        }
    }

    private func pollCursorPosition() {
        let cursor = NSEvent.mouseLocation
        let inside = self.frame.contains(cursor)

        if isResizing {
            // Keep controls visible during resize; no hide scheduling.
            if !isHovering { showControls() }
            hideTimer?.cancel()
            hideTimer = nil
            cursorWasInside = inside
            return
        }

        if inside && !cursorWasInside {
            cursorWasInside = true
            hideTimer?.cancel()
            hideTimer = nil
            if !isHovering { showControls() }
        } else if !inside && cursorWasInside {
            cursorWasInside = false
            if isHovering { scheduleHideControls() }
        }
    }

    private func hideLoadingOverlay() {
        guard let overlay = loadingOverlay else { return }
        // Resume media playback and trigger autoplay
        webView.setAllMediaPlaybackSuspended(false) { [weak self] in
            self?.triggerPlayback()
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            overlay.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.loadingOverlay?.removeFromSuperview()
            self?.loadingOverlay = nil
            self?.startUpdateTimer()
            // After loading completes, hide title bar if mouse is not inside the window
            if !(self?.isHovering ?? false) {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.3
                    self?.titleBarView.animator().alphaValue = 0
                })
            }
        })
    }

    private func triggerPlayback() {
        // Trigger playback for all video elements + trigger YouTube iframe playback via postMessage.
        // Also assert the user's mute intent — WKWebView's autoplay policy will often force
        // audio off without an explicit unmute, and YouTube re-mutes around ad transitions.
        let wantMute = userWantsMute
        let mutedJSBool = wantMute ? "true" : "false"
        let ytMuteCmd = wantMute ? "'mute'" : "'unmute'"
        let js = """
        (function() {
            var videos = Array.from(document.querySelectorAll('video'));
            var mainVideo = \(Self.mainVideoJS);
            if (mainVideo && !videos.includes(mainVideo)) videos.push(mainVideo);
            videos.forEach(v => {
                v.muted = \(mutedJSBool);
                if (!\(mutedJSBool)) v.volume = 1.0;
                v.play().catch(() => {});
            });
            if (window.playerCommand) {
                window.playerCommand(\(ytMuteCmd));
                if (!\(mutedJSBool)) window.playerCommand('volume', 1.0);
                window.playerCommand('play');
            }
            var iframe = document.querySelector('iframe');
            if (iframe) {
                iframe.contentWindow.postMessage(JSON.stringify({event:'command',func:'playVideo',args:[]}), '*');
            }
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
        // Delayed retry (YouTube iframe may not be ready yet)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    @objc func closeWindow() {
        cursorPollTimer?.invalidate()
        cursorPollTimer = nil
        resetYouTubeFallbackState()
        reinjectLayoutWorkItem?.cancel()
        reinjectLayoutWorkItem = nil
        stopUpdateTimer()
        saveWindowFrame()
        onClose?()
        self.close()
    }

    // MARK: - Hover Controls

    private func showControls() {
        hideTimer?.cancel()
        guard !isHovering else { return }
        isHovering = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            titleBarView.animator().alphaValue = 1.0
            controlBarView.animator().alphaValue = 1.0
        })
    }

    private func scheduleHideControls() {
        hideTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.hideControls()
        }
        hideTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func hideControls() {
        guard isHovering else { return }
        if isResizing {
            // Can't hide during resize; reschedule so controls hide once resize ends
            scheduleHideControls()
            return
        }
        isHovering = false
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            titleBarView.animator().alphaValue = 0
            controlBarView.animator().alphaValue = 0
        })
    }

    private func makeControlButton(x: CGFloat, symbolName: String, action: Selector) -> NSButton {
        let btn = NSButton(frame: NSRect(x: x, y: 6, width: 28, height: 28))
        btn.isBordered = false
        btn.wantsLayer = true
        btn.layer?.backgroundColor = NSColor.clear.cgColor
        btn.contentTintColor = .white
        btn.target = self
        btn.action = action
        if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            btn.image = img.withSymbolConfiguration(config)
            btn.title = ""
            btn.imagePosition = .imageOnly
        } else {
            btn.title = symbolName
            btn.font = NSFont.systemFont(ofSize: 14)
        }
        return btn
    }

    private func setButtonSymbol(_ btn: NSButton, _ symbolName: String) {
        if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            btn.image = img.withSymbolConfiguration(config)
            btn.title = ""
        } else {
            btn.title = symbolName
        }
    }

    private static let mainVideoJS = "(window.__floatVideoMainVideo && window.__floatVideoMainVideo.isConnected ? window.__floatVideoMainVideo : document.querySelector('video'))"

    private func videoJS(_ directJS: String, youtubeCmd: String? = nil) {
        var js = "(function() { var v = \(Self.mainVideoJS); if(v) { \(directJS) }"
        if let cmd = youtubeCmd {
            js += " else if(window.playerCommand) { \(cmd) }"
        }
        js += " })();"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    @objc func togglePlayPause() {
        if isPlaying {
            videoJS("v.pause()", youtubeCmd: "playerCommand('pause')")
        } else {
            videoJS("v.play().catch(()=>{})", youtubeCmd: "playerCommand('play')")
        }
        isPlaying.toggle()
        setButtonSymbol(playPauseButton, isPlaying ? "pause.fill" : "play.fill")
    }

    @objc func skipForward() {
        videoJS("v.currentTime += 10",
                youtubeCmd: "playerCommand('seek', (window.getPlayerState()?.ct||0)+10)")
    }

    @objc func toggleMute() {
        userWantsMute.toggle()
        if userWantsMute {
            videoJS("v.muted = true", youtubeCmd: "playerCommand('mute')")
            setButtonSymbol(volumeButton, "speaker.slash.fill")
            volumeSlider.doubleValue = 0
        } else {
            videoJS("v.muted = false; v.volume = 1.0",
                    youtubeCmd: "playerCommand('unmute'); playerCommand('volume', 1.0)")
            setButtonSymbol(volumeButton, "speaker.wave.2.fill")
            volumeSlider.doubleValue = 1.0
        }
    }

    @objc func volumeChanged(_ sender: NSSlider) {
        let vol = sender.doubleValue
        let muted = vol == 0
        videoJS("v.volume = \(vol); v.muted = \(muted)",
                youtubeCmd: "playerCommand('volume', \(vol)); playerCommand(\(muted ? "'mute'" : "'unmute'"))")
        userWantsMute = muted
        setButtonSymbol(volumeButton, userWantsMute ? "speaker.slash.fill" : "speaker.wave.2.fill")
    }

    private func seekTo(percent: Double) {
        let js = """
        (function() {
            var v = \(Self.mainVideoJS);
            if (v && v.duration) { v.currentTime = v.duration * \(percent); }
            else if (window.getPlayerState && window.playerCommand) {
                var s = window.getPlayerState();
                if (s) playerCommand('seek', s.dur * \(percent));
            }
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - Audio Track & Subtitle Menu

    /// In-page helper behind the track menu and the float-time prefs sync.
    /// Called as `(source)(request)`; re-evaluated on every use because a full
    /// in-page navigation wipes the JS world. Actions:
    /// - `query`: lists playback rates, YouTube qualities, audio tracks,
    ///   caption tracks and auto-translate languages with the current selection.
    /// - `select`: applies a menu pick ({type: rate|quality|audio|captions|translate, id}).
    /// - `sync`: applies the Chrome tab's captured state; returns the status
    ///   protocol of `attemptApplyPlayerPrefs` (done/retry/ad/applied).
    /// YouTube goes through the #movie_player API; other sites fall back to the
    /// main <video>'s HTML5 audioTracks/textTracks.
    private static let mediaTracksJS = """
    (function(req) {
        var p = document.getElementById('movie_player') || document.querySelector('.html5-video-player');
        var yt = !!(p && typeof p.getAvailableAudioTracks === 'function' && typeof p.getOption === 'function');
        var video = \(mainVideoJS);

        function inAd() {
            return !!(p && p.classList && (p.classList.contains('ad-showing') || p.classList.contains('ad-interrupting')));
        }

        // ---- YouTube audio tracks (dubbed videos) ----
        function audioInfo(t) {
            try { return (t && typeof t.getLanguageInfo === 'function') ? t.getLanguageInfo() : null; } catch (e) { return null; }
        }
        function audioTracks() {
            try { return p.getAvailableAudioTracks() || []; } catch (e) { return []; }
        }
        function currentAudioId() {
            var li = null;
            try { li = audioInfo(p.getAudioTrack()); } catch (e) {}
            return (li && li.id) || '';
        }
        function findAudio(id, sameLanguageOk) {
            var tracks = audioTracks(), i, li;
            for (i = 0; i < tracks.length; i++) {
                li = audioInfo(tracks[i]);
                if (li && li.id === id) return tracks[i];
            }
            if (!sameLanguageOk) return null;
            // Ids are "<lang>.<variant>" (e.g. zh-Hant.4 original, en-US.10
            // auto-dubbed); fall back to the same language.
            var lang = String(id).split('.')[0];
            for (i = 0; i < tracks.length; i++) {
                li = audioInfo(tracks[i]);
                if (li && String(li.id).split('.')[0] === lang) return tracks[i];
            }
            return null;
        }

        // ---- YouTube captions ----
        function captionKey(c) {
            return c.vss_id || c.vssId || ((c.languageCode || '') + '|' + (c.kind || ''));
        }
        function captionList() {
            var list = null;
            // includeAsr: without it auto-generated tracks are left out and
            // ASR-only videos look like they have no captions at all.
            try { list = p.getOption('captions', 'tracklist', { includeAsr: true }); } catch (e) {}
            if (list && list.length) return list;
            // Captions module not loaded (CC off since page load): the active
            // audio track carries the same list.
            try {
                var at = p.getAudioTrack();
                return ((at && at.captionTracks) || []).map(function(c) {
                    return { languageCode: c.languageCode, languageName: c.languageName,
                             displayName: c.displayName, kind: c.kind, vss_id: c.vssId,
                             is_translateable: c.isTranslateable };
                });
            } catch (e) { return []; }
        }
        function currentCaption() {
            try {
                var t = p.getOption('captions', 'track');
                return (t && t.languageCode) ? t : null;
            } catch (e) { return null; }
        }
        function translationLanguages() {
            var list = null;
            try { list = p.getOption('captions', 'translationLanguages'); } catch (e) {}
            if (list && list.length) return list;
            try {
                var r = p.getPlayerResponse().captions.playerCaptionsTracklistRenderer;
                return (r.translationLanguages || []).map(function(l) {
                    var n = l.languageName || {};
                    return { languageCode: l.languageCode,
                             languageName: n.simpleText || (n.runs || []).map(function(x) { return x.text; }).join('') };
                });
            } catch (e) { return []; }
        }
        function findCaption(list, want) {
            var i, key = captionKey(want);
            for (i = 0; i < list.length; i++) if (captionKey(list[i]) === key) return list[i];
            for (i = 0; i < list.length; i++) {
                if (list[i].languageCode === want.languageCode && (list[i].kind || '') === (want.kind || '')) return list[i];
            }
            for (i = 0; i < list.length; i++) if (list[i].languageCode === want.languageCode) return list[i];
            return null;
        }
        function isTranslatable(c) { return !!(c.is_translateable || c.isTranslateable); }
        function qualityInfo() {
            try {
                var cur = p.getPlaybackQuality(), label = '';
                var list = p.getAvailableQualityData().filter(function(d) { return d.isPlayable; }).map(function(d) {
                    if (d.quality === cur) label = d.qualityLabel;
                    return { id: d.quality, label: d.qualityLabel };
                });
                return { qualities: list, quality: p.getPreferredQuality(), qualityLabel: label };
            } catch (e) { return { qualities: [] }; }
        }
        function translationCode(t) {
            return (t && t.translationLanguage && t.translationLanguage.languageCode) || '';
        }
        function captionMatches(want) {
            var cur = currentCaption();
            if (!want) return !cur;
            return !!cur && cur.languageCode === want.languageCode && translationCode(cur) === translationCode(want);
        }
        // want: null turns CC off; otherwise a track (from the list, or a
        // captured {languageCode, kind, vssId}) plus optional translationLanguage.
        function setCaption(want) {
            if (!want) { p.setOption('captions', 'track', {}); return; }
            // The captions module may be unloaded when CC starts off.
            try { if (typeof p.loadModule === 'function') p.loadModule('captions'); } catch (e) {}
            var base = findCaption(captionList(), want), track = {}, k;
            if (base) {
                for (k in base) if (k !== 'translationLanguage') track[k] = base[k];
            } else {
                track.languageCode = want.languageCode;
                if (want.kind) track.kind = want.kind;
            }
            var tl = translationCode(want);
            if (tl) {
                var langs = translationLanguages(), name = '';
                for (var i = 0; i < langs.length; i++) if (langs[i].languageCode === tl) name = langs[i].languageName;
                track.translationLanguage = name ? { languageCode: tl, languageName: name } : { languageCode: tl };
            }
            p.setOption('captions', 'track', track);
        }
        // Re-checks a pick a few times: setOption silently no-ops while the
        // captions module is mid-initialization, and an audio switch can make
        // YouTube re-pick captions from the new track's defaults.
        function settle(check, apply) {
            [700, 2000, 4500].forEach(function(ms) {
                setTimeout(function() {
                    if (inAd() || check()) return;
                    try { apply(); } catch (e) {}
                }, ms);
            });
        }

        if (req.action === 'query') {
            if (p) {
                if (!yt) return { source: 'youtube', loading: true };
                if (inAd()) return { source: 'youtube', ad: true };
                var curAudio = currentAudioId();
                var audio = audioTracks().map(function(t) {
                    var li = audioInfo(t) || {};
                    return { id: String(li.id || ''), label: String(li.name || li.id || ''),
                             autoDubbed: !!li.isAutoDubbed, selected: !!li.id && li.id === curAudio };
                }).filter(function(a) { return a.id; });
                var cur = currentCaption(), list = captionList();
                var selected = cur ? findCaption(list, cur) : null;
                var captions = list.map(function(c) {
                    return { id: captionKey(c), label: String(c.displayName || c.languageName || c.languageCode || ''),
                             selected: c === selected };
                });
                var q = qualityInfo();
                return {
                    source: 'youtube', audio: audio, captions: captions, captionsOn: !!cur,
                    translation: translationCode(cur),
                    translationLanguages: list.some(isTranslatable) ? translationLanguages().map(function(l) {
                        return { id: l.languageCode, label: l.languageName || l.languageCode };
                    }) : [],
                    rate: p.getPlaybackRate(), rates: p.getAvailablePlaybackRates(),
                    qualities: q.qualities, quality: q.quality, qualityLabel: q.qualityLabel
                };
            }
            if (video) {
                var out = { source: 'html5', audio: [], captions: [], captionsOn: false,
                            rate: video.playbackRate, rates: [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2] };
                var ats = video.audioTracks, tts = video.textTracks, n, t;
                for (n = 0; ats && n < ats.length; n++) {
                    t = ats[n];
                    out.audio.push({ id: String(n), label: t.label || t.language || ('Track ' + (n + 1)), selected: !!t.enabled });
                }
                for (n = 0; tts && n < tts.length; n++) {
                    t = tts[n];
                    if (t.kind !== 'subtitles' && t.kind !== 'captions') continue;
                    out.captions.push({ id: String(n), label: t.label || t.language || ('Track ' + (n + 1)), selected: t.mode === 'showing' });
                    if (t.mode === 'showing') out.captionsOn = true;
                }
                return out;
            }
            return { source: 'none' };
        }

        if (req.action === 'select') {
            if (yt) {
                if (inAd()) return 'ad';
                // A manual pick ends the float-time sync from the Chrome tab.
                window.__floatVideoPrefsApplied = true;
                if (req.type === 'rate' || req.type === 'quality') {
                    try {
                        if (req.type === 'rate') p.setPlaybackRate(Number(req.id));
                        else p.setPlaybackQualityRange(req.id, req.id);
                    } catch (e) { return 'error'; }
                    return 'ok';
                }
                if (req.type === 'audio') {
                    var target = findAudio(req.id, false);
                    if (!target) return 'missing';
                    var keep = currentCaption();
                    try { p.setAudioTrack(target); } catch (e) { return 'error'; }
                    settle(function() { return captionMatches(keep); }, function() { setCaption(keep); });
                    return 'ok';
                }
                var want = null, tracks = captionList(), j;
                if (req.type === 'captions' && req.id) {
                    for (j = 0; j < tracks.length; j++) if (captionKey(tracks[j]) === req.id) want = tracks[j];
                    if (!want) return 'missing';
                } else if (req.type === 'translate') {
                    var from = currentCaption();
                    from = from ? (findCaption(tracks, from) || from) : null;
                    if (!from) {
                        // CC off: translate from the spoken language's track
                        // (human-made over auto-generated), else any human one.
                        var src = tracks.filter(isTranslatable);
                        var spoken = currentAudioId().split('.')[0].split('-')[0];
                        var sameLang = src.filter(function(c) { return String(c.languageCode).split('-')[0] === spoken; });
                        from = sameLang.filter(function(c) { return c.kind !== 'asr'; })[0] || sameLang[0] ||
                               src.filter(function(c) { return c.kind !== 'asr'; })[0] || src[0];
                    }
                    if (!from) return 'missing';
                    want = {};
                    for (var key in from) if (key !== 'translationLanguage') want[key] = from[key];
                    want.translationLanguage = { languageCode: req.id };
                }
                setCaption(want);
                settle(function() { return captionMatches(want); }, function() { setCaption(want); });
                return captionMatches(want) ? 'ok' : 'pending';
            }
            if (video && req.type === 'rate') {
                video.playbackRate = Number(req.id);
                return 'ok';
            }
            if (video && req.type === 'audio' && video.audioTracks) {
                for (var a = 0; a < video.audioTracks.length; a++) video.audioTracks[a].enabled = String(a) === req.id;
                return 'ok';
            }
            if (video && req.type === 'captions' && video.textTracks) {
                for (var c = 0; c < video.textTracks.length; c++) {
                    var tt = video.textTracks[c];
                    if (tt.kind === 'subtitles' || tt.kind === 'captions') tt.mode = String(c) === req.id ? 'showing' : 'disabled';
                }
                return 'ok';
            }
            return 'unsupported';
        }

        if (req.action === 'sync') {
            if (window.__floatVideoPrefsApplied) return 'done';
            if (!p) return 'retry';
            // While an ad plays, the player exposes the ad's tracks — applying
            // now would misfire. Report distinctly so the native side keeps
            // waiting without burning the deadline.
            if (inAd()) { window.__floatVideoSyncStable = 0; return 'ad'; }
            var s = req.prefs || {};
            if (s.rate > 0 && s.rate !== 1 && typeof p.setPlaybackRate === 'function') {
                try { p.setPlaybackRate(s.rate); } catch (e) {}
            }
            if (!yt) return 'retry';
            // Only act during real playback: while the player is still
            // starting up it re-picks its own audio track and captions,
            // silently reverting anything applied earlier.
            var state = -1;
            try { state = p.getPlayerState(); } catch (e) {}
            if (state !== 1) return 'retry';
            var dirty = false;
            // Audio first: each audio track carries its own caption list.
            if (s.audioId) {
                var audioTarget = findAudio(s.audioId, true);
                window.__floatVideoAudioSyncTries = window.__floatVideoAudioSyncTries || 0;
                if (audioTarget && currentAudioId() !== audioInfo(audioTarget).id &&
                    window.__floatVideoAudioSyncTries < 3) {
                    window.__floatVideoAudioSyncTries++;
                    try { p.setAudioTrack(audioTarget); } catch (e) {}
                    window.__floatVideoSyncStable = 0;
                    return 'retry'; // captions next tick, once the switch settles
                }
            }
            if (s.captionTrack) {
                if (!captionMatches(s.captionTrack)) {
                    try { setCaption(s.captionTrack); } catch (e) {}
                    dirty = true;
                }
            } else if (s.captionsOff && currentCaption()) {
                try { p.setOption('captions', 'track', {}); } catch (e) {}
                dirty = true;
            }
            // YouTube may also flip CC on by itself a few seconds into playback
            // (sticky language, "recommended" initial state), so only call it
            // done once the whole state has held for a few ticks.
            window.__floatVideoSyncStable = dirty ? 0 : (window.__floatVideoSyncStable || 0) + 1;
            if (window.__floatVideoSyncStable < 4) return 'retry';
            window.__floatVideoPrefsApplied = true;
            return 'applied';
        }
        return null;
    })
    """

    private func runMediaTracksJS(_ request: [String: Any], completion: ((Any?) -> Void)? = nil) {
        guard let data = try? JSONSerialization.data(withJSONObject: request) else { return }
        let js = "\(Self.mediaTracksJS)(JSON.parse(atob('\(data.base64EncodedString())')))"
        webView.evaluateJavaScript(js) { result, error in
            if let error = error {
                NSLog("%@", "[FloatVideo] Media tracks JS error: \(logSafeError(error))")
            }
            completion?(result)
        }
    }

    @objc private func showTrackMenu(_ sender: NSButton) {
        // Tracks are read fresh on every open: they change with the video,
        // with ads, and (captions) with the selected audio track.
        runMediaTracksJS(["action": "query"]) { [weak self] result in
            guard let self = self else { return }
            let menu = self.buildTrackMenu(result as? [String: Any] ?? [:])
            self.popUpTrackMenu(menu, from: sender)
        }
    }

    private func buildTrackMenu(_ info: [String: Any]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let source = info["source"] as? String ?? "none"
        let notice: String?
        if info["loading"] as? Bool == true {
            notice = "Player is still loading…"
        } else if info["ad"] as? Bool == true {
            notice = "Available after the ad"
        } else if source == "none" {
            notice = "No video found"
        } else {
            notice = nil
        }
        if let notice = notice {
            let item = NSMenuItem(title: notice, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return menu
        }

        let rate = (info["rate"] as? NSNumber)?.doubleValue ?? 1
        let rates = (info["rates"] as? [NSNumber] ?? []).map { $0.doubleValue }
        addTrackSection(to: menu, title: "Speed", items: rates.map { r in
            trackMenuItem(r == 1 ? "Normal" : String(format: "%gx", r), selected: abs(r - rate) < 0.01,
                          request: ["type": "rate", "id": String(r)])
        }, collapse: true)

        let qualities = info["qualities"] as? [[String: Any]] ?? []
        if !qualities.isEmpty {
            let preferred = info["quality"] as? String ?? "auto"
            let currentLabel = info["qualityLabel"] as? String ?? ""
            let auto = trackMenuItem(currentLabel.isEmpty ? "Auto" : "Auto (\(currentLabel))",
                                     selected: preferred == "auto", request: ["type": "quality", "id": "auto"])
            addTrackSection(to: menu, title: "Quality", items: [auto] + qualities.map { q in
                let id = q["id"] as? String ?? ""
                return trackMenuItem(q["label"] as? String ?? id, selected: id == preferred,
                                     request: ["type": "quality", "id": id])
            }, collapse: true)
        }

        let audioInfo = info["audio"] as? [[String: Any]] ?? []
        let captionInfo = info["captions"] as? [[String: Any]] ?? []
        guard source == "youtube" || audioInfo.count > 1 || !captionInfo.isEmpty else { return menu }
        menu.addItem(.separator())

        let audio = audioInfo.map { track -> NSMenuItem in
            var label = track["label"] as? String ?? ""
            if track["autoDubbed"] as? Bool == true, label.range(of: "dub", options: .caseInsensitive) == nil {
                label += " (auto-dubbed)"
            }
            return trackMenuItem(label, selected: track["selected"] as? Bool == true,
                                 request: ["type": "audio", "id": track["id"] as? String ?? ""])
        }
        if audio.isEmpty {
            let item = NSMenuItem(title: "Default", action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.state = .on
            addTrackSection(to: menu, title: "Audio Track", items: [item])
        } else {
            addTrackSection(to: menu, title: "Audio Track", items: audio)
        }

        menu.addItem(.separator())
        let captionsOn = info["captionsOn"] as? Bool == true
        var subtitles = [trackMenuItem("Off", selected: !captionsOn, request: ["type": "captions", "id": ""])]
        subtitles += captionInfo.map { track in
            trackMenuItem(track["label"] as? String ?? "", selected: track["selected"] as? Bool == true,
                          request: ["type": "captions", "id": track["id"] as? String ?? ""])
        }
        addTrackSection(to: menu, title: "Subtitles/CC", items: subtitles)

        let languages = info["translationLanguages"] as? [[String: Any]] ?? []
        if !languages.isEmpty {
            menu.addItem(autoTranslateMenuItem(languages: languages,
                                               current: info["translation"] as? String ?? ""))
        }
        return menu
    }

    /// Adds a titled group of radio-style items. Long lists (heavily dubbed
    /// videos carry 20+ audio tracks) and `collapse` sections go into a
    /// submenu so the menu stays on screen.
    private func addTrackSection(to menu: NSMenu, title: String, items: [NSMenuItem], collapse: Bool = false) {
        if collapse || items.count > 8 {
            let current = items.first { $0.state == .on }?.title
            let parent = NSMenuItem(title: current.map { "\(title): \($0)" } ?? title,
                                    action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            items.forEach { submenu.addItem($0) }
            parent.submenu = submenu
            menu.addItem(parent)
            return
        }
        if #available(macOS 14.0, *) {
            menu.addItem(.sectionHeader(title: title))
        } else {
            let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
        }
        items.forEach { menu.addItem($0) }
    }

    private func autoTranslateMenuItem(languages: [[String: Any]], current: String) -> NSMenuItem {
        let entries = languages.compactMap { lang -> (code: String, label: String)? in
            guard let code = lang["id"] as? String, !code.isEmpty else { return nil }
            return (code, lang["label"] as? String ?? code)
        }
        let currentLabel = entries.first { $0.code == current }?.label
        let parent = NSMenuItem(title: currentLabel.map { "Auto-translate: \($0)" } ?? "Auto-translate",
                                action: nil, keyEquivalent: "")
        parent.state = currentLabel == nil ? .off : .on

        let submenu = NSMenu()
        submenu.autoenablesItems = false
        // The full list runs to 150+ languages; put the user's own first.
        var preferred: [(code: String, label: String)] = []
        for tag in Locale.preferredLanguages {
            for entry in entries where (tag == entry.code || tag.hasPrefix(entry.code + "-"))
                && !preferred.contains(where: { $0.code == entry.code }) {
                preferred.append(entry)
            }
        }
        for entry in preferred {
            submenu.addItem(trackMenuItem(entry.label, selected: entry.code == current,
                                          request: ["type": "translate", "id": entry.code]))
        }
        if !preferred.isEmpty { submenu.addItem(.separator()) }
        for entry in entries {
            submenu.addItem(trackMenuItem(entry.label, selected: entry.code == current,
                                          request: ["type": "translate", "id": entry.code]))
        }
        parent.submenu = submenu
        return parent
    }

    private func trackMenuItem(_ title: String, selected: Bool, request: [String: Any]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(trackMenuItemSelected(_:)), keyEquivalent: "")
        item.target = self
        item.state = selected ? .on : .off
        item.representedObject = request
        return item
    }

    @objc private func trackMenuItemSelected(_ item: NSMenuItem) {
        guard var request = item.representedObject as? [String: Any] else { return }
        request["action"] = "select"
        // The pick wins over the float-time sync from the Chrome tab, which may
        // still be retrying (e.g. holding captions off).
        prefsApplyDeadline = nil
        runMediaTracksJS(request) { result in
            let type = request["type"] as? String ?? "?"
            let id = request["id"] as? String ?? ""
            NSLog("%@", "[FloatVideo] Track menu: \(type)=\(id.isEmpty ? "off" : id) -> \(result as? String ?? "nil")")
        }
    }

    private func popUpTrackMenu(_ menu: NSMenu, from button: NSButton) {
        guard let bar = button.superview else { return }
        // Menus draw at the pop-up-menu window level. If this panel sits above
        // it (configureWindow asks for maximumWindow + 1) it would paint over
        // its own menu, so drop just under the menu level while it is open.
        let savedLevel = level
        let menuLevel = NSWindow.Level.popUpMenu.rawValue
        if savedLevel.rawValue >= menuLevel {
            level = NSWindow.Level(rawValue: menuLevel - 1)
        }
        defer { level = savedLevel }
        // Open upward, right-aligned to the button (like YouTube's settings
        // panel); AppKit still shifts it to stay on screen.
        let size = menu.size
        let topLeft = NSPoint(x: button.frame.maxX - size.width, y: button.frame.maxY + size.height)
        menu.popUp(positioning: nil, at: topLeft, in: bar)
    }

    // MARK: - Control Bar State Polling

    private func startUpdateTimer() {
        updateTimer?.invalidate()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            // Always run: polling drives audio-intent reconciliation, not just UI.
            // Skipping while controls are hidden would leave the page muted when
            // YouTube re-mutes during ad transitions and the cursor isn't inside.
            self.pollVideoState()
        }
    }

    private func stopUpdateTimer() {
        updateTimer?.invalidate()
        updateTimer = nil
    }

    private func pollVideoState() {
        let js = """
        (function() {
            var v = \(Self.mainVideoJS);
            if (v) {
                // Consume any pending trusted-click request atomically with the
                // current ad state so the native side never fires a stale click
                // after the ad has already ended.
                var tc = window.__floatVideoPendingTrustedClick || null;
                window.__floatVideoPendingTrustedClick = null;
                var mp = document.querySelector('#movie_player, .html5-video-player');
                var ads = !!(mp && (mp.classList.contains('ad-showing') ||
                                    mp.classList.contains('ad-interrupting')));
                return { ct: v.currentTime, dur: v.duration, vol: v.volume, muted: v.muted, paused: v.paused,
                         skips: window.__floatVideoAdSkipCount || 0,
                         ff: window.__floatVideoAdFFCount || 0,
                         adSkipInstalled: !!window.__floatVideoAdSkipInstalled,
                         tc: tc, ads: ads };
            }
            if (window.getPlayerState) return window.getPlayerState();
            return null;
        })()
        """
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self = self, let dict = result as? [String: Any] else { return }
            let ct = dict["ct"] as? Double ?? 0
            let dur = dict["dur"] as? Double ?? 0
            let vol = dict["vol"] as? Double ?? 1
            let muted = dict["muted"] as? Bool ?? false
            let paused = dict["paused"] as? Bool ?? true

            // Diagnostics: log whenever the in-page ad-skip guard has clicked Skip
            // since the last poll (the guard runs in-page, so surface it natively).
            let skips = (dict["skips"] as? NSNumber)?.intValue ?? 0
            if skips > self.lastAdSkipCount {
                NSLog("[FloatVideo] Auto-skipped ad (total \(skips))")
                self.lastAdSkipCount = skips
            }
            let ff = (dict["ff"] as? NSNumber)?.intValue ?? 0
            if ff > self.lastAdFFCount {
                NSLog("[FloatVideo] Fast-forwarded stuck ad (total \(ff))")
                self.lastAdFFCount = ff
            }

            // Self-healing: a full in-page navigation (autoplay-next, reload)
            // wipes the JS world while Swift-side state blocks re-injection in
            // didFinish. Re-install the ad-skip guard whenever the page reports
            // it missing. Same philosophy as the mute-intent reconciliation below.
            let adSkipInstalled = dict["adSkipInstalled"] as? Bool ?? true
            if !adSkipInstalled, self.currentSite == "youtube",
               self.loadingStrategy == .fullPageInject {
                self.injectAdSkip()
            }

            // Trusted click: the in-page guard published the skip button's
            // center; press it with a real mouse event. Only honor requests
            // whose same-poll snapshot still shows an ad, so a click can never
            // land on content after the ad ended between guard tick and poll.
            if self.currentSite == "youtube",
               self.loadingStrategy == .fullPageInject,
               let tc = dict["tc"] as? [String: Any],
               (dict["ads"] as? Bool) == true,
               let px = (tc["x"] as? NSNumber)?.doubleValue,
               let py = (tc["y"] as? NSNumber)?.doubleValue {
                self.performTrustedClick(pageX: px, pageY: py)
            }

            // Update progress bar
            if dur > 0 {
                let fraction = CGFloat(ct / dur)
                self.progressPlayed.frame.size.width = self.progressBg.frame.width * fraction
            }
            // Update time label
            self.timeLabel.stringValue = "\(self.formatTime(ct)) / \(self.formatTime(dur))"
            // Sync play state (observed)
            self.isPlaying = !paused
            self.setButtonSymbol(self.playPauseButton, paused ? "play.fill" : "pause.fill")

            // Mute/volume: UI reflects user INTENT, not the observed state.
            // If observed drifts from intent (YouTube re-mutes after an ad, audio
            // session interruption, etc.) re-assert intent on the page. Self-healing.
            let desiredMuted = self.userWantsMute
            self.setButtonSymbol(self.volumeButton, desiredMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            if desiredMuted {
                self.volumeSlider.doubleValue = 0
                if !muted {
                    self.videoJS("v.muted = true", youtubeCmd: "playerCommand('mute')")
                }
            } else {
                // Keep the slider visually pinned away from 0 while the user wants audio
                self.volumeSlider.doubleValue = max(vol, 0.01)
                if muted || vol == 0 {
                    self.videoJS("v.muted = false; v.volume = 1.0",
                                 youtubeCmd: "playerCommand('unmute'); playerCommand('volume', 1.0)")
                }
            }
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && !seconds.isNaN else { return "0:00" }
        let s = Int(seconds)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }

    @objc func toggleOpacity() {
        if self.alphaValue < 1.0 {
            self.alphaValue = 1.0
        } else {
            self.alphaValue = 0.6
        }
    }

    // MARK: - Resize Edge Detection

    private func detectResizeEdge(at point: NSPoint) -> ResizeEdge {
        let w = self.frame.width
        let h = self.frame.height
        let b = resizeBorderWidth

        let onLeft = point.x < b
        let onRight = point.x > w - b
        let onBottom = point.y < b
        let onTop = point.y > h - b

        if onTop && onLeft { return .topLeft }
        if onTop && onRight { return .topRight }
        if onBottom && onLeft { return .bottomLeft }
        if onBottom && onRight { return .bottomRight }
        if onLeft { return .left }
        if onRight { return .right }
        if onBottom { return .bottom }
        if onTop { return .top }
        return .none
    }

    private func cursorForEdge(_ edge: ResizeEdge) -> NSCursor {
        // Older Swift toolchains lack the macOS 15 SDK's frameResize API.
        #if compiler(>=6.0)
        if #available(macOS 15, *) {
            switch edge {
            case .left: return .frameResize(position: .left, directions: .all)
            case .right: return .frameResize(position: .right, directions: .all)
            case .top: return .frameResize(position: .top, directions: .all)
            case .bottom: return .frameResize(position: .bottom, directions: .all)
            case .topLeft: return .frameResize(position: .topLeft, directions: .all)
            case .topRight: return .frameResize(position: .topRight, directions: .all)
            case .bottomLeft: return .frameResize(position: .bottomLeft, directions: .all)
            case .bottomRight: return .frameResize(position: .bottomRight, directions: .all)
            case .none: return .arrow
            }
        }
        #endif
        switch edge {
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        case .topLeft, .bottomRight: return .crosshair
        case .topRight, .bottomLeft: return .crosshair
        case .none: return .arrow
        }
    }

    // MARK: - Event Interception (intercept resize events before WKWebView)

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .mouseMoved, .cursorUpdate:
            if isResizing {
                cursorForEdge(resizeEdge).set()
                return
            }
            let location = event.locationInWindow
            let edge = detectResizeEdge(at: location)
            if edge != .none,
               !(edge == .top && titleBarView.alphaValue > 0 && titleBarView.frame.contains(location)) {
                cursorForEdge(edge).set()
                return
            }
        case .leftMouseDown:
            // Synthetic trusted clicks (ad skip) must reach the web view even
            // when they land inside the resize border.
            if isPostingSyntheticClick { break }
            let location = event.locationInWindow
            let edge = detectResizeEdge(at: location)
            if edge != .none {
                // When title bar is visible, drag takes priority over top-edge resize
                if edge == .top, titleBarView.alphaValue > 0,
                   titleBarView.frame.contains(location) {
                    break // Let DraggableTitleBar handle the drag
                }
                isResizing = true
                resizeEdge = edge
                cursorForEdge(edge).set()
                initialMouseLocation = NSEvent.mouseLocation
                initialWindowFrame = self.frame
                return
            }
        case .leftMouseDragged:
            if isResizing {
                mouseDragged(with: event)
                return
            }
        case .leftMouseUp:
            if isResizing {
                mouseUp(with: event)
                return
            }
        default:
            break
        }
        super.sendEvent(event)
    }

    // MARK: - Mouse Handling

    override func mouseDown(with event: NSEvent) {
        // Resize handled by sendEvent interception, title bar drag handled by DraggableTitleBar
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isResizing else {
            super.mouseDragged(with: event)
            return
        }
        cursorForEdge(resizeEdge).set()

        let currentMouse = NSEvent.mouseLocation
        let deltaX = currentMouse.x - initialMouseLocation.x
        let deltaY = currentMouse.y - initialMouseLocation.y
        var newFrame = initialWindowFrame

        // First calculate new width based on edge
        switch resizeEdge {
        case .right, .topRight, .bottomRight:
            newFrame.size.width += deltaX
        case .left, .topLeft, .bottomLeft:
            newFrame.size.width -= deltaX
        case .top, .bottom:
            // Vertical drag: derive width from height
            let dh = (resizeEdge == .top) ? deltaY : -deltaY
            newFrame.size.height = initialWindowFrame.height + dh
            newFrame.size.width = newFrame.size.height * videoAspectRatio
        case .none:
            break
        }

        switch resizeEdge {
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            let dh = (resizeEdge == .topLeft || resizeEdge == .topRight) ? deltaY : -deltaY
            let verticalWidth = (initialWindowFrame.height + dh) * videoAspectRatio
            if abs(verticalWidth - initialWindowFrame.width) > abs(newFrame.width - initialWindowFrame.width) {
                newFrame.size.width = verticalWidth
            }
        default: break
        }

        // Horizontal/diagonal drag: derive height from width, maintain aspect ratio
        if resizeEdge != .top && resizeEdge != .bottom && resizeEdge != .none {
            newFrame.size.height = newFrame.size.width / videoAspectRatio
        }

        // Enforce minimum size
        let minW = self.minSize.width
        if newFrame.size.width < minW {
            newFrame.size.width = minW
            newFrame.size.height = minW / videoAspectRatio
        }

        // Anchor to opposite edge
        switch resizeEdge {
        case .left, .bottomLeft, .topLeft:
            newFrame.origin.x = initialWindowFrame.maxX - newFrame.size.width
        default: break
        }
        switch resizeEdge {
        case .bottom, .bottomLeft, .bottomRight:
            newFrame.origin.y = initialWindowFrame.maxY - newFrame.size.height
        default: break
        }

        self.setFrame(newFrame, display: true, animate: false)
    }

    override func mouseUp(with event: NSEvent) {
        if isResizing {
            saveWindowFrame()
        }
        isResizing = false
        resizeEdge = .none
        NSCursor.arrow.set()
        super.mouseUp(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        if !isResizing {
            NSCursor.arrow.set()
        }
        super.mouseExited(with: event)
    }

    // Allow window to become key window + respond to first click
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override var acceptsMouseMovedEvents: Bool {
        get { true }
        set { super.acceptsMouseMovedEvents = newValue }
    }

    // ESC closes the window
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            closeWindow()
        } else {
            super.keyDown(with: event)
        }
    }
}
