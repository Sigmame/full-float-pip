import Cocoa
import WebKit

// MARK: - Asset scheme

/// Serves the bundled catalogue from `vibe://app/…`. A custom scheme (rather than file://)
/// gives the page a real origin, lets us attach a Content-Security-Policy, and keeps the
/// reachable files to exactly what CatalogAssets allows.
final class CatalogSchemeHandler: NSObject, WKURLSchemeHandler {
    private let assets: CatalogAssets
    init(assets: CatalogAssets) { self.assets = assets }

    static let contentSecurityPolicy = [
        "default-src 'none'",
        "script-src 'self'",
        "style-src 'self' 'unsafe-inline'",
        "img-src 'self' https: data:",
        "font-src 'self' data:",
        "connect-src 'self'",
        "frame-src https://www.youtube-nocookie.com https://www.youtube.com http://127.0.0.1:*",
        "media-src https: blob:",
        "base-uri 'none'",
        "form-action 'none'"
    ].joined(separator: "; ")

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, url.host == CatalogWindowController.host,
              let file = assets.fileURL(forPath: url.path),
              let mime = CatalogAssets.mimeType(forExtension: file.pathExtension),
              let data = try? Data(contentsOf: file) else {
            respond(task, status: 404, mime: "text/plain; charset=utf-8", body: Data("Not found".utf8))
            return
        }
        respond(task, status: 200, mime: mime, body: data)
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private func respond(_ task: WKURLSchemeTask, status: Int, mime: String, body: Data) {
        guard let url = task.request.url else { return }
        var headers = [
            "Content-Type": mime,
            "Content-Length": String(body.count),
            "Cache-Control": "no-cache",
            "X-Content-Type-Options": "nosniff"
        ]
        if mime.hasPrefix("text/html") { headers["Content-Security-Policy"] = Self.contentSecurityPolicy }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(response)
        task.didReceive(body)
        task.didFinish()
    }
}

// MARK: - Window

/// The catalogue as a native window: the existing web UI in a WKWebView, with the
/// chrome.* APIs it expects answered by the app instead of the browser.
final class CatalogWindowController: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    static let scheme = "vibe"
    static let host = "app"
    static var startURL: URL { URL(string: "\(scheme)://\(host)/\(CatalogAssets.defaultPage)")! }

    let window: NSWindow
    let webView: WKWebView
    let bridge: CatalogBridge
    private(set) var didFinishLoading = false
    var onLoad: ((WKWebView) -> Void)?

    init(assets: CatalogAssets, storage: CatalogStorage, delegate: CatalogBridgeDelegate?) {
        bridge = CatalogBridge(storage: storage)
        bridge.delegate = delegate

        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(CatalogSchemeHandler(assets: assets), forURLScheme: Self.scheme)
        let shim = WKUserScript(source: Self.shimSource, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        configuration.userContentController.addUserScript(shim)
        configuration.userContentController.addScriptMessageHandler(bridge, contentWorld: .page, name: "vibe")
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        // The billboard trailer may start muted on its own; anything with sound waits for a click.
        configuration.mediaTypesRequiringUserActionForPlayback = .audio

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.underPageBackgroundColor = NSColor(calibratedRed: 0.071, green: 0.071, blue: 0.086, alpha: 1)
        webView.setValue(false, forKey: "allowsLinkPreview")
        if #available(macOS 13.3, *), ProcessInfo.processInfo.environment["VIBEFLOAT_DEBUG"] == "1" {
            webView.isInspectable = true
        }

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "VibeFloat — Kho phim"
        window.minSize = NSSize(width: 360, height: 520)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(calibratedRed: 0.071, green: 0.071, blue: 0.086, alpha: 1)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.center()
        window.setFrameAutosaveName("VibeFloatCatalogWindow")

        super.init()
        window.delegate = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.load(URLRequest(url: Self.startURL))
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func reload() { webView.reloadFromOrigin() }

    /// Deliver an event to the page's `chrome.runtime.onMessage` listeners.
    func emit(_ message: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(message),
              let data = try? JSONSerialization.data(withJSONObject: message),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.__vibeNativeEmit && window.__vibeNativeEmit(\(json))", completionHandler: nil)
    }

    // MARK: Navigation: nothing but our own page ever loads in this window.

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        let ours = url?.scheme == Self.scheme && url?.host == Self.host
        decisionHandler(ours || url?.absoluteString == "about:blank" ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        didFinishLoading = true
        onLoad?(webView)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        nil
    }

    // MARK: Shim

    /// Runs before the page's own scripts: gives them the chrome.* surface they were written
    /// against, and routes https fetches through the app.
    static let shimSource = #"""
    (() => {
      const call = (method, args) => window.webkit.messageHandlers.vibe.postMessage({ method, args: args || {} });
      const withCallback = (promise, callback) => {
        if (typeof callback === 'function') { promise.then(callback, () => callback(undefined)); return undefined; }
        return promise;
      };
      const listeners = new Set();
      const storageArea = {
        get(keys, callback) { return withCallback(call('storage.get', { keys: keys === undefined ? null : keys }), callback); },
        set(items, callback) { return withCallback(call('storage.set', { items }).then(() => undefined), callback); },
        remove(keys, callback) { return withCallback(call('storage.remove', { keys }).then(() => undefined), callback); }
      };
      window.chrome = {
        runtime: {
          id: 'vibefloat-native',
          lastError: null,
          getURL: path => 'vibe://app/' + String(path).replace(/^\//, ''),
          sendMessage(message, callback) { return withCallback(call('runtime.send', { message }), callback); },
          onMessage: { addListener: fn => listeners.add(fn), removeListener: fn => listeners.delete(fn) }
        },
        storage: {
          local: storageArea, sync: storageArea,
          onChanged: { addListener() {}, removeListener() {} }
        },
        tabs: { create() { return Promise.resolve(); }, query() { return Promise.resolve([]); }, sendMessage() { return Promise.resolve(); } }
      };
      window.__vibeNative = { shell: true };
      window.__vibeNativeEmit = message => {
        listeners.forEach(fn => { try { fn(message, {}, () => {}); } catch (error) { console.warn(error); } });
      };

      const pageFetch = window.fetch.bind(window);
      const toBytes = base64 => {
        const binary = atob(base64);
        const bytes = new Uint8Array(binary.length);
        for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
        return bytes;
      };
      window.fetch = async (input, init = {}) => {
        const request = typeof input === 'string' || input instanceof URL ? null : input;
        const url = new URL(request ? request.url : String(input), location.href);
        if (url.protocol !== 'https:') return pageFetch(input, init);
        const method = String(init.method || (request && request.method) || 'GET').toUpperCase();
        const headers = {};
        new Headers(init.headers || (request && request.headers) || {}).forEach((value, name) => { headers[name] = value; });
        const signal = init.signal || (request && request.signal);
        if (signal && signal.aborted) throw new DOMException('The operation was aborted.', 'AbortError');
        const pending = call('net.fetch', { url: url.href, method, headers });
        const aborted = signal ? new Promise((_, reject) => signal.addEventListener('abort',
          () => reject(new DOMException('The operation was aborted.', 'AbortError')), { once: true })) : null;
        const result = await (aborted ? Promise.race([pending, aborted]) : pending);
        if (!result || result.error) throw new TypeError('Failed to fetch');
        const emptyBody = method === 'HEAD' || [101, 204, 205, 304].includes(result.status);
        return new Response(emptyBody ? null : toBytes(result.bodyBase64), {
          status: result.status, statusText: result.statusText, headers: result.headers
        });
      };
    })();
    """#
}
