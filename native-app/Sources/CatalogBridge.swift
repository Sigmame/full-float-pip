import Cocoa
import WebKit

// MARK: - Bridge between the catalogue page and the app

/// What the app implements for the catalogue: the same commands the extension's service
/// worker used to forward over native messaging, now answered in-process.
protocol CatalogBridgeDelegate: AnyObject {
    func catalogHandle(runtimeMessage: [String: Any], completion: @escaping ([String: Any]) -> Void)
}

/// Answers `window.webkit.messageHandlers.vibe` calls from the shim in CatalogWindow:
/// storage, network and runtime messages. The page is our own bundled UI, but it renders
/// remote data, so the bridge still refuses anything outside the three jobs it exists for.
final class CatalogBridge: NSObject, WKScriptMessageHandlerWithReply {
    weak var delegate: CatalogBridgeDelegate?
    let storage: CatalogStorage
    private let fetcher = CatalogFetcher()

    init(storage: CatalogStorage) {
        self.storage = storage
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        // Only our own page, in its main frame.
        guard message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.protocol == CatalogWindowController.scheme,
              message.frameInfo.securityOrigin.host == CatalogWindowController.host,
              let body = message.body as? [String: Any],
              let method = body["method"] as? String else {
            replyHandler(nil, "Rejected")
            return
        }
        let args = body["args"] as? [String: Any] ?? [:]

        switch method {
        case "storage.get":
            replyHandler(storage.get(keys: args["keys"]), nil)
        case "storage.set":
            let ok = storage.set(args["items"] as? [String: Any] ?? [:])
            replyHandler(ok ? ["ok": true] : nil, ok ? nil : "Storage limit reached")
        case "storage.remove":
            let keys = (args["keys"] as? [String]) ?? (args["keys"] as? String).map { [$0] } ?? []
            storage.remove(keys: keys)
            replyHandler(["ok": true], nil)
        case "runtime.send":
            guard let payload = args["message"] as? [String: Any], let delegate = delegate else {
                replyHandler(["success": false, "error": "App not ready"], nil)
                return
            }
            delegate.catalogHandle(runtimeMessage: payload) { replyHandler($0, nil) }
        case "net.fetch":
            fetcher.fetch(args) { replyHandler($0, nil) }
        default:
            replyHandler(nil, "Unknown method")
        }
    }
}

// MARK: - Network

/// `fetch` for the page, performed by the app so provider CORS rules do not apply. Restricted
/// to the provider hosts, GET and HEAD, no cookies, a body cap, and redirects that stay inside
/// the same allow-list.
final class CatalogFetcher: NSObject, URLSessionDataDelegate {
    private final class Job {
        var data = Data()
        var response: HTTPURLResponse?
        var overflow = false
        let completion: ([String: Any]) -> Void
        init(completion: @escaping ([String: Any]) -> Void) { self.completion = completion }
    }

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 40
        configuration.urlCache = URLCache(memoryCapacity: 16 * 1024 * 1024, diskCapacity: 0)
        configuration.requestCachePolicy = .useProtocolCachePolicy
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()
    private var jobs: [Int: Job] = [:]
    private let lock = NSLock()

    func fetch(_ args: [String: Any], completion: @escaping ([String: Any]) -> Void) {
        func fail(_ reason: String) { DispatchQueue.main.async { completion(["error": reason]) } }
        guard let raw = args["url"] as? String, let url = URL(string: raw), CatalogNetworkPolicy.allows(url) else {
            return fail("Blocked host")
        }
        let method = (args["method"] as? String ?? "GET").uppercased()
        guard CatalogNetworkPolicy.allowedMethods.contains(method) else { return fail("Blocked method") }

        var request = URLRequest(url: url)
        request.httpMethod = method
        CatalogNetworkPolicy.sanitizedHeaders(args["headers"] as? [String: Any])
            .forEach { request.setValue($1, forHTTPHeaderField: $0) }

        let task = session.dataTask(with: request)
        lock.lock(); jobs[task.taskIdentifier] = Job(completion: completion); lock.unlock()
        task.resume()
    }

    private func job(_ task: URLSessionTask) -> Job? {
        lock.lock(); defer { lock.unlock() }
        return jobs[task.taskIdentifier]
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        if let url = request.url, CatalogNetworkPolicy.allows(url) { completionHandler(request) } else { completionHandler(nil) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        job(dataTask)?.response = response as? HTTPURLResponse
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let job = job(dataTask), !job.overflow else { return }
        job.data.append(data)
        if job.data.count > CatalogNetworkPolicy.maxBodyBytes {
            job.overflow = true
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let finished = jobs.removeValue(forKey: task.taskIdentifier); lock.unlock()
        guard let job = finished else { return }
        var result: [String: Any]
        if job.overflow {
            result = ["error": "Response too large"]
        } else if let response = job.response {
            var headers: [String: String] = [:]
            for (name, value) in response.allHeaderFields {
                guard let name = name as? String, let value = value as? String else { continue }
                headers[name.lowercased()] = value
            }
            result = [
                "status": response.statusCode,
                "statusText": HTTPURLResponse.localizedString(forStatusCode: response.statusCode),
                "url": response.url?.absoluteString ?? "",
                "headers": headers,
                "bodyBase64": job.data.base64EncodedString()
            ]
        } else {
            result = ["error": error?.localizedDescription ?? "No response"]
        }
        DispatchQueue.main.async { job.completion(result) }
    }
}
