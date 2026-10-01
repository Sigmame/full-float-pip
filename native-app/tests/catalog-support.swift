import Foundation

// Run: swiftc -swift-version 5 Sources/CatalogSupport.swift tests/catalog-support.swift -o /tmp/catalog-support && /tmp/catalog-support
@main
struct CatalogSupportChecks {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }

    static func main() throws {
        // --- Network policy -------------------------------------------------------------
        func allowed(_ text: String) -> Bool { URL(string: text).map(CatalogNetworkPolicy.allows) ?? false }
        check(allowed("https://phimapi.com/danh-sach/phim-moi-cap-nhat?page=1"), "provider API is reachable")
        check(allowed("https://phim.nguonc.com/api/films/search?keyword=a"), "provider subdomain is reachable")
        check(allowed("https://img.nguonc.com/x.jpg"), "provider artwork host is reachable")
        check(allowed("https://phimimg.com/uploads/movies/a-poster.webp"), "artwork host is reachable")
        for blocked in ["http://phimapi.com/x", "https://example.com/", "https://phimapi.com.evil.com/x",
                        "https://evilphimapi.com/x", "https://user:pw@phimapi.com/x", "https://phimapi.com:8443/x",
                        "https://sub.phimimg.com/x", "file:///etc/passwd", "vibe://app/catalog.html"] {
            check(!allowed(blocked), "must block \(blocked)")
        }
        check(CatalogNetworkPolicy.allowedMethods == ["GET", "HEAD"], "read-only methods")
        let headers = CatalogNetworkPolicy.sanitizedHeaders(["Accept": "application/json", "Cookie": "a=b", "Authorization": "x",
                                                              "accept-language": "vi", "X-Evil": "1", "Accept-Charset": "a\r\nInjected: 1"])
        check(headers == ["Accept": "application/json", "accept-language": "vi"], "only harmless headers pass: \(headers)")

        // --- Assets: only files under the folder, only known types ------------------------
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-assets-\(UUID().uuidString)")
        let root = base.appendingPathComponent("catalog")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("icons"), withIntermediateDirectories: true)
        try "<html></html>".write(to: root.appendingPathComponent("catalog.html"), atomically: true, encoding: .utf8)
        try "1".write(to: root.appendingPathComponent("catalog.js"), atomically: true, encoding: .utf8)
        try "x".write(to: root.appendingPathComponent("icons/icon.png"), atomically: true, encoding: .utf8)
        try "secret".write(to: base.appendingPathComponent("secret.js"), atomically: true, encoding: .utf8)
        try "hidden".write(to: root.appendingPathComponent(".env.js"), atomically: true, encoding: .utf8)
        try "plain".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.js"), withDestinationURL: base.appendingPathComponent("secret.js"))
        let assets = CatalogAssets(root: root)
        check(assets.fileURL(forPath: "/")?.lastPathComponent == "catalog.html", "root serves the catalogue page")
        check(assets.fileURL(forPath: "/catalog.js") != nil && assets.fileURL(forPath: "/icons/icon.png") != nil, "bundled files are served")
        check(assets.fileURL(forPath: "/catalog.js?v=2#x") != nil, "query and fragment are ignored")
        for bad in ["/../secret.js", "/icons/../../secret.js", "/%2e%2e/secret.js", "/..%2fsecret.js", "/link.js", "/.env.js",
                    "/notes.txt", "/missing.js", "/icons", "//etc/passwd", "/a\\b.js", "/icons//icon.png", "/catalog.js%00.png"] {
            check(assets.fileURL(forPath: bad) == nil, "must not serve \(bad)")
        }
        check(CatalogAssets.mimeType(forExtension: "JS") == "text/javascript; charset=utf-8", "mime lookup ignores case")

        // --- Storage ------------------------------------------------------------------------
        let file = base.appendingPathComponent("support/storage.json")
        var storage: CatalogStorage? = CatalogStorage(fileURL: file)
        check(storage!.get(keys: "a").isEmpty, "empty to start")
        check(storage!.set(["a": 1, "list": [["slug": "x"]], "flag": true]), "set accepts JSON")
        check(storage!.get(keys: "a")["a"] as? Int == 1, "string key")
        check(Set(storage!.get(keys: ["a", "flag", "nope"]).keys) == ["a", "flag"], "list of keys skips missing")
        check(storage!.get(keys: ["a": 9, "b": 7]).count == 2 && (storage!.get(keys: ["b": 7])["b"] as? Int) == 7, "defaults fill gaps")
        check(storage!.get(keys: nil).count == 3, "nil returns everything")
        check(!storage!.set(["bad": Date()]), "non-JSON values are refused")
        check(storage!.get(keys: "bad").isEmpty, "a refused write changes nothing")
        check(!storage!.set(["huge": String(repeating: "x", count: CatalogStorage.maxBytes + 1)]), "the size cap holds")
        storage!.remove(keys: ["a"])
        check(storage!.get(keys: "a").isEmpty, "remove")
        storage!.flush()
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "storage file is owner-only")
        storage = nil
        let reopened = CatalogStorage(fileURL: file)
        check(reopened.get(keys: "flag")["flag"] as? Bool == true && reopened.get(keys: "a").isEmpty, "data survives a restart")

        // --- Continue watching ---------------------------------------------------------------
        let progress = CatalogStorage(fileURL: base.appendingPathComponent("support/progress.json"))
        let t0 = Date(timeIntervalSince1970: 1_000)
        CatalogProgress.apply(["slug": "a", "name": "Phim A", "poster": "p.jpg", "epName": "Tập 1", "currentTime": 120.0, "duration": 2400.0], to: progress, now: t0)
        CatalogProgress.apply(["slug": "b", "name": "Phim B", "currentTime": 5.0], to: progress, now: t0)
        CatalogProgress.apply(["slug": "a", "currentTime": 300.0], to: progress, now: t0.addingTimeInterval(60))
        var list = progress.get(keys: CatalogProgress.storageKey)[CatalogProgress.storageKey] as? [[String: Any]] ?? []
        check(list.count == 2 && list[0]["slug"] as? String == "a", "latest watched moves to the front")
        check(list[0]["name"] as? String == "Phim A" && list[0]["poster"] as? String == "p.jpg" && list[0]["epName"] as? String == "Tập 1", "a bare heartbeat keeps what was known")
        check(list[0]["currentTime"] as? Double == 300 && list[0]["duration"] as? Double == 2400, "time updates, duration is kept")
        check(list[0]["source"] as? String == "kkphim", "source defaults like the extension")
        check(list[0]["updatedAt"] as? Double == 1_060_000, "updatedAt is in milliseconds")
        CatalogProgress.apply(["name": "no slug"], to: progress)
        for i in 0..<15 { CatalogProgress.apply(["slug": "m\(i)", "currentTime": 1.0], to: progress) }
        list = progress.get(keys: CatalogProgress.storageKey)[CatalogProgress.storageKey] as? [[String: Any]] ?? []
        check(list.count == CatalogProgress.maxEntries && list[0]["slug"] as? String == "m14", "keeps ten, newest first")

        // --- Opening the floating player --------------------------------------------------------
        func open(_ info: [String: Any], aiDub: Bool = false, prefs: [String: Any]? = nil) -> [String: Any] {
            CatalogOpenRequest.message(from: info, playerPrefs: prefs, storedAIDub: aiDub)
        }
        var message = open(["pageUrl": "https://phimapi.com/phim/x", "src": "https://s.example/a.m3u8", "title": "Phim X", "site": "kkphim",
                            "width": NSNumber(value: 1920), "height": NSNumber(value: 1080), "currentTime": NSNumber(value: 42.5)])
        check(message["action"] as? String == "open" && message["width"] as? Int == 960 && message["height"] as? Int == 540, "landscape video is scaled to fit 960x540")
        check(message["currentTime"] as? Double == 42.5 && message["videoSrc"] as? String == "https://s.example/a.m3u8", "resume time and source pass through")
        message = open([:])
        check(message["width"] as? Int == 640 && message["height"] as? Int == 360 && message["title"] as? String == "VibeFloat" && message["site"] as? String == "generic", "defaults")
        message = open(["width": NSNumber(value: 200), "height": NSNumber(value: 100)])
        check(message["width"] as? Int == 320 && message["height"] as? Int == 160 || message["height"] as? Int == 180, "tiny video is raised to the minimum size: \(message)")
        message = open(["width": NSNumber(value: 1080), "height": NSNumber(value: 1920)])
        check(message["width"] as? Int == 340 && (message["height"] as? Int ?? 0) >= 520, "portrait video gets the phone-shaped window")
        check(open(["preferEmbed": true, "focusSession": NSNumber(value: true)])["preferEmbed"] as? Bool == true, "flags pass through")
        check(open([:])["preferEmbed"] == nil && open([:])["aiDubEnabled"] == nil, "flags are absent unless set")
        check(open([:], aiDub: true)["aiDubEnabled"] as? Bool == true, "stored dubbing preference applies when the request is silent")
        check(open(["aiDubEnabled": false], aiDub: true)["aiDubEnabled"] == nil, "an explicit off beats the stored preference")
        check(open(["site": "youtube"], prefs: ["rate": 1.5])["playerPrefs"] != nil && open(["site": "kkphim"], prefs: ["rate": 1.5])["playerPrefs"] == nil, "player prefs only for YouTube")
        check(open(["movieContext": ["slug": "x"]])["movieContext"] != nil, "playlist context passes through")

        try? FileManager.default.removeItem(at: base)
        print("Catalog support passed: network policy, asset paths, storage, continue watching and open requests")
    }
}
