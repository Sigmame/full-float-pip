import Cocoa
import WebKit

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate {

    var floatWindow: FloatWindow?
    var messageHandler: NativeMessageHandler?
    var httpServer: LocalHTTPServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Start local HTTP server (provides valid Referer for YouTube embed)
        httpServer = LocalHTTPServer()
        httpServer?.start { port in
            NSLog("[FloatVideo] HTTP server started on port \(port)")
        }

        // Start Native Messaging
        messageHandler = NativeMessageHandler()
        messageHandler?.onMessage = { [weak self] message in
            DispatchQueue.main.async {
                self?.handleMessage(message)
            }
        }
        messageHandler?.startListening()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false  // Don't quit when window closes
    }

    func handleMessage(_ msg: [String: Any]) {
        guard let action = msg["action"] as? String else {
            messageHandler?.sendMessage([
                "type": "error",
                "error": "Missing 'action' field"
            ])
            return
        }

        switch action {
        case "open":
            let url = validatedHTTPURL(msg["url"] as? String ?? "")
            let videoSrc = validatedHTTPURL(msg["videoSrc"] as? String ?? "")
            let embedUrl = validatedHTTPURL(msg["embedUrl"] as? String ?? "")
            let title = msg["title"] as? String ?? "Float Video"
            let rawSite = msg["site"] as? String ?? "generic"
            let site = rawSite.range(of: "\\A[a-z]+\\z", options: .regularExpression) != nil ? rawSite : "generic"
            let width = msg["width"] as? CGFloat
                ?? CGFloat(msg["width"] as? Int ?? 640)
            let height = msg["height"] as? CGFloat
                ?? CGFloat(msg["height"] as? Int ?? 360)
            let currentTime = msg["currentTime"] as? Double ?? 0

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
                playerPrefs: msg["playerPrefs"] as? [String: Any]
            )

            messageHandler?.sendMessage([
                "type": "status",
                "status": "opened",
                "title": title
            ])

        case "close":
            closeFloatWindow()
            messageHandler?.sendMessage([
                "type": "status",
                "status": "closed"
            ])

        case "ping":
            messageHandler?.sendMessage([
                "type": "status",
                "status": "pong"
            ])

        default:
            messageHandler?.sendMessage([
                "type": "error",
                "error": "Unknown action: \(action)"
            ])
        }
    }

    private func validatedHTTPURL(_ string: String) -> String {
        let lower = string.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://") ? string : ""
    }

    func openFloatWindow(url: String, videoSrc: String?, embedUrl: String?,
                         title: String, width: CGFloat, height: CGFloat,
                         currentTime: Double, site: String,
                         cookies: [[String: Any]] = [],
                         playerPrefs: [String: Any]? = nil) {
        closeFloatWindow()

        floatWindow = FloatWindow(
            videoWidth: width,
            videoHeight: height,
            videoTitle: title
        )

        floatWindow?.loadVideo(
            url: url, videoSrc: videoSrc, embedUrl: embedUrl,
            currentTime: currentTime, site: site,
            // Provider, not a snapshot: the HTTP server starts asynchronously and
            // its port is still 0 when the first open message arrives.
            httpServerPortProvider: { [weak self] in self?.httpServer?.port ?? 0 },
            cookies: cookies,
            playerPrefs: playerPrefs
        )

        floatWindow?.onClose = { [weak self] in
            self?.floatWindow = nil
            self?.messageHandler?.sendMessage([
                "type": "status",
                "status": "closed"
            ])
        }

        floatWindow?.show()
    }

    func closeFloatWindow() {
        floatWindow?.close()
        floatWindow = nil
    }
}
