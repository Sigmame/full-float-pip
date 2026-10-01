import Foundation
import Network
import Darwin

// MARK: - LocalHTTPServer — Local HTTP Server
// Provides valid HTTP Referer header for YouTube embeds

class LocalHTTPServer {
    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    private var isReady = false
    private let apiToken = UUID().uuidString
    private let playCapability = UUID().uuidString

    var localPlayCapability: String { playCapability }

    var onCommand: ((String, [String: String]) -> [String: Any]?)?

    func start(completion: @escaping (UInt16) -> Void) {
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            listener = try NWListener(using: params, on: .any)
        } catch {
            NSLog("[FloatVideo] HTTP server failed to create listener: \(error)")
            return
        }

        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let port = self?.listener?.port?.rawValue {
                    self?.port = port
                    self?.isReady = true
                    NSLog("[FloatVideo] HTTP server ready on port \(port)")
                    // Save port & token for CLI & Agent hooks.
                    // Owner-only permissions, and a symlink planted at either
                    // path is refused rather than followed: these live directly in
                    // $HOME, so following one would write the token wherever the
                    // link points. The old code used `write(atomically:)` for the
                    // port (0644) and `createFile` for the token (which follows
                    // an existing symlink).
                    let home = AppPaths.home
                    let portFile = home.appendingPathComponent(".floatvideo_port")
                    let tokenFile = home.appendingPathComponent(".floatvideo_token")
                    Self.writePrivateFile("\(port)", to: portFile)
                    Self.writePrivateFile(self?.apiToken ?? "", to: tokenFile)
                    completion(port)
                }
            case .failed(let error):
                NSLog("[FloatVideo] HTTP server failed: \(error)")
            default:
                break
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener?.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isReady = false
        let home = AppPaths.home
        try? FileManager.default.removeItem(at: home.appendingPathComponent(".floatvideo_token"))
        try? FileManager.default.removeItem(at: home.appendingPathComponent(".floatvideo_port"))
        NSLog("[FloatVideo] HTTP server stopped")
    }

    // MARK: - Private File Writing

    /// Writes a secret/IPC value with owner-only permissions, refusing to follow
    /// a symlink at the destination. Returns false when the path could not be
    /// written safely — callers keep going, since a missing token file only
    /// disables the CLI, it does not break the player.
    @discardableResult
    private static func writePrivateFile(_ text: String, to url: URL) -> Bool {
        let path = url.path
        // `attributesOfItem` follows symlinks, so probe explicitly.
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil {
            NSLog("[FloatVideo] Refusing to write \(url.lastPathComponent): symlink at path")
            return false
        }
        // A stale file from a previous run would also defeat O_EXCL; remove it
        // first, deliberately, rather than reusing whatever is there.
        try? FileManager.default.removeItem(atPath: path)
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            NSLog("[FloatVideo] Could not create \(url.lastPathComponent) (errno \(errno))")
            return false
        }
        defer { close(fd) }
        let data = Data(text.utf8)
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == data.count else {
            NSLog("[FloatVideo] Short write for \(url.lastPathComponent)")
            return false
        }
        _ = fchmod(fd, 0o600)
        return true
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)

        // Read HTTP request
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, error in
            guard let data = data, error == nil else {
                connection.cancel()
                return
            }

            let request = String(data: data, encoding: .utf8) ?? ""
            self?.processRequest(request, connection: connection)
        }
    }

    private func processRequest(_ request: String, connection: NWConnection) {
        // Parse request line: GET /play?v=VIDEO_ID HTTP/1.1
        let lines = request.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendErrorResponse(connection: connection, code: 400, message: "Bad Request")
            return
        }

        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            sendErrorResponse(connection: connection, code: 400, message: "Bad Request")
            return
        }

        let path = parts[1]

        // Browsers may omit both Origin and Referer, so these headers are only
        // defense in depth. The capability/token below is the auth decision.
        if path.hasPrefix("/play") {
            guard queryValue("cap", in: path) == playCapability else {
                sendErrorResponse(connection: connection, code: 403, message: "Forbidden")
                return
            }
            for headerName in ["origin", "referer"] {
                if let value = Self.headerValue(headerName, in: lines), !Self.isLoopbackOrigin(value) {
                    NSLog("[FloatVideo] Refused \(path) from non-loopback \(headerName): \(value.prefix(80))")
                    sendErrorResponse(connection: connection, code: 403, message: "Forbidden")
                    return
                }
            }
        } else if path == "/health" {
            guard Self.headerValue("x-vibefloat-token", in: lines) == apiToken else {
                sendErrorResponse(connection: connection, code: 403, message: "Forbidden")
                return
            }
        }

        if path.hasPrefix("/play") {
            handlePlayRequest(path: path, connection: connection)
        } else if path == "/health" {
            sendResponse(connection: connection, body: "OK", contentType: "text/plain")
        } else if path.hasPrefix("/api/") {
            let token = lines.first(where: { $0.lowercased().hasPrefix("x-vibefloat-token:") })?
                .split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces)
            guard token == apiToken else {
                sendErrorResponse(connection: connection, code: 403, message: "Forbidden")
                return
            }
            handleApiRequest(path: path, connection: connection)
        } else {
            sendErrorResponse(connection: connection, code: 404, message: "Not Found")
        }
    }

    // MARK: - Request Header Helpers

    private static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]

    private static func headerValue(_ name: String, in lines: [String]) -> String? {
        let prefix = name.lowercased() + ":"
        return lines.first { $0.lowercased().hasPrefix(prefix) }?
            .split(separator: ":", maxSplits: 1).last?
            .trimmingCharacters(in: .whitespaces)
    }

    private func queryValue(_ name: String, in path: String) -> String? {
        guard let components = URLComponents(string: "http://localhost\(path)") else { return nil }
        return components.queryItems?.first(where: { $0.name == name })?.value
    }

    /// True when an Origin/Referer header points at this machine — i.e. at the
    /// player page we served ourselves. `null` origins and anything unparsable
    /// count as foreign.
    private static func isLoopbackOrigin(_ value: String) -> Bool {
        guard let host = URLComponents(string: value)?.host ?? URL(string: value)?.host else { return false }
        return loopbackHosts.contains(host.lowercased())
    }

    // MARK: - API Request Handler (Vibe-Sync & Automation)

    private func handleApiRequest(path: String, connection: NWConnection) {
        guard let urlComponents = URLComponents(string: "http://localhost\(path)") else {
            sendErrorResponse(connection: connection, code: 400, message: "Invalid URL")
            return
        }
        let command = String(urlComponents.path.dropFirst("/api/".count))
        var params: [String: String] = [:]
        for item in urlComponents.queryItems ?? [] {
            params[item.name] = item.value ?? ""
        }

        let result = onCommand?(command, params) ?? ["success": true, "command": command]
        if let jsonData = try? JSONSerialization.data(withJSONObject: result, options: []),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            sendResponse(connection: connection, body: jsonString, contentType: "application/json; charset=utf-8")
        } else {
            sendResponse(connection: connection, body: "{\"success\":true}", contentType: "application/json; charset=utf-8")
        }
    }

    // MARK: - Play Request Handler

    private func handlePlayRequest(path: String, connection: NWConnection) {
        // Parse query parameters
        guard let urlComponents = URLComponents(string: "http://localhost\(path)") else {
            sendErrorResponse(connection: connection, code: 400, message: "Invalid URL")
            return
        }

        let queryItems = urlComponents.queryItems ?? []
        let videoId = queryItems.first(where: { $0.name == "v" })?.value ?? ""
        let site = queryItems.first(where: { $0.name == "site" })?.value ?? "youtube"
        let startTime = queryItems.first(where: { $0.name == "t" })?.value ?? "0"
        let safeWidth = min(max(Int(queryItems.first(where: { $0.name == "w" })?.value ?? "") ?? 640, 200), 1920)
        let safeHeight = min(max(Int(queryItems.first(where: { $0.name == "h" })?.value ?? "") ?? 360, 200), 1080)

        guard site == "youtube", videoId.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil else {
            sendErrorResponse(connection: connection, code: 400, message: "Invalid video ID")
            return
        }

        let html = buildYouTubePlayerHTML(
            videoId: videoId,
            startTime: startTime,
            safeWidth: safeWidth,
            safeHeight: safeHeight
        )

        sendResponse(connection: connection, body: html, contentType: "text/html; charset=utf-8")
    }

    // MARK: - YouTube Player HTML

    private func buildYouTubePlayerHTML(videoId: String, startTime: String,
                                        safeWidth: Int, safeHeight: Int) -> String {
        let startSeconds = max(Int(startTime) ?? 0, 0)
        let origin = "http://127.0.0.1:\(port)"
        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta name="referrer" content="no-referrer">
            <title>VibeFloat</title>
            <style>
                * { margin: 0; padding: 0; box-sizing: border-box; }
                html, body { width: 100%; height: 100%; background: #000; overflow: hidden; }
                #stage {
                    position: fixed;
                    top: 0;
                    left: 0;
                    width: \(safeWidth)px;
                    height: \(safeHeight)px;
                    transform-origin: top left;
                    transform: scale(1);
                    background: #000;
                }
                #ytplayer {
                    width: 100%;
                    height: 100%;
                    background: #000;
                }
                #stage iframe {
                    display: block;
                    border: none;
                }
            </style>
        </head>
        <body>
            <div id="stage">
                <div id="ytplayer"></div>
            </div>
            <script>
            var SAFE_W = \(safeWidth);
            var SAFE_H = \(safeHeight);
            (function() {
                var stage = document.getElementById('stage');
                window.player = null;

                function getLayout() {
                    var vw = Math.max(window.innerWidth || 0, 1);
                    var vh = Math.max(window.innerHeight || 0, 1);
                    if (vw < SAFE_W || vh < SAFE_H) {
                        return {
                            viewportWidth: vw,
                            viewportHeight: vh,
                            playerWidth: SAFE_W,
                            playerHeight: SAFE_H,
                            scale: Math.min(vw / SAFE_W, vh / SAFE_H)
                        };
                    }
                    return {
                        viewportWidth: vw,
                        viewportHeight: vh,
                        playerWidth: vw,
                        playerHeight: vh,
                        scale: 1
                    };
                }

                function applyLayout(layout) {
                    stage.style.width = layout.playerWidth + 'px';
                    stage.style.height = layout.playerHeight + 'px';
                    stage.style.transform = 'scale(' + layout.scale + ')';
                    stage.style.left = Math.round((layout.viewportWidth - layout.playerWidth * layout.scale) / 2) + 'px';
                    stage.style.top = Math.round((layout.viewportHeight - layout.playerHeight * layout.scale) / 2) + 'px';

                    if (window.player && window.player.setSize) {
                        window.player.setSize(
                            Math.round(layout.playerWidth),
                            Math.round(layout.playerHeight)
                        );
                    }
                }

                window.fitYouTubePlayer = function() {
                    applyLayout(getLayout());
                };

                window.addEventListener('resize', window.fitYouTubePlayer);
                window.fitYouTubePlayer();
            })();
            var tag = document.createElement('script');
            tag.src = 'https://www.youtube.com/iframe_api';
            document.head.appendChild(tag);
            function onYouTubeIframeAPIReady() {
                var initialLayout = (function() {
                    var vw = Math.max(window.innerWidth || 0, 1);
                    var vh = Math.max(window.innerHeight || 0, 1);
                    if (vw < SAFE_W || vh < SAFE_H) {
                        return { width: SAFE_W, height: SAFE_H };
                    }
                    return { width: vw, height: vh };
                })();

                window.player = new YT.Player('ytplayer', {
                    width: initialLayout.width,
                    height: initialLayout.height,
                    videoId: '\(videoId)',
                    playerVars: {
                        autoplay: 1,
                        controls: 0,
                        rel: 0,
                        modestbranding: 1,
                        start: \(startSeconds),
                        playsinline: 1,
                        origin: '\(origin)'
                    },
                    events: {
                        'onReady': function() {
                            window.fitYouTubePlayer();
                        }
                    }
                });
            }
            window.getPlayerState = function() {
                if (!window.player || !window.player.getCurrentTime) return null;
                try {
                    return {
                        ct: window.player.getCurrentTime(),
                        dur: window.player.getDuration(),
                        vol: window.player.getVolume() / 100,
                        muted: window.player.isMuted(),
                        paused: window.player.getPlayerState() === 2
                    };
                } catch(e) { return null; }
            };
            window.playerCommand = function(cmd, val) {
                if (!window.player) return;
                try {
                    if (cmd === 'play') window.player.playVideo();
                    if (cmd === 'pause') window.player.pauseVideo();
                    if (cmd === 'seek') window.player.seekTo(val, true);
                    if (cmd === 'volume') window.player.setVolume(val * 100);
                    if (cmd === 'mute') window.player.mute();
                    if (cmd === 'unmute') window.player.unMute();
                } catch(e) {}
            };
            </script>
        </body>
        </html>
        """
    }

    // MARK: - HTTP Response

    private func sendResponse(connection: NWConnection, body: String, contentType: String) {
        let bodyData = body.data(using: .utf8) ?? Data()
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: \(contentType)\r
        Content-Length: \(bodyData.count)\r
        Connection: close\r
        \r

        """.data(using: .utf8)! + bodyData

        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendErrorResponse(connection: NWConnection, code: Int, message: String) {
        let body = "<h1>\(code) \(message)</h1>"
        let bodyData = body.data(using: .utf8) ?? Data()
        let response = """
        HTTP/1.1 \(code) \(message)\r
        Content-Type: text/html\r
        Content-Length: \(bodyData.count)\r
        Connection: close\r
        \r

        """.data(using: .utf8)! + bodyData

        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
