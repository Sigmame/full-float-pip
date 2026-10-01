import Foundation

// Pure pieces of the native catalogue shell: what the page may reach on the network,
// which files it may be served, and where its data lives. No AppKit or WebKit here,
// so tests can exercise all of it directly.

// MARK: - Network policy

/// The hosts the catalogue may reach through the native bridge: the movie providers
/// (same list as the extension's manifest) and their artwork.
enum CatalogNetworkPolicy {
    private static let providerDomains = [
        "phimapi.com", "ophim1.com", "ophim.com", "nguonc.com", "streamc.xyz",
        "kkphim.com", "kkphimplayer.com", "kkphimplayer6.com"
    ]
    private static let exactHosts: Set<String> = ["phimimg.com"]
    static let allowedMethods: Set<String> = ["GET", "HEAD"]
    static let allowedRequestHeaders: Set<String> = ["accept", "accept-language"]
    static let maxBodyBytes = 12 * 1024 * 1024

    static func allows(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil, let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if exactHosts.contains(host) { return true }
        return providerDomains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func sanitizedHeaders(_ raw: [String: Any]?) -> [String: String] {
        var result: [String: String] = [:]
        for (name, value) in raw ?? [:] {
            guard allowedRequestHeaders.contains(name.lowercased()), let text = value as? String,
                  text.count <= 256, !text.contains("\n"), !text.contains("\r") else { continue }
            result[name] = text
        }
        return result
    }
}

// MARK: - Assets

/// Maps a request path on `vibe://app/` to a file under the catalogue folder, and nothing else.
struct CatalogAssets {
    let root: URL
    private let resolvedRoot: String

    static let defaultPage = "catalog.html"
    private static let mimeTypes: [String: String] = [
        "html": "text/html; charset=utf-8",
        "js": "text/javascript; charset=utf-8",
        "css": "text/css; charset=utf-8",
        "png": "image/png",
        "svg": "image/svg+xml",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "webp": "image/webp",
        "ico": "image/x-icon",
        "json": "application/json; charset=utf-8"
    ]

    init(root: URL) {
        self.root = root.standardizedFileURL
        self.resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func mimeType(forExtension ext: String) -> String? {
        mimeTypes[ext.lowercased()]
    }

    func fileURL(forPath rawPath: String) -> URL? {
        var path = rawPath.removingPercentEncoding ?? rawPath
        if let query = path.firstIndex(where: { $0 == "?" || $0 == "#" }) { path = String(path[..<query]) }
        while path.hasPrefix("/") { path.removeFirst() }
        if path.isEmpty { path = Self.defaultPage }
        guard !path.contains("\0"), !path.contains("\\") else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.contains(where: { $0 == ".." || $0 == "." || $0.isEmpty || $0.hasPrefix(".") }) else { return nil }
        let candidate = root.appendingPathComponent(path).standardizedFileURL
        guard Self.mimeType(forExtension: candidate.pathExtension) != nil else { return nil }
        // Resolve symlinks so a link inside the folder cannot lead outside it.
        let resolved = candidate.resolvingSymlinksInPath().path
        guard resolved.hasPrefix(resolvedRoot + "/") else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: resolved)
    }
}

// MARK: - Storage

/// `chrome.storage.local` for the native shell: a small JSON file, written atomically with
/// owner-only permissions. Reads and writes are serialised; writes are coalesced.
final class CatalogStorage {
    static let maxBytes = 8 * 1024 * 1024

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.aspect.floatvideo.catalog-storage")
    private var values: [String: Any]
    private var flushScheduled = false

    init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            values = object
        } else {
            values = [:]
        }
    }

    /// `keys` follows chrome.storage: nil for everything, a name, a list of names, or a
    /// dictionary of defaults.
    func get(keys: Any?) -> [String: Any] {
        queue.sync {
            switch keys {
            case let name as String:
                return values[name].map { [name: $0] } ?? [:]
            case let names as [String]:
                return names.reduce(into: [String: Any]()) { result, name in
                    if let value = values[name] { result[name] = value }
                }
            case let defaults as [String: Any]:
                return defaults.reduce(into: [String: Any]()) { result, pair in
                    result[pair.key] = values[pair.key] ?? pair.value
                }
            default:
                return values
            }
        }
    }

    @discardableResult
    func set(_ items: [String: Any]) -> Bool {
        queue.sync {
            var updated = values
            for (key, value) in items { updated[key] = value }
            guard JSONSerialization.isValidJSONObject(updated),
                  let data = try? JSONSerialization.data(withJSONObject: updated),
                  data.count <= Self.maxBytes else { return false }
            values = updated
            scheduleFlush()
            return true
        }
    }

    func remove(keys: [String]) {
        queue.sync {
            keys.forEach { values.removeValue(forKey: $0) }
            scheduleFlush()
        }
    }

    /// Write pending changes now (used at quit).
    func flush() {
        queue.sync { writeLocked() }
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        queue.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.writeLocked() }
    }

    private func writeLocked() {
        flushScheduled = false
        guard let data = try? JSONSerialization.data(withJSONObject: values) else { return }
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".catalog-storage-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else { return }
        if rename(temporary.path, fileURL.path) != 0 { try? FileManager.default.removeItem(at: temporary) }
    }
}

