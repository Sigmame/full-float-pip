import Cocoa

/// The quick actions the browser popup used to offer, as a menu bar item (and the Dock menu):
/// open the catalogue, control the player that is open, resume something, and flip the two
/// preferences that matter while working over other apps.
final class MenuBarController: NSObject, NSMenuDelegate {
    static let aiDubKey = "vibe_ai_dubbing_enabled_v2"
    static let resumeEntries = 5

    private let statusItem: NSStatusItem
    private weak var delegate: AppDelegate?

    init(delegate: AppDelegate) {
        self.delegate = delegate
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        let image = NSImage(systemSymbolName: "rectangle.on.rectangle.angled", accessibilityDescription: "VibeFloat")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = "VibeFloat"
        let menu = NSMenu(title: "VibeFloat")
        menu.delegate = self
        statusItem.menu = menu
    }

    // The menu is rebuilt each time it opens, so it always shows the current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let fresh = buildMenu()
        // Move the items over (an item can belong to one menu only).
        while let item = fresh.items.first {
            fresh.removeItem(item)
            menu.addItem(item)
        }
    }

    func buildMenu() -> NSMenu {
        let menu = NSMenu(title: "VibeFloat")
        guard let delegate = delegate else { return menu }

        add(menu, "Mở kho phim", key: "1") { delegate.showCatalog() }

        if let player = delegate.floatWindow {
            menu.addItem(.separator())
            let title = NSMenuItem(title: "Đang mở: \(player.videoTitle)", action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)
            add(menu, player.isPlaying ? "Tạm dừng" : "Phát tiếp") { player.togglePlayPause() }
            add(menu, "Đóng cửa sổ nổi") { delegate.closeFloatWindow() }
        }

        let resume = Self.continueEntries(from: delegate.catalogStorage)
        if !resume.isEmpty {
            menu.addItem(.separator())
            let parent = NSMenuItem(title: "Tiếp tục xem", action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: "Tiếp tục xem")
            for entry in resume {
                add(submenu, entry.label) { delegate.resumeFromMenu(slug: entry.slug) }
            }
            parent.submenu = submenu
            menu.addItem(parent)
        }

        menu.addItem(.separator())
        let ghost = add(menu, "Xuyên chuột", key: "g", modifiers: [.command, .shift]) { delegate.toggleGhostFromMenu() }
        ghost.state = delegate.currentGhostState() ? .on : .off
        let dub = add(menu, "Lồng tiếng AI") { delegate.toggleAIDubFromMenu() }
        dub.state = delegate.aiDubPreference() ? .on : .off

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Thoát VibeFloat", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        return menu
    }

    /// Titles of the newest few "Tiếp tục xem" entries, read straight from storage.
    static func continueEntries(from storage: CatalogStorage?) -> [(slug: String, label: String)] {
        guard let list = storage?.get(keys: CatalogProgress.storageKey)[CatalogProgress.storageKey] as? [[String: Any]] else { return [] }
        return list.prefix(resumeEntries).compactMap { entry in
            guard let slug = entry["slug"] as? String, let name = entry["name"] as? String, !name.isEmpty else { return nil }
            let episode = (entry["epName"] as? String).flatMap { $0.isEmpty ? nil : " — \($0)" } ?? ""
            return (slug, name + episode)
        }
    }

    // MARK: Building blocks

    private final class Action: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func fire() { run() }
    }
    private var actions: [Action] = []

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = [.command],
                     _ run: @escaping () -> Void) -> NSMenuItem {
        let action = Action(run)
        actions.append(action)
        if actions.count > 64 { actions.removeFirst(actions.count - 64) }
        let item = NSMenuItem(title: title, action: #selector(Action.fire), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = action
        item.representedObject = action   // the item only holds its target weakly; this keeps the closure alive
        menu.addItem(item)
        return item
    }
}

extension AppDelegate {
    func aiDubPreference() -> Bool {
        (catalogStorage?.get(keys: MenuBarController.aiDubKey)[MenuBarController.aiDubKey] as? NSNumber)?.boolValue ?? false
    }

    func toggleGhostFromMenu() {
        let state = toggleGhostPreferringWindow()
        tellCatalog(["type": "NATIVE_STATUS_BROADCAST", "connected": true, "isGhost": state])
    }

    /// Flip the dubbing preference (what new players start with) and the open player, and tell the page.
    func toggleAIDubFromMenu() {
        let enabled = !aiDubPreference()
        catalogStorage?.set([MenuBarController.aiDubKey: enabled])
        tellCatalog(["type": "AI_DUB_PREF", "enabled": enabled])
        floatWindow?.setAIDubEnabled(enabled)
    }

    /// Resume a "Tiếp tục xem" entry through the catalogue page, which knows how to build the request.
    func resumeFromMenu(slug: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: [slug], options: []),
              let json = String(data: data, encoding: .utf8) else { return }
        catalog?.webView.evaluateJavaScript("window.floatContinueBySlug && window.floatContinueBySlug(\(json)[0])", completionHandler: nil)
    }
}
