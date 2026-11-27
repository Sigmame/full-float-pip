import Foundation
import Network

// MARK: - LocalHTTPServer — Local HTTP Server
// Provides valid HTTP Referer header for YouTube embeds

class LocalHTTPServer {
    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    private var isReady = false

    func start(completion: @escaping (UInt16) -> Void) {
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
            listener = try NWListener(using: params)
        } catch {
            NSLog("%@", "[FloatVideo] HTTP server failed to create listener: \(error)")
            return
        }

        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let port = self?.listener?.port?.rawValue {
                    self?.port = port
                    self?.isReady = true
                    NSLog("[FloatVideo] HTTP server ready on port \(port)")
                    completion(port)
                }
            case .failed(let error):
                NSLog("%@", "[FloatVideo] HTTP server failed: \(error)")
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
        NSLog("[FloatVideo] HTTP server stopped")
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

        if path.hasPrefix("/play") {
            handlePlayRequest(path: path, connection: connection)
        } else if path == "/health" {
            sendResponse(connection: connection, body: "OK", contentType: "text/plain")
        } else {
            sendErrorResponse(connection: connection, code: 404, message: "Not Found")
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
        let startTime = queryItems.first(where: { $0.name == "t" })?.value ?? "0"
        let safeWidth = max(Int(queryItems.first(where: { $0.name == "w" })?.value ?? "") ?? 640, 200)
        let safeHeight = max(Int(queryItems.first(where: { $0.name == "h" })?.value ?? "") ?? 360, 200)

        guard videoId.range(of: "\\A[A-Za-z0-9_-]+\\z", options: .regularExpression) != nil else {
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
            <title>Float Video</title>
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