// MARK: - Continue watching

/// Native port of MovieService.applyProgressUpdate: the player reports where the viewer is,
/// and the "Tiếp tục xem" list (newest first, ten entries) is updated whether or not the
/// catalogue window is open.
enum CatalogProgress {
    static let storageKey = "vibe_continue_watching"
    static let maxEntries = 10

    static func apply(_ message: [String: Any], to storage: CatalogStorage, now: Date = Date()) {
        guard let slug = message["slug"] as? String, !slug.isEmpty else { return }
        let list = (storage.get(keys: storageKey)[storageKey] as? [[String: Any]]) ?? []
        let previous = list.first { ($0["slug"] as? String) == slug } ?? [:]

        func text(_ key: String) -> String {
            if let value = message[key] as? String, !value.isEmpty { return value }
            return previous[key] as? String ?? ""
        }
        func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }

        let currentTime = number(message["currentTime"]) ?? 0
        let duration = number(message["duration"]).flatMap { $0 > 0 ? $0 : nil } ?? number(previous["duration"]) ?? 0
        let entry: [String: Any] = [
            "slug": slug,
            "name": text("name"),
            "origin_name": text("origin_name"),
            "poster": text("poster"),
            "source": { let s = text("source"); return s.isEmpty ? "kkphim" : s }(),
            "epName": text("epName"),
            "epSlug": text("epSlug"),
            "linkM3u8": text("linkM3u8"),
            "linkEmbed": text("linkEmbed"),
            "genres": previous["genres"] ?? [],
            "genreName": previous["genreName"] ?? "",
            "genreSlug": previous["genreSlug"] ?? "",
            "countries": previous["countries"] ?? [],
            "currentTime": currentTime,
            "duration": duration,
            "serverIdx": number(message["serverIdx"]) ?? number(previous["serverIdx"]) ?? 0,
            "epIdx": number(message["epIdx"]) ?? number(previous["epIdx"]) ?? 0,
            "updatedAt": (now.timeIntervalSince1970 * 1000).rounded()
        ]
        var updated = list.filter { ($0["slug"] as? String) != slug }
        updated.insert(entry, at: 0)
        storage.set([storageKey: Array(updated.prefix(maxEntries))])
    }
}

// MARK: - Opening the floating player

/// Native port of the extension's `_doFloatVideo` message building: the catalogue asks for a
/// float, and this decides the window size and which fields reach the player.
enum CatalogOpenRequest {
    static func message(from videoInfo: [String: Any], playerPrefs: [String: Any]?, storedAIDub: Bool) -> [String: Any] {
        func number(_ key: String, default fallback: Double) -> Double {
            let value = (videoInfo[key] as? NSNumber)?.doubleValue ?? fallback
            return value > 0 ? value : fallback
        }
        func flag(_ key: String) -> Bool { (videoInfo[key] as? NSNumber)?.boolValue ?? (videoInfo[key] as? Bool) ?? false }

        let originalWidth = number("width", default: 640)
        let originalHeight = number("height", default: 360)
        let ratio = originalWidth / originalHeight
        var width: Double, height: Double
        if ratio < 0.8 {
            width = 340
            let target = (ratio > 0.3 && ratio < 1.0) ? ratio : 9.0 / 16.0
            height = (width / target).rounded()
            if height > 640 { height = 640 }
            if height < 520 { height = 568 }
        } else {
            let scale = min(960 / originalWidth, 540 / originalHeight, 1)
            width = (originalWidth * scale).rounded()
            height = (originalHeight * scale).rounded()
            if width < 320 { width = 320; height = (width / ratio).rounded() }
            if height < 180 { height = 180; width = (height * ratio).rounded() }
        }

        var message: [String: Any] = [
            "action": "open",
            "url": videoInfo["pageUrl"] as? String ?? "",
            "videoSrc": videoInfo["src"] as? String ?? "",
            "embedUrl": videoInfo["embedUrl"] as? String ?? "",
            "title": (videoInfo["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "VibeFloat",
            "site": (videoInfo["site"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "generic",
            // Int, because the player reads these as Int when they are not CGFloat.
            "width": Int(width),
            "height": Int(height),
            "currentTime": (videoInfo["currentTime"] as? NSNumber)?.doubleValue ?? 0
        ]
        if let context = videoInfo["movieContext"] as? [String: Any] { message["movieContext"] = context }
        if flag("preferEmbed") { message["preferEmbed"] = true }
        if flag("focusSession") { message["focusSession"] = true }
        let aiDub = videoInfo["aiDubEnabled"] == nil ? storedAIDub : flag("aiDubEnabled")
        if aiDub { message["aiDubEnabled"] = true }
        if message["site"] as? String == "youtube", let prefs = playerPrefs { message["playerPrefs"] = prefs }
        return message
    }
}
