import Cocoa
import WebKit

// MARK: - The app: the catalogue in its own window, a menu bar item, and the floating player

/// One standalone app at a time: a second launch asks the first to show its window and quits.
enum StandaloneInstance {
    static let showCatalogNotification = Notification.Name("com.aspect.floatvideo.show-catalog")
    private static var lockDescriptor: Int32 = -1

    static var supportDirectory: URL {
        AppPaths.home
            .appendingPathComponent("Library/Application Support/FloatVideo", isDirectory: true)
    }

    /// True when this process is the only standalone instance.
    static func acquire() -> Bool {
        try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let path = supportDirectory.appendingPathComponent("standalone.lock").path
        let descriptor = open(path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if descriptor >= 0 { close(descriptor) }
            return false
        }
        lockDescriptor = descriptor   // held until the process exits
        return true
    }
}

extension AppDelegate {
    /// Folder holding the bundled catalogue: an override for development, the app bundle, or
    /// the installer's copy next to the app.
    static func catalogAssetsRoot() -> URL? {
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["VIBEFLOAT_CATALOG_DIR"], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override, isDirectory: true))
        }
        if let resources = Bundle.main.resourceURL { candidates.append(resources.appendingPathComponent("catalog", isDirectory: true)) }
        candidates.append(StandaloneInstance.supportDirectory.appendingPathComponent("catalog", isDirectory: true))
        return candidates.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent(CatalogAssets.defaultPage).path)
        }
    }

    /// Startup: single instance, menus, then the catalogue window.
    func startStandalone() {
        guard StandaloneInstance.acquire() else {
            DistributedNotificationCenter.default().postNotificationName(
                StandaloneInstance.showCatalogNotification, object: nil, userInfo: nil, deliverImmediately: true)
            exit(0)
        }
        NSApp.setActivationPolicy(.regular)
        installMainMenu()
        menuBar = MenuBarController(delegate: self)
        DistributedNotificationCenter.default().addObserver(
            forName: StandaloneInstance.showCatalogNotification, object: nil, queue: .main) { [weak self] _ in
            self?.showCatalog()
        }

        let storage = CatalogStorage(fileURL: StandaloneInstance.supportDirectory.appendingPathComponent("catalog-storage.json"))
        catalogStorage = storage
        // Scripted checks drive the player over the local API and do not need the catalogue window.
        if ProcessInfo.processInfo.environment["VIBEFLOAT_NO_CATALOG"] == "1" { return }
        guard let root = Self.catalogAssetsRoot() else {
            let alert = NSAlert()
            alert.messageText = "Không tìm thấy giao diện kho phim"
            alert.informativeText = "Chạy lại scripts/install.sh để cài đặt đầy đủ."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        catalog = CatalogWindowController(assets: CatalogAssets(root: root), storage: storage, delegate: self)
        showCatalog()
        runCatalogSelfTestIfRequested()
    }

    func showCatalog() {
        catalog?.show()
    }

    func tellCatalog(_ message: [String: Any]) {
        catalog?.emit(message)
    }

    // MARK: Menu

    private func installMainMenu() {
        let main = NSMenu()
        func add(_ title: String, to menu: NSMenu, action: Selector?, key: String = "",
                 modifiers: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = target
            menu.addItem(item)
        }
        func submenu(_ title: String, _ build: (NSMenu) -> Void) {
            let item = NSMenuItem(); main.addItem(item)
            let menu = NSMenu(title: title); item.submenu = menu
            build(menu)
        }

        submenu("VibeFloat") { menu in
            add("Giới thiệu VibeFloat", to: menu, action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), modifiers: [])
            menu.addItem(.separator())
            add("Ẩn VibeFloat", to: menu, action: #selector(NSApplication.hide(_:)), key: "h")
            add("Ẩn các ứng dụng khác", to: menu, action: #selector(NSApplication.hideOtherApplications(_:)), key: "h", modifiers: [.command, .option])
            menu.addItem(.separator())
            add("Thoát VibeFloat", to: menu, action: #selector(NSApplication.terminate(_:)), key: "q")
        }
        submenu("Chỉnh sửa") { menu in
            add("Hoàn tác", to: menu, action: Selector(("undo:")), key: "z")
            add("Làm lại", to: menu, action: Selector(("redo:")), key: "z", modifiers: [.command, .shift])
            menu.addItem(.separator())
            add("Cắt", to: menu, action: #selector(NSText.cut(_:)), key: "x")
            add("Sao chép", to: menu, action: #selector(NSText.copy(_:)), key: "c")
            add("Dán", to: menu, action: #selector(NSText.paste(_:)), key: "v")
            add("Chọn tất cả", to: menu, action: #selector(NSText.selectAll(_:)), key: "a")
        }
        submenu("Hiển thị") { menu in
            add("Tải lại kho phim", to: menu, action: #selector(menuReloadCatalog), key: "r", target: self)
            add("Toàn màn hình", to: menu, action: #selector(NSWindow.toggleFullScreen(_:)), key: "f", modifiers: [.command, .control])
        }
        submenu("Cửa sổ") { menu in
            add("Thu nhỏ", to: menu, action: #selector(NSWindow.performMiniaturize(_:)), key: "m")
            add("Kho phim", to: menu, action: #selector(menuShowCatalog), key: "1", target: self)
        }
        NSApp.mainMenu = main
    }

    @objc func menuReloadCatalog() { catalog?.reload() }
    @objc func menuShowCatalog() { showCatalog() }

    // MARK: Development self-test

    /// With VIBEFLOAT_CATALOG_SELFTEST_JS and VIBEFLOAT_CATALOG_SELFTEST_OUT set, runs that script
    /// in the loaded catalogue after a delay, writes its JSON result to the output path and quits.
    /// Lets the window be verified without a person at the screen. Does nothing otherwise.
    func runCatalogSelfTestIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let scriptPath = env["VIBEFLOAT_CATALOG_SELFTEST_JS"], let outPath = env["VIBEFLOAT_CATALOG_SELFTEST_OUT"],
              let script = try? String(contentsOfFile: scriptPath, encoding: .utf8) else { return }
        let delay = Double(env["VIBEFLOAT_CATALOG_SELFTEST_DELAY"] ?? "") ?? 8
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let webView = self?.catalog?.webView else { return }
            webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
                var payload: [String: Any]
                switch result {
                case .success(let value): payload = ["ok": true, "result": value]
                case .failure(let error): payload = ["ok": false, "error": "\(error)"]
                }
                if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
                    try? data.write(to: URL(fileURLWithPath: outPath))
                }
                if env["VIBEFLOAT_CATALOG_SELFTEST_KEEP"] != "1" { NSApp.terminate(nil) }
            }
        }
    }
}

// MARK: - Catalogue requests

extension AppDelegate: CatalogBridgeDelegate {
    /// The messages the catalogue used to send to the extension's service worker, answered here.
    func catalogHandle(runtimeMessage message: [String: Any], completion: @escaping ([String: Any]) -> Void) {
        switch message["type"] as? String ?? "" {
        case "GET_NATIVE_STATUS":
            completion(["success": true, "connected": true, "isGhost": currentGhostState(),
                        "isAIDubEnabled": floatWindow?.isAIDubbingEnabled ?? false])

        case "NATIVE_COMMAND":
            let action = message["action"] as? String ?? ""
            var params: [String: String] = [:]
            if let value = message["value"] { params["val"] = "\(value)" }
            // The command table waits on the main thread, so it cannot run on it.
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = self?.runNativeCommand(action, params: params) ?? ["success": false, "error": "App not ready"]
                DispatchQueue.main.async { completion(result) }
            }

        case "FLOAT_VIDEO_REQUEST":
            guard let info = message["videoInfo"] as? [String: Any] else {
                completion(["success": false, "error": "Thiếu thông tin video."])
                return
            }
            let stored = (catalogStorage?.get(keys: "vibe_ai_dubbing_enabled_v2")["vibe_ai_dubbing_enabled_v2"] as? NSNumber)?.boolValue ?? false
            let request = CatalogOpenRequest.message(from: info, playerPrefs: message["playerPrefs"] as? [String: Any], storedAIDub: stored)
            if let error = performOpen(request) {
                completion(["success": false, "error": error])
            } else {
                tellCatalog(["type": "NATIVE_STATUS_BROADCAST", "connected": true, "isGhost": currentGhostState()])
                completion(["success": true, "title": request["title"] as? String ?? ""])
            }

        case "OPEN_YOUTUBE":
            // "YouTube ↗" on a curated film: the address is built here from a validated id, never taken from the page.
            let id = message["id"] as? String ?? ""
            guard id.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil,
                  let url = URL(string: "https://www.youtube.com/watch?v=\(id)") else {
                completion(["success": false, "error": "Invalid video id"])
                return
            }
            NSWorkspace.shared.open(url)
            completion(["success": true])

        case "CLOSE_FLOAT":
            closeFloatWindow()
            completion(["success": true])

        case "SET_AI_DUB_VOICE":
            let voice = message["voice"] as? String ?? message["gender"] as? String ?? ""
            _ = runNativeCommand("setDubVoice", params: ["voice": voice])
            completion(["success": true])

        case "TOGGLE_AI_DUB", "STOP_AI_DUB", "SPEAK_AI_DUB", "PREFETCH_AI_DUB", "PREFETCH_BATCH_AI_DUB":
            // These dub a browser tab's captions; the catalogue window has no tab to dub.
            completion(["success": true])

        default:
            completion(["success": false, "error": "Unknown message type"])
        }
    }
}
