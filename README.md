# VibeFloat (FullFloatPiP)

**English | [中文](README-zh.md)**

**A movie catalogue and a player that floats over EVERYTHING — including fullscreen apps.**

VibeFloat is a standalone macOS app. Browse movies in its own window, press **Phát nổi**, and the video floats in a borderless window above every other app — fullscreen Terminal, fullscreen IDE, fullscreen anything — on every Space. Built for developers who vibe code with a film, a tutorial or a stream playing alongside their work.

<p align="center">
  <img src="docs/demo.png" alt="VibeFloat floating over a fullscreen Terminal" width="640">
  <br>
  <sub><i>The player floating above a fullscreen Terminal.</i></sub>
</p>

## What it does

- **Catalogue window** — a home page with a billboard and rows (cinema, dubbed, series, anime, films), search, categories, genres and countries, an endless grid, and a detail window with episodes and similar titles. Move between cards with the arrow keys; rest the pointer on a card for a preview.
- **Your lists** — *Danh sách của tôi* (favourites), *Tiếp tục xem* with progress bars, *Đã xem* (mark watched / unwatched) and *Đã ẩn* (hide movies you do not like; everything hidden disappears from every row and list, and can be restored). Right-click a card, use its ⋯ button, or press **W** (watched) / **H** (hide) on a selected card.
- **YouTube films** — a reviewed list of recent Asian films from publisher channels, with search and filters. See the [selection policy](docs/youtube-movies.md).
- **Floating player** — always on top, on all Spaces, YouTube-style controls, seek, volume, speed, size presets, opacity, click-through, episode navigation with auto-next and skip-intro, optional offline Vietnamese dubbing.
- **Menu bar and Dock menu** — open the catalogue, pause or close the player, resume something, switch click-through and AI dubbing, quit.
- **Global shortcuts** while a player is open (for example ⌘⇧G click-through).

## Installation

Requirements: macOS 12 (Monterey) or later and the Xcode Command Line Tools. No browser is needed.

```bash
xcode-select --install                      # once, if you have no Command Line Tools
git clone https://github.com/Sigmame/full-float-pip.git
cd full-float-pip
./scripts/install.sh
open "$HOME/Library/Application Support/FloatVideo/VibeFloat.app"
```

The script compiles the app, installs it to `~/Library/Application Support/FloatVideo/` with the catalogue inside the bundle, signs it ad hoc for this Mac, and removes the files the old Chrome setup left behind. Quit the app (⌘Q) and open it again after reinstalling. To remove it: `./scripts/uninstall.sh` (keeps your saved lists; `--purge` deletes them too).

## Using it

1. Open VibeFloat. Pick a movie (card, hero, detail window) and press **Phát nổi**.
2. Switch to any app, even fullscreen: the player stays on top. Closing the catalogue window does not stop it.
3. Controls appear on hover over the player: drag the title bar to move, click the timeline to seek, ESC closes, drag an edge to resize (aspect ratio is locked).

**Sizes.** The player menu offers Small (480 pt), Medium (640 pt) and Wide (up to 960 pt); the last choice is remembered. Wide fits within 75% of the visible screen width and an 85% height budget including its controls, and placement keeps the chosen size when it can.

**Defaults.** Click-through starts **off** and is never switched on automatically. AI dubbing starts **off** and needs an explicit toggle; offline dubbing in the player also starts off.

## Safety scope

- The catalogue reaches only the movie providers (`phimapi.com`, `ophim1.com`, `ophim.com`, `nguonc.com`, `streamc.xyz`, `kkphim.com`, `kkphimplayer.com`, `kkphimplayer6.com` and their subdomains) and the artwork host `phimimg.com`. Requests go through the app: GET/HEAD only, HTTPS, no cookies, a 12 MB cap, redirects re-checked against the same list. The page cannot frame anything and has a Content-Security-Policy.
- The player restricts remote page and iframe navigation to those providers; media CDN requests remain available. YouTube plays only for the exact video ids in the reviewed list.
- The catalogue's data (favourites, marks, progress, caches) is one private JSON file, `~/Library/Application Support/FloatVideo/catalog-storage.json`.
- The local control tool `scripts/vibe-sync.sh` reads a private token from `~/.floatvideo_token` while the app runs; direct HTTP calls to `/api/` need the `X-VibeFloat-Token` header.

## How it works

```
VibeFloat.app
 ├─ Catalogue window  ── WKWebView showing native-app/Catalog (HTML/CSS/JS) from the bundle as vibe://app/
 │                         └─ Swift bridge: storage, network, "Phát nổi", status        (CatalogBridge.swift)
 ├─ Floating player   ── NSPanel above fullscreen apps, on all Spaces                  (FloatWindow.swift)
 ├─ Local HTTP server ── YouTube embed pages with a valid Referer, the /api/ control API (LocalHTTPServer.swift)
 └─ Menu bar + Dock   ── quick actions                                                  (MenuBarController.swift)
```

- `FloatWindow.swift` creates an `NSPanel` at window level `maximumWindow + 1` with collection behaviour `canJoinAllSpaces` + `fullScreenAuxiliary`, which is what lets it float above fullscreen apps and appear on every Space.
- `CatalogWindow.swift` / `CatalogBridge.swift` / `CatalogSupport.swift` serve the bundled UI, answer its `chrome.*`-style calls, and hold the pure, tested parts (network policy, file paths, storage, progress).
- `native-app/Catalog/` is the whole catalogue UI: `catalog.html|css|js`, `movie-service.js` (providers, caches, lists), `site-access.js` (the reviewed YouTube films), `dub-preference.js`.
- Video loading: direct stream URLs play in a `<video>`; reviewed YouTube films use the local-server embed; provider embeds load in the player's `WKWebView`.

### Coming from the Chrome extension

The Chrome extension and its native-messaging host are gone. What the extension did that the app can no longer do: detect `<video>` elements on pages open in your browser and float them from there, and speak page captions for a browser tab. Everything else — the catalogue, the lists, the YouTube films, the floating player and its controls — is in the app. Favourites and marks saved inside the extension are not copied over. The installer removes the old native-messaging manifest; remove the extension itself at `chrome://extensions`.

## Development

```bash
cd native-app
swift build                                   # debug build
for t in Catalog/tests/*.test.js; do node "$t"; done
swiftc -swift-version 5 Sources/CatalogSupport.swift tests/catalog-support.swift -o /tmp/catalog-support && /tmp/catalog-support
```

`VIBEFLOAT_HOME=/some/folder` keeps the app's data, port file and token out of your real home; `VIBEFLOAT_CATALOG_DIR` serves the catalogue from a folder instead of the bundle (edit the UI without reinstalling); `VIBEFLOAT_CATALOG_SELFTEST_JS` / `_OUT` run a script in the loaded window and write its JSON result.

## Known limitations

- **DRM content** (Netflix, Disney+ and other Widevine platforms) cannot play in the floating window.
- **Sign-in is not shared** with your browser; sites that need a login are not supported.
- **macOS only** (12+), built and signed locally; there is no notarised download yet.

## License

MIT

## Contributing

Issues and pull requests are welcome. Please open an issue first to discuss significant changes.
