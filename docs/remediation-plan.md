# VibeFloat — Kế hoạch xử lý toàn bộ vấn đề

Nguồn: `docs/security-review.md`. Thứ tự dưới đây là **thứ tự commit**, không chỉ là thứ tự ưu tiên — mỗi phase build/verify được độc lập để có thể dừng giữa đường mà không để lại trạng thái nửa vời.

Nguyên tắc chung:
- Mỗi phase = 1 nhánh/bundle commit riêng, có tiêu chí nghiệm thu riêng.
- Kiểm tra biên dịch: `cd native-app && swift build`. Extension không có test → verify thủ công theo checklist.
- **Không** đổi hành vi sản phẩm (nổi trên mọi app, chặn popup, tự động phát) trừ khi phase đó nói rõ.

---

## Phase 0 — Chốt baseline (làm trước mọi thứ)

1. Ghi lại "hợp đồng" hiện tại của message native → sửa thành nguồn sự thật duy nhất trong `docs/`.
2. Xác nhận `git status` sạch trước khi sửa; `.freebuff/` là untracked của công cụ, **không** đụng vào.
3. Smoke test thủ công trước khi sửa, để so sánh sau khi sửa:
   - YouTube: float video đang xem → phát được, không cần đăng nhập lại.
   - TikTok (link rút gọn `vt.tiktok.com`) → resolve + phát.
   - Phim (phimapi/ophim/nguonc) → phát được server thuyết minh/vietsub mặc định.
   - Hotkey `⌘⇧Space` pause/resume; `⌃⌥[`/`⌃⌥]` prev/next tập.
   - `scripts/vibe-sync.sh` gọi `/api/` thành công.

---

## Phase 1 — Pathway cookie (P0, rủi ro cao nhất)

**Mục tiêu:** sau phase này, app **không** còn đọc/giữ cookie Google, và cookie đến native bị giới hạn cứng.

**Trạng thái: ĐÃ TRIỂN KHAI trong working tree** (chưa commit; `swift build` sạch, `node --check` sạch).

- [x] `extension/background.js:155-177` — bỏ hẳn `chrome.cookies.getAll({ domain: '.google.com' })`.
- [x] Thêm hằng `YOUTUBE_SESSION_COOKIE_NAMES` (`background.js:7-17`) và lọc theo đó: `SID`, `HSID`, `SSID`, `APISID`, `SAPISID`, `SIDCC`, `LOGIN_INFO`, `__Secure-1P/3P` (SID, PAPISID, PSIDTS, PSIDCC).
- [x] Payload cookie rút còn `{name, value, secure}` — không còn `domain`/`path`/`httpOnly`.
- [x] `FloatWindow.swift:1365-1422` (`injectCookies`) — allowlist tên phía native (`mirrorableCookieNames`), domain/path **cố định** (`.youtube.com`, `/`), không còn `?? ".youtube.com"` và không còn tin `domain` từ message; entry không hợp lệ bị đếm vào `skipped`.
- [x] Cookie tiền tố `__Secure-` được ép `Secure` để không bị engine coi là không hợp lệ.
- [x] Comment in-code ghi rõ `HTTPCookiePropertyKey` không có khoá `httpOnly` → lý do phải giới hạn số cookie.
- [x] Log native đổi thành `Injected N session cookies (skipped M)` để phát hiện việc lọc quá tay.
- [x] Gỡ `https://*.google.com/*` khỏi `extension/manifest.json` (đã đối chiếu: chỉ `background.js:150` cũ dùng quyền này).

**Tiêu chí nghiệm thu — cần chạy tay:**
1. Load lại extension trong `chrome://extensions` (đổi `host_permissions` nên phải **reload**, không chỉ refresh tab).
2. Float một video YouTube khi **đang đăng nhập**: phải vào đúng tài khoản, không hiện nút Sign in. Nếu hiện Sign in → thiếu tên cookie trong allowlist; thêm tên đó, **tuyệt đối không** khôi phục đường Google.
3. Xoá WebView data store (hoặc float lần đầu trên máy sạch) → vẫn đăng nhập được nhờ cookie mirror.
4. Log `[FloatVideo]` phải hiện `Injected N session cookies (skipped 0)`; `skipped > 0` là dấu hiệu extension và native lệch allowlist.
5. Trong float window mở DevTools (`preview_evaluate` không dùng được cho WKWebView) → xác nhận `document.cookie` chỉ chứa cookie YouTube, không có cookie Google nào.

**Đánh đổi đã chấp nhận:** nếu phiên YouTube đã hết hạn, WebView có thể hiện trang đăng nhập Google thay vì tự vào (trước đây cookie Google che được việc này). Đây là hành vi mong muốn: đăng nhập trong cửa sổ nổi (cookie lưu lại trong data store của app) thay vì âm thầm mang toàn bộ phiên Google sang.

---

## Phase 2 — Escape & validate HTML nhúng (P0)

**Trạng thái: ĐÃ TRIỂN KHAI trong working tree** (chưa commit; `swift build` sạch). Số dòng dưới đây là số **mới**, sau khi thêm khối helper ở `FloatWindow.swift:1246`.

- [x] `FloatWindow.swift:1246-1377` — khối `// MARK: - Untrusted Input Handling` gồm toàn bộ helper dùng chung: `sanitizedURL`, `hostMatches`, `validateMediaURL`, `documentBaseURL`, `isSafeMediaSource`, `escapeHTML`, `escapeJSString`, cùng các allowlist (`allowedEmbedDomains`, `plainHTTPHosts`, `forbiddenSchemes`, `cookieBearingHosts`).
- [x] `escapedSrc` trong `buildVideoHTML` (`FloatWindow.swift:2055-2060`) — **đính chính kế hoạch**: giá trị này nằm trong **literal chuỗi JavaScript** của `<script>`, không nằm trong markup. Escape HTML ở đây là **sai** (nó biến `&` thành `&amp;` và làm hỏng query string hợp lệ) và cũng **không chặn được** `</script>` vì trình phân tích HTML không giải mã entity bên trong `<script>`. Cái đúng là escape JS: `escapeJSString(videoSrc, quote: "\"")` — chuỗi `</script><script>alert(1)</script>` trở thành `\u003c/script\u003e...`, không thể đóng thẻ script.
- [x] `FloatWindow.swift:2406` — `buildEmbedHTML` escape `embedUrl` bằng `escapeHTML` (ngữ cảnh **thuộc tính** HTML, ở đây full HTML escape mới đúng).
- [x] `FloatWindow.swift:1673` — `showEmbedFailure` dùng `escapeJSString` thay cho việc tự nối `\\`/`\'` bằng tay (bản cũ bỏ sót newline).
- [x] `FloatWindow.swift:2531` — `injectVideoMaximize` escape `site` trong `const site = '...'`.
- [x] `validateMediaURL(_:)` (`FloatWindow.swift:1296`) — chỉ nhận `https` tới host trong allowlist (khớp cả subdomain), hoặc `http` **chỉ** với loopback (`127.0.0.1`/`localhost`/`::1`) cho server `/play` cục bộ. Từ chối `javascript:`, `data:`, `blob:`, `file:`, `filesystem:`, `about:`, `vbscript:`, host lạ, chuỗi rỗng, và mọi chuỗi chứa `" ' < > \` \` ` hoặc ký tự điều khiển (chặn trước cả khi dựng `URL`).
- [x] `FloatWindow.swift:1436` — `baseURL` của nhánh direct video đi qua **`documentBaseURL(for:)`** thay vì `validateMediaURL` trực tiếp. Hàm này thêm một luật nằm ngoài kế hoạch ban đầu nhưng đúng vào "bề mặt bị bỏ sót" đã ghi ở báo cáo: `loadHTMLString(_:baseURL:)` biến `baseURL` thành **origin của tài liệu**, nên nếu `videoSrc` trỏ vào một origin mà app đang giữ cookie phiên (`.youtube.com`, `.google.com`, `youtu.be`) thì trang player nội tuyến sẽ **cùng origin** với phiên đã đăng nhập và đọc được cookie qua `document.cookie`. Luật: host thuộc `cookieBearingHosts` → trả `nil` (log lại), còn lại dùng nguyên URL stream để giữ nguyên hành vi Referer/tương đối. Host không nằm trong allowlist cũng → `nil` theo đúng kế hoạch.
- [x] `FloatWindow.swift:1469-1485` — nhánh priority 3 (embed nạp trực tiếp): chỉ `URLRequest` khi `validateMediaURL` qua; nếu không thì log `Refused embed URL outside the allowlist` và **rơi xuống priority 4** (nạp cả trang) thay vì nạp URL lạ.
- [x] `FloatWindow.swift:2035` — `fallbackToEmbedIfDirectFailed` từ chối embed ngoài allowlist, log rõ lý do.
- [x] `FloatWindow.swift:2001-2003` và `2018-2020` — hai nhánh `didFail`/`didFailProvisionalNavigation` cũng validate `currentEmbedUrl` trước khi dựng iframe (trước đây dùng thẳng `currentEmbedUrl`, vốn được gán từ message ở `loadVideo` mà không kiểm tra).
- [x] Kiểm tra phía `LocalHTTPServer.swift`: `handlePlayRequest` (`:150-160`) đã clamp `w`/`h` bằng `min(max(Int(...) ?? 640, 200), 1920/1080)`, `site` phải `== "youtube"`, `videoId` phải khớp `^[A-Za-z0-9_-]{11}$`; `startSeconds` là `Int` đã `max(…, 0)` (`:176`); `origin` chỉ ghép từ `port` dạng số. **Không có** nội suy chuỗi thô nào tới được.
  - Còn đúng **một** điểm nội suy chưa an toàn: `LocalHTTPServer.swift:337` `<iframe src="\(videoId)"` trong `buildGenericEmbedHTML`. Đã xác minh hàm này **không có caller nào** trong repo → là code chết, không tiếp cận được. Xử ở Phase 6 (xoá) hoặc phase dọn dẹp; chưa đụng vào để giữ diff của Phase 2 gọn.

**Kiểm chứng đã chạy (thay cho unit test — xem ghi chú dưới):** trích nguyên văn khối helper từ `Sources/FloatWindow.swift` (bằng `sed` theo marker, không chép lại code) rồi chạy 41 assertion bằng `swift -`. Kết quả: `ALL CHECKS PASSED` — gồm `</script><script>alert(1)</script>` không còn `<`/`>`; `" onload="alert(1)` không còn `"`; `javascript:`/`data:`/`blob:`/`file:`/`about:`/host lạ/chuỗi rỗng đều bị từ chối; `https://www.youtube.com/...` bị từ chối làm `baseURL` nhưng vẫn qua `validateMediaURL`; URL stream hợp lệ giữ nguyên query string.

**Vì sao không có target test trong `Package.swift` (đính chính tiêu chí nghiệm thu):** máy này chỉ có Command Line Tools, **không có `XCTest` lẫn module `Testing`** (`import XCTest` → `no such module`). Nâng `swift-tools-version` lên 6.0 để dùng swift-testing sẽ bật Swift 6 language mode và làm **hàng loạt** file hiện có lỗi strict-concurrency (`AppDelegate.swift:369`, `:425`, …) — ngoài phạm vi. Vì vậy: **không** thêm test target; giữ harness chạy bằng `swift -` như trên. Muốn có test thật thì cần một phase riêng (tách phần pure logic ra module riêng hoặc nâng toolchain lên Xcode đầy đủ).

**Còn phải chạy tay (không thực hiện được ở đây):**
1. Float bình thường cả 3 nhóm: YouTube (đang đăng nhập), TikTok, phim (phimapi/ophim/nguonc) → phải phát như trước. Đây là điều kiện quan trọng nhất: allowlist là **mới siết**, nên nếu một nhà cung cấp embed dùng host không có trong `allowedEmbedDomains` thì luồng sẽ tụt xuống nạp cả trang và có thể hỏng.
2. Khi nghi ngờ: đọc log `[FloatVideo]` tìm `Refused embed URL outside the allowlist` / `Refused direct-embed fallback` / `Not using cookie-bearing origin as document base`. Gặp dòng "Refused" mà nội dung đó **nên** phát được → thêm domain của nhà cung cấp vào `allowedEmbedDomains` (`FloatWindow.swift:1253`), không nới theo hướng khác.

---

## Phase 3 — Navigation policy (P1)

**Trạng thái: ĐÃ TRIỂN KHAI** (`swift build` sạch).

- [x] `FloatWindow.swift:2032` — thêm `webView(_:decidePolicyFor:decisionHandler:)`.
- [x] **Tái dùng helper Phase 2** (`forbiddenSchemes`, `hostMatches`, `plainHTTPHosts`) — không có allowlist thứ hai. Allowlist top-level (`FloatWindow.swift:1321`) = `allowedEmbedDomains` **cộng** một số domain chỉ hợp lệ ở tầng tài liệu: `google.com` (bắt buộc, vì đăng nhập YouTube rơi vào `accounts.google.com`), `googlevideo.com`, `gstatic.com`, `ytimg.com`, CDN của TikTok, `akamaized.net`/`cloudfront.net`/`fastly.net`/`jsdelivr.net`.
- [x] Phân tầng theo frame, có chủ đích:
  - `about:` → cho phép (trang player nội tuyến của chính app).
  - host loopback → cho phép (server `/play` cục bộ).
  - scheme thuộc `forbiddenSchemes` → `cancel` + log, **mọi** frame.
  - `targetFrame == nil` (yêu cầu mở cửa sổ mới) → `cancel` + log.
  - frame con / tài nguyên con → cho phép (các player kéo từ hàng chục CDN, siết host ở đây chỉ tạo allowlist mục nát).
  - tài liệu top-level → **bắt buộc** `https` + host trong allowlist, nếu không thì `cancel` + log `Blocked top-level navigation outside allowlist` (`:2073`).
- [x] Không nuốt lỗi im lặng: mọi nhánh `cancel` đều có `NSLog` kèm URL rút gọn.
- [ ] **Chưa xác minh được ở đây** (không chạy được WKWebView): nhánh "redirect chuỗi nhiều bước" của netflix/twitch/youku. Nếu một embed hợp lệ bị chặn, log sẽ có dòng `Blocked top-level navigation`, và cách xử đúng là thêm domain của nó vào `allowedTopLevelDomains` — không phải nới thành "cho phép mọi https".

---

## Phase 4 — Hardening HTTP server cục bộ (P1)

**Trạng thái: ĐÃ TRIỂN KHAI** (`swift build` sạch).

- [x] `LocalHTTPServer.swift:78` — `writePrivateFile(_:to:)` dùng chung cho cả port và token: từ chối nếu đường dẫn là **symlink** (`destinationOfSymbolicLink`), xoá file cũ, tạo mới bằng `open(O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW, 0o600)`, ghi nội dung, `fchmod 0600`. Trước đây port ghi kiểu `write(atomically:)` (0644) và token ghi kiểu `createFile` — tức là **đi theo symlink** nếu có sẵn.
- [x] `LocalHTTPServer.swift` — `/play` yêu cầu capability riêng được tạo theo vòng đời server; `/health` yêu cầu API token. `Origin`/`Referer` ngoài loopback vẫn bị từ chối như defense in depth, nhưng không còn được dùng làm cơ chế xác thực vì trình duyệt có thể bỏ qua các header này.
- [x] `stop()` dọn cả `~/.floatvideo_token` **và** `~/.floatvideo_port`.
- [x] Listener vẫn chỉ `127.0.0.1` — không đổi.
- [x] `/play` dùng capability riêng trong query string vì WKWebView navigation không gắn được custom header. Capability này không có quyền gọi `/api/`; player HTML đặt `referrer` policy `no-referrer` để không chuyển capability cho iframe YouTube. `/health` dùng `x-vibefloat-token` như các endpoint `/api/`.
- [x] **ĐÃ CHẠY THẬT ở đây** — `LocalHTTPServer` chỉ phụ thuộc Foundation/Network/Darwin nên compile được thành executable kiểm tra mà không cần AppKit. Harness chạy **đúng file `Sources/LocalHTTPServer.swift`** (không sửa gì), 24/24 check pass:
  - `token file is 0600`, `port file is 0600`; port file chứa đúng port đang mở.
  - `/health` không Origin → 200 `OK`; có `Origin: https://evil.example` → **403**.
  - `/play` không Origin → 200 HTML (có `abcdefghijk` trong payload); Origin ngoài → **403**; **`Referer` ngoài → 403**; Origin loopback → 200; `Origin: null` → **403** (origin sandboxed/`file://` cũng bị coi là ngoài).
  - `/play?v=short` → 400; `site=tiktok` → 400; `w=99999&h=99999` → clamp thành `SAFE_W = 1920`.
  - `/api/status` đúng token → 200; token sai → 403; thiếu token → 403; path lạ → 404.
  - `stop()` xoá **cả** token lẫn port file.
  - Chế độ symlink riêng: đặt `~/.floatvideo_token` là symlink trỏ vào `sentinel.txt` → log `Refusing to write .floatvideo_token: symlink at path`, **sentinel không bị ghi**, symlink còn nguyên, port file vẫn ghi bình thường 0600.
- [x] Cách cô lập an toàn (đã dùng): `HOME` **không** được tôn trọng (`FileManager.homeDirectoryForCurrentUser` vẫn trả `/Users/anle`), nhưng **`CFFIXED_USER_HOME=/tmp/vibefloat-sbx`** thì có. Nhờ đó chạy được code thật mà không đụng vào `~/.floatvideo_*` thật. Cách dựng lại harness:
  ```bash
  mkdir -p /tmp/vibefloat-sbx
  swiftc -O -o /tmp/vibefloat-server-check \
      native-app/Sources/LocalHTTPServer.swift <harness>.swift
  CFFIXED_USER_HOME=/tmp/vibefloat-sbx /tmp/vibefloat-server-check normal
  CFFIXED_USER_HOME=/tmp/vibefloat-sbx /tmp/vibefloat-server-check symlink
  ```
  (Harness tạm đã bị xoá khỏi repo sau khi dùng — xem gợi ý ở cuối báo cáo về việc biến nó thành script thường trực.)
- [x] `scripts/vibe-sync.sh` không phải sửa: nó đọc đúng `$HOME/.floatvideo_port` + `$HOME/.floatvideo_token` (đường dẫn không đổi ở Phase 4) và **đã có sẵn** nhánh lỗi rõ ràng khi thiếu token — tức là khi `writePrivateFile` từ chối vì symlink, CLI báo `control token is missing` thay vì gửi token sai. Failure mode kín và dễ đọc.
- [ ] **Chưa chạy được:** `./scripts/vibe-sync.sh status` với app thật đang chạy (ở đây không bật được app GUI).

---

## Phase 5 — Cấu hình & khởi động (P1)

**Trạng thái: ĐÃ TRIỂN KHAI.**

- [x] `scripts/install.sh` — bỏ hẳn fallback `EXT_ID="*"`. Chuẩn hoá input (bỏ khoảng trắng, hạ chữ A–P) rồi validate `^[a-p]{32}$`; sai/rỗng → in hướng dẫn lấy ID và `exit 1` **trước khi** ghi manifest.
  - Đã kiểm phần validate bằng bash: `""`, `"*"`, chuỗi 32 ký tự chứa `q`–`z`, đều **REJECT**; ID đúng dạng (chỉ a–p, 32 ký tự, có/không khoảng trắng) **ACCEPT**.
- [x] `FloatWindow.swift:2563` — `runJavaScriptConfirmPanelWithMessage` → `completionHandler(false)` + log message đã bị từ chối.
- [x] `FloatWindow.swift:2554` — `runJavaScriptAlertPanelWithMessage` → vẫn đóng ngay (không có ai ngồi bấm OK) nhưng **log lại** message, nên page "nagging" hoặc player kẹt vòng lặp để lại dấu vết.
- [ ] **Chưa test được:** nhánh resume dựa vào `confirm()` của một số player. Trước đây họ được tự động trả `true`; nay là `false`. Playlist phim (tự chuyển tập) đã có luồng riêng nên nhiều khả năng không dùng `confirm()`; cần xác nhận bằng cách xem log tìm dòng `Page confirm denied` khi phát phim.

---

## Phase 6 — Trải nghiệm phím & dọn quyền (P2)

**Trạng thái: ĐÃ TRIỂN KHAI** (trừ 1 mục tuỳ chọn, xem dưới).

- [x] `VibeDock.swift:660` — thêm `VibeHotkeys.uninstall()`: `UnregisterEventHotKey` toàn bộ, `RemoveEventHandler`, xoá `actions`. Thêm `isInstalled` (`:672`) để `install` trở thành idempotent.
- [x] `AppDelegate.swift:382` — tách `installHotkeys()` ra khỏi `applicationDidFinishLaunching` (nơi trước đây đăng ký ngay lúc launch, khi chưa có player nào).
- [x] Gọi `installHotkeys()` trong `openFloatWindow`; gọi `hotkeys.uninstall()` ở **cả** `closeFloatWindow` **và** closure `onClose` (đóng cửa sổ trực tiếp không đi qua `closeFloatWindow`, nếu chỉ sửa một chỗ thì `⌘⇧G` vẫn bị nuốt tới lúc thoát app).
- [x] **Đổi cách xử `⌘⇧G`:** thay vì đổi tổ hợp (là quyết định UX của bạn, xem câu hỏi ở phần cuối), vấn đề gốc đã được giải: hotkey **chỉ tồn tại khi cửa sổ nổi đang mở**.
- [x] Thêm công tắc tắt toàn bộ hotkey trong menu `•••` — `FloatWindow.swift:576` (`onToggleHotkeys`), `:5457`, AppDelegate `installHotkeys/uninstall`; trạng thái lưu ở `UserDefaults` key `vibefloat.globalHotkeysEnabled` và sống qua lần float sau.
- [x] `extension/manifest.json` — gỡ `tiktokv.com`, `tiktokcdn.com`, `byteoversea.com`. Đã grep lại `extension/`: sau khi gỡ, không còn tham chiếu nào ngoài `manifest.json` (đã đối chiếu: cả 3 chỉ xuất hiện đúng 1 lần, ở `host_permissions`).
- [x] Xoá code chết `LocalHTTPServer.buildGenericEmbedHTML` — hàm này không có caller nào và là **điểm nội suy `<iframe src="\(videoId)">` chưa an toàn** duy nhất còn lại ở phía Swift (ghi ở Phase 2). Xoá luôn cđả hàm thay vì escape code chưa bao giờ chạy.
- [ ] (Tuỳ chọn) Tách world cho script inject (`WKContentWorld`) — **chưa làm**. Toàn bộ script hiện chạy chung main world của trang, nên JS của trang gọi được `window.__floatVideoApplyLayout` v.v. Mức độ: thấp (các hàm đó chỉ là layout player, không cầm token). Đây là việc lớn — tách world sẽ phải chuyển cả kênh `evaluateJavaScript` sang `callAsyncJavaScript`/world riêng, rủi ro cao hơn lợi ích ở thời điểm này.

**Tiêu chí nghiệm thu — phần chạy được ngay:** đóng cửa sổ nổi → `⌘⇧Space`/`⌘⇧B`/`⌘⇧G` trả lại cho hệ thống/editor; mở lại → hotkey hoạt động trở lại; tắt bằng `•••` → đóng/mở lại vẫn tắt (đã lưu).

---

## Tính năng sản phẩm (yêu cầu mới, ngoài báo cáo bảo mật)

### A. Tuỳ chọn tự cuộn TikTok

**Trạng thái: ĐÃ TRIỂN KHAI.** Ghi chú: đây là thay đổi **hành vi**, không phải hardening.

- [x] `FloatWindow.swift:601` — `preferredTikTokAutoScroll`, lưu ở `UserDefaults` key `vibefloat.tiktokAutoScroll`, **mặc định BẬT** (đúng trạng thái "xem như trên web" mà bạn yêu cầu). Tắt bằng nút trên thanh điều khiển hoặc menu `•••`; lựa chọn được nhớ cho lần float sau.
- [x] Logic chạy trong page, gắn vào nhánh `site === 'tiktok'` của `injectVideoMaximize` (`FloatWindow.swift:2941-2970`): lắng nghe `ended` ở **capture** trên `window` (event `ended` không bubble, nhưng capture vẫn bắt được), chỉ tiến khi video đó **chính là** `__floatVideoMainVideo`, và chỉ một lần cho mỗi item (`__tiktokAutoScrollAdvancing`, mở khoá sau 1.6 s). Cuộn bằng `scrollBy({top: innerHeight})` — **đúng cử chỉ** mà điều hướng thủ công (`↓`/`j`/`PageDown`) đang dùng, nên `scroll-snap` và lazy-load của feed vẫn hoạt động.
- [x] Video TikTok mặc định `loop`, mà video loop thì **không bao giờ** bắn `ended` → `__tiktokApplyAutoScroll()` tắt `loop` trên các video khi tính năng đang bật. Đây là chi tiết quyết định cả tính năng này có chạy hay không.
- [x] Điều khiển: nút `arrow.down.circle` / `.fill` màu xanh khi bật, **chỉ hiện khi `currentSite == "tiktok"`** (`FloatWindow.swift:1166`, `:5463-5480`); thêm mục trong menu `•••`. Cờ native đẩy vào page ngay khi bấm; literal trong script inject seed giá trị lúc cài lần đầu.
- [x] Kiểm chứng: trích nguyên văn 2 payload JS từ `FloatWindow.swift` (theo marker, không chép tay), thay chỗ nội suy Swift, rồi `new Function(...)` bằng node → **cả hai parse OK**. `handleTikTokMedia` cũng ép `loop = false` cho video mới xuất hiện khi auto-scroll đang bật.
- [ ] **Chưa xác minh runtime:** cần mở một float TikTok và để một video chạy hết. Kỳ vọng: hết video → tự cuộn mượt sang item kế và item kế tự phát. Nếu cuộn mà item mới **không** tự phát, thủ phạm là `handleTikTokMedia` chưa gọi `play()` cho item mới — sửa ở đó, không sửa ở khối auto-scroll.

### B. Cửa sổ ôm sát khung phát

**Trạng thái: ĐÃ TRIỂN KHAI.** Mặc định **BẬT**.

- [x] `FloatWindow.swift:591` — `preferredHugVideoFrame`, key `vibefloat.hugVideoFrame`.
- [x] Nguồn số đo: `pollVideoState` (đã chạy sẵn 0.5 s/lần) giờ trả thêm `vw`/`vh` của **`__floatVideoMainVideo`** (`FloatWindow.swift` trong payload JS), native đọc và gọi `adoptVideoAspectRatio` (`:4106`). Không thêm vòng polling mới.
- [x] `adoptVideoAspectRatio`: chặn hai đầu 0.35–3.2 (giá trị ngoài khoảng là số đo hỏng — video 0 chiều cao, slot quảng cáo); chỉ nhúc khi lệch > 0.012 nên không rung; cập nhật `videoAspectRatio` + `contentAspectRatio`, **tính lại `minSize`/`maxSize`** (`applySizeConstraints`, tách ra từ `configureWindow`); giữ **cạnh trên và tâm ngang** nên video như reflow tại chỗ; kẹp vào `maxSize` rồi vào `visibleFrame`; `setFrame(animate: false)` (mỗi frame trung gian của animation làm WebView re-layout → giật hình đang phát).
- [x] **Không chống lại người dùng:** `userLockedSize` bật khi kéo cạnh resize (`mouseDragged`) hoặc khi chọn preset. Quan trọng: `applySizePreset` nhận thêm `fromUser: Bool = true` — `show()` gọi `fromUser: false` khi khôi phục cỡ nhớ sẵn, nếu không thì preset-tự-động lúc mở sẽ **khoá tính năng ôm khung ngay từ đầu**, mỗi lần float.
- [x] Menu `•••` — "✓ Ôm sát khung phát" (bật/tắt) và "Ôm lại khung ngay" (bỏ khoá, ôm lại một lần ngay).
- [ ] **Chưa xác minh runtime:** mong đợi dễ thấy nhất là YouTube Shorts / video dọc (tỉ lệ 9:16) trong cửa sổ ngang, và phim 2.39:1 trong cửa sổ 16:9 — phải hết hai vệt đen. Embed **khác origin** (netflix/twitch/youku) **không** ôm được: `videoWidth` nằm trong iframe cross-origin, không đọc được — hành vi giữ nguyên như trước.

---

## Thứ tự thực hiện đề xuất

```
Phase 0 (baseline) → Phase 1 (cookie) → Phase 2 (escape) → Phase 3 (nav policy)
→ Phase 4 (http server) → Phase 5 (install/confirm) → Phase 6 (hotkey/host perms)
```

Phase 1 và 2 nên làm **cùng một đợt release** vì chúng bù trừ cho nhau theo đúng nghĩa: escape làm giảm khả năng chèn script, còn giới hạn cookie làm giảm giá trị của việc chèn script thành công. Làm 1 mà bỏ 2 thì chuỗi khai thác vẫn liền.

## Kiểm chứng chung sau mỗi phase

- `cd native-app && swift build` — phải sạch, **không warning**. Đã chạy sau mọi thay đổi của Phase 3–6 và 2 tính năng.
- `node --check extension/background.js`, parse `extension/manifest.json`, `bash -n scripts/install.sh` — đã chạy, sạch.
- Checklist smoke test ở Phase 0 chạy lại đầy đủ, không regression.
- Đọc `NSLog` với prefix `[FloatVideo]` để chắc các nhánh fallback vẫn đi đúng đường (không bị validation mới chặn nhầm).

## Trạng thái tổng: còn lại đúng những gì không máy nào tự làm được

Tất cả 7 phase đã triển khai trong working tree (**chưa commit**) cộng 2 tính năng mới. Những dòng `[ ]` còn lại trong tài liệu này **không phải việc chưa làm** — chúng là bốn loại sau, và mỗi loại đã ghi rõ cách xử:

1. **Chỉ xác minh được khi chạy app/Chrome thật** — Phase 3 (redirect nhiều bước), Phase 4 (`vibe-sync.sh` với app đang chạy), Phase 5 (`confirm()` của player), tính năng A, tính năng B. Không có đường tắt: các phần này đều nằm sau WebKit/AppKit/GUI.
2. **Cố ý đi lệch kế hoạch, có lý do ghi kèm** — không bắt buộc token cho `/play` (Phase 4).
3. **Quyết định UX của bạn, không phải của tôi** — đổi tổ hợp `⌘⇧G` trong Phase 6. Vấn đề gốc (nuốt phím khi không có cửa sổ nổi) đã được xử bằng vòng đời hotkey; đổi tổ hợp chỉ còn là sở thích.
4. **Cố ý hoãn, rủi ro > lợi ích ở thời điểm này** — tách `WKContentWorld` (Phase 6).

Cách kiểm nhanh nhất cho nhóm 1: mở float, rồi lọc log:

```bash
tail -f "$HOME/Library/Logs/FloatVideo/native-host.log" | grep -E "Refused|Blocked|Page confirm denied|Hugged|Injected|Not using cookie-bearing"
```

Bình thường sẽ thấy `Injected N session cookies (skipped 0)` và `Hugged video frame`. Thấy dòng `Refused`/`Blocked` cho nội dung **đáng ra phải chạy** = allowlist thiếu domain, thêm vào `allowedEmbedDomains`/`allowedTopLevelDomains` (`FloatWindow.swift:1253` và `:1321`) — **không** nới thành "cho phép mọi https".

## Audit follow-up fixes (2026-09-25)

- [x] Cookie mirror được dựng từ `Set-Cookie` response header với thuộc tính `HttpOnly`, và chỉ được đưa vào WKWebView khi `cookie.isHTTPOnly == true`.
- [x] Log native chỉ ghi scheme/host cho URL; query string, fragment, signed URL và capability không còn được ghi.
- [x] Installer dùng file tạm `mktemp`, mode `0600`, chặn symlink ở đích và thay thế bằng `mv`.
- [x] `sec.id`, `rating`, `rank`, `year` và `quality` từ API được escape trước khi đưa vào HTML.

## Audit follow-up fixes (2026-09-26) — thanh đen, quảng cáo trong ảnh, skip 9922

Ba lỗi người dùng báo trên stream `Phù Sa — Tập 23`: không cắt được thanh đen,
không blur được quảng cáo nằm trong ảnh, không skip được quảng cáo `9922.com`.

Phần dưới đây **không phải suy đoán**. Mỗi con số được đo bằng cách chạy
`VNRecognizeTextRequest` và các heuristic hiện có của app trên chính ảnh người
dùng gửi. Cách đo lại:

```bash
cd native-app && swift -   # dán đoạn load ảnh + Vision + heuristic của bạn
```

### A. Thanh đen — hai nguyên nhân, cả hai đã tái hiện được

**A1. Mực burn-in trong thanh phá phép dò "mọi điểm ảnh đen".** Bộ dò cũ đòi
`darkPixels >= 74/80` cho **mỗi** hàng, nên hàng chứa chữ trắng của dòng tài trợ
bị coi là "không phải thanh đen" và vòng quét đứt ngay: `top < 3`, `hasBars =
false`, `scale` giữ `1.0000`.

**A2. Một hàng sáng ở mép khung cũng đủ giết vòng quét.** Đây mới là cái quan
sát được trên ảnh thật. Quét hồ sơ độ sáng theo hàng (y/chiều cao → luma trung
bình) của ảnh người dùng:

| vùng | dải |
|---|---|
| thanh tiêu đề | ≈0.02–0.04, luma **43** (xám đậm, không tính là "đen") |
| thanh đen trên (có banner) | ≈0.045–0.14 |
| hình | ≈0.15–0.87 |
| thanh đen dưới | ≈0.872–1.00 |

Mô phỏng lại đúng 96×72 mà bộ dò lấy mẫu, tại mép nội dung WebView thật
(`y0=110/130`):

```
y0=110: bộ dò cũ top=1 bottom=61 -> NOCROP | bộ dò mới top=7 bottom=61 -> CROPS span=0.76
y0=130: bộ dò cũ top=1 bottom=60 -> NOCROP | bộ dò mới top=6 bottom=60 -> CROPS span=0.76
y0=90:  bộ dò cũ top=0 bottom=61 -> NOCROP | bộ dò mới top=0 bottom=61 -> NOCROP
```

`span=0.76` khớp với dải hình thật (0.10→0.86). Dòng `y0=90` cho thấy A2: hàng 0
là một vệt sáng (mép title bar) nên cả hai bộ dò đều đứng ở `top=0`. Bộ dò mới
đã được thêm dung sai này.

**Đã sửa:**
- [x] `smartFillJavaScript`: `dark(y)` (bool) → `darkRatio(y)` trả **tỉ lệ** điểm
      ảnh gần đen; `barRow(y) = darkRatio(y) >= 0.5`. Chữ burn-in là **thiểu số**
      trong hàng nên hàng vẫn là hàng thanh.
- [x] Thay phép "quét chuỗi từ hàng 0" bằng **tìm chuỗi dày nhất** trong 3 hàng
      đầu/cuối (`barRun`/`barRunUp`): một hàng sáng ở mép không còn giết vòng
      quét. Chuỗi phải dày `>= max(3, height/48)` mới tính.
- [x] `renderedLetterbox` (bản native cho khung cross-origin không đọc được
      pixel): cùng hai luật trên — `>= 0.92` → `>= 0.5`, cộng dung sai mép.
- [x] `tests/black-bars.test.js`: thêm kịch bản banner burn-in (4 và 7 hàng) và
      kịch bản **hàng 0 sáng**. Cả hai đã được xác nhận **fail với code cũ**
      (`scale(1.0000)`) và **pass với code mới** (`scale(1.3333)`).

`picture` vẫn kiểm 3 hàng giữa nên cảnh tối / fade-to-black không bị zoom, và
`hasBars` vẫn đòi cả hai thanh + dải hình ≥ 55%.

### B. Quảng cáo trong ảnh — detector trong trang chỉ thấy pixel của `<video>`

`#float-ad-blur` chỉ tồn tại trong `buildVideoHTML` (direct video);
`buildEmbedHTML` đặt `display: none`; đường `.fullPageInject` (player riêng của
provider) không có phần tử nào. Và ngay cả khi overlay có mặt, nó chỉ đọc được
pixel của chính `<video>` — một quảng cáo vẽ bằng markup trang, hay nằm trong
iframe cross-origin, là vô hình với nó.

**Đã sửa:**
- [x] Gộp thành `bannerBlurJavaScript` (một nguồn duy nhất, tự tạo overlay + CSS
      inline) và gọi `window.__floatInstallAdBlur(video)` ở **cả bốn** đường:
      direct video, embed frame (`installMovieEmbedAdScript`), full page
      (`injectVideoMaximize`); overlay chết ở `buildEmbedHTML` đã bỏ.
- [x] Overlay dùng chung `z-index: 2147483647` với video và **tái append xuống
      cuối `body`** để thắng thế bằng thứ tự DOM (video full-page bị ghim cùng
      z-index). `#float-ad-blur` được miễn trừ trong `hideNonAncestors`, nếu không
      "ẩn chrome trang" sẽ tắt luôn blur.
- [x] **Mới — cover do native điều khiển.** `window.__floatForceAdCover(on,
      full)` cho phép native che khung (`full`) hoặc chỉ dải trên (`band`) sau khi
      chính native đã nhận dạng quảng cáo trên ảnh render. Đây là đường duy nhất
      hoạt động với quảng cáo không nằm trong pixel của video. Native gọi lại mỗi
      lần quét; `forcedUntil = now + 4 s` là lưới an toàn để cover không dính lại
      nếu vòng quét dừng giữa quảng cáo.
- [x] `tests/banner-blur.test.js`: thêm cover cưỡng bức (`full` che 100% và blur
      mạnh, `band` chỉ dải trên, tắt được, hết hạn sau 4 s, không xếp chồng timer).

### C. Không skip được `9922.com` — ba tín hiệu cũ đều mù với creative thật

Đo trên chính khung quảng cáo người dùng gửi:

| tín hiệu | cấu hình | đo được | kết luận |
|---|---|---|---|
| `looksLike9922Splash` | `pale > 0.88`, `darkBorder >= 0.45` | `pale=0.842`, `darkBorder=0.009` | **FALSE** — creative đã đổi, không còn "thẻ sáng giữa viền tối" |
| `looksLikeSlotFrame` | `neon > 0.03` | neon: 0.038 (gốc), **0.023** (640), **0.023** (420), **0.026** (280) | **FALSE** ở mọi cỡ app thực sự lấy mẫu; hoạ tiết xanh bị downscale/JPEG xoá |
| OCR `fast` (đường direct video) | 280×158 JPEG q0.5 | chỉ trả `in` (h=0.633) | **mù** — không có chữ nào dùng được |
| OCR `accurate` | cùng 280×158 | `9922`, h=**0.228**, midY=0.544 | **đọc được** |

Creative thật, đọc bằng OCR `accurate` (ảnh gốc, quy về vùng nội dung):

```
9922                                                 h=0.210  w=0.300  midY=0.544
9922,COM - NƠI CƠ HỘI BẮT ĐẦU TỪ MỘT CÚ CHẠM.        h=0.066  w=0.845  midY=0.075
```

Và banner tài trợ (ảnh thứ nhất) — dòng chữ nằm trong thanh đen trên cùng:

```
Bộ phim này do : 9922.com tài trợ và công bố. Sản phẩm: Nổ Hũ, Game Bài   h=0.048 w=0.704 midY=0.920
VNgo Bắn Cá, Sòng Bài, Thể Thao. Rút tiền 24/7 nhận tiền trong tích tắc      h=0.056 w=0.702 midY=0.873
```

**Đã sửa:**
- [x] `Sources/AdClassifier.swift` (mới, thuần — không AppKit, không I/O) phân
      loại khung thành `none` / `banner` / `splash` theo OCR + **hình học hộp
      chữ**, không theo màu. Luật: brand ở cuối cùng (`9\s*9\s*2\s*2`, `99 22`,
      `chín chín hai hai`); CTA landing page đòi **cả hai** nửa câu (`cơ hội` +
      `bắt đầu`/`cú chạm`); splash khi hộp brand **cao `>= 0.10` và hẹp `<= 0.6`**
      (wordmark 0.21–0.23 × 0.16–0.30 so với dòng banner 0.048–0.11 × 0.70).
- [x] Ngưỡng rộng **và** cao cùng lúc là chủ đích: nếu chỉ đòi chiều cao, dòng
      banner (0.048–0.056, và tới ~0.11 nếu OCR gộp hai dòng) sẽ bị xếp nhầm là
      splash → seek → ăn mất phim. Có test riêng cho đúng ca biên này.
- [x] `FloatWindow.swift` dùng `readTextHits(in:accurate:)` (trả `[AdTextHit]`
      kèm hộp) thay `readText` cũ; `readText` giữ lại làm tiện ích ghi log.
- [x] `adWatch` (direct video): đổi OCR sang **accurate** và dùng classifier —
      đây là lý do trực tiếp đường này chưa bao giờ skip spot 9922.
- [x] `scanEmbedAdIfNeeded`: OCR chạy cho **mọi** chiến lược (kể cả full-page),
      phân loại rồi hành động theo loại: `splash` → skip + cover toàn khung;
      `banner` → chỉ blur dải trên, **không bao giờ** seek. Chính khả năng phân
      biệt này làm cho việc đọc khung ở full-page trở nên an toàn (trước đây
      OCR bị tắt hẳn cho full-page để tránh seek ăn phim).
- [x] `skipInterstitialAd`: nhận thêm `.fullPageInject` (trừ YouTube), tìm video
      bằng `window.__floatVideoMainVideo || #player || video`; ngân sách tua vẫn
      chặn ở 90 s như trước.
- [x] Test native thật: `tests/ad-classifier/main.swift` + `swiftc`, chạy bằng
      `tests/run.sh`. Fixture là **số đo thật** ở bảng trên, gồm cả ca chống
      false-positive: phụ đề có đúng từ khoá CTA, và câu tài trợ khi OCR gộp dòng.

`looksLike9922Splash` vẫn giữ nguyên trong code (nó kín, không false-positive) và
vẫn là một tín hiệu phụ cho `slot`. Nó chỉ không còn là tín hiệu duy nhất.

**Chạy lại toàn bộ:**
```bash
cd native-app && swift build     # sạch, không warning
./tests/run.sh                   # swiftc (ad-classifier) + node (các file .test.js)
./tests/run.sh black-bars        # lọc theo tên
```

**Còn phải xác minh trên máy có app:** mở đúng stream `Phù Sa` và xem log
`[FloatVideo]` cho `kind=splash` (tua) / `kind=banner` (blur) và
`Hugged video frame` cho phần cắt thanh đen.

---

## Công cụ: `tools/diagnose` — đo offline trên ảnh chụp bất kỳ

Ba lỗi ở mục trên đều đã được tìm ra bằng cách chạy detector thật trên ảnh người
dùng gửi, chứ không phải bằng đọc code. Bước đó giờ được đóng gói lại:

```bash
cd native-app
tools/build-diagnose.sh
.build/vibefloat-diagnose shot.png --content 5 100      # ảnh chụp trọn cửa sổ
.build/vibefloat-diagnose frame.png                      # ảnh chỉ có khung phim
```

Báo cáo gồm: hồ sơ độ sáng theo hàng, bảng OCR + quyết định của `AdClassifier`,
quyết định của **code thật** (`renderedLetterbox`, `looksLike9922Splash`,
`looksLikeSlotFrame`), hai bộ dò trong trang chạy bằng JavaScriptCore trên pixel
lấy từ ảnh, kèm mọi con số mà ngưỡng đang chấm, và kết luận app sẽ làm gì.

`--content TOP% BOTTOM%` khai báo vùng player trong ảnh. Ảnh chụp trọn cửa sổ có
thêm title bar của AppKit ở trên — bản snapshot thật của app thì không — nên cần
trừ nó ra (ví dụ `--content 5 100`). `--width` mặc định 640, đúng bằng mức app
giới hạn snapshot.

**Không có logic nào được chép lại.** `tools/build-diagnose.sh` trích
`looksLike9922Splash`, `looksLikeSlotFrame`, `renderedLetterbox` **nguyên văn** từ
`Sources/FloatWindow.swift` (chúng thuần hàm trên `CGImage`, chỉ bất khả truy cập vì
class quanh chúng cần AppKit), và script **dừng build** nếu trích thất bại — nên
công cụ không thể lặng lẽ chẩn đoán bằng logic cũ. `AdClassifier.swift` được
biên dịch thẳng. Hai script JS trong trang được đọc từ chính file Swift lúc chạy,
y như các test node đang làm.

Hai ví dụ thật (chính hai ảnh đã dẫn tới bản sửa này):

```
$ .build/vibefloat-diagnose paste-9922-ad.png --content 9 79
  brand     wordmark-shaped  9922                      h=0.219 w=0.306
  brand cta  9922 .COM - NƠI CƠ HỘI BẮT ĐẦU TỪ MỘT CÚ CHẠM.   h=0.065
  verdict: splash
  looksLike9922Splash: false   <- pale=0.876 (cần >0.88), darkBorder=0.043 (cần >=0.45)
  looksLikeSlotFrame:  false   <- neon=0.023 (cần >0.03)
  9922        : SKIP (splash) + full-frame cover

$ .build/vibefloat-diagnose paste-phu-sa-banner.png --content 5 100
  brand  Bộ phim này do : 9922.com tài trợ và công bố...  h=0.046 w=0.697
  verdict: banner
  smartFill transform: translateY(4.545%) scale(1.3091)   <- thanh đen ĐÃ được cắt
  black bars  : CROP
  9922        : BLUR top band only (no seek — the line is burned in for the episode)
```

Lần sau gặp một creative mới: chạy công cụ trước, đọc các con số, rồi mới sửa
ngưỡng — và thêm ảnh đó làm fixture cho `tests/ad-classifier` nếu nó đổi quyết định.

---

## Tăng cường âm thanh cho phim (2026-09-26)

Phim thường được trộn cho tai nghe; xem trên loa laptop thì lời thoại chìm dưới
tiếng nền. `HTMLMediaElement.volume` bị spec chặn ở 1.0, nên **không có** mức
"to" trên chính element — muốn nâng thật thì phải qua Web Audio.

**Bốn mức** (`AudioBoostLevel`): Không · Nhẹ (+40%, x1.4) · Vừa (x2.0) ·
Mạnh (x2.8), lưu ở UserDefaults `vibefloat.audioBoost`, mặc định **Không** — nó
đổi thứ người dùng nghe, nên để họ tự bật và giữ lựa chọn qua các lần mở.

**Chuỗi tín hiệu.** `createMediaElementSource(video)` → `GainNode` →
`DynamicsCompressor` làm limiter (threshold −6 dB, knee 6, ratio 12,
attack 3 ms, release 250 ms) → `AnalyserNode` → đích. Nâng track lên 2–3 lần mà
không có limiter thì mọi tiếng nổ/tiếng súng đều vỡ; limiter giữ đỉnh dưới
0 dBFS mà không bơm lời thoại.

**Cái bẫy phải tránh.** `createMediaElementSource` **đưa âm thanh của element
vào graph**, và audio đi vào một graph *đang suspended* là im lặng vĩnh viễn —
không có đường quay lại. Vì vậy `__floatEnsureAudioGraph(video)` trả `nil` chừng
nào `AudioContext.state` chưa `running`; element chỉ bị capture sau khi context
sống, còn lại cứ phát bình thường và sẽ thử lại. Trang báo lại qua
`__floatAudioBoostStatus` (`off`/`no-video`/`pending`/`blocked`/`unsupported`/`on`)
và Swift `NSLog` khi status không phải `on` — để một trang từ chối graph không
im lặng thất bại.

**Chung graph với ad audio tap.** `startAdAudioTap()` trong `buildVideoHTML` cũng
lấy `__floatEnsureAudioGraph(v)` để dùng `ctx`/`analyser`, thay vì tự tạo
`AudioContext` và gọi `createMediaElementSource` lần nữa — gọi lần hai trên cùng
một element sẽ throw. Nên analyser nghe tín hiệu *sau* gain + limiter.

**Áp vào đâu.** Nguồn chân lý là một script nhúng (`audioBoostJavaScript`), cài ở
ba đường phát mà native chạm được (`buildVideoHTML`, `installMovieEmbedAdScript`,
`injectVideoMaximize`) và tự áp lại ở mỗi lần `playing`, nên một tập mới hay player
đến muộn cũng vào đúng mức. Swift còn đẩy lại định kỳ (`retryAudioBoostIfNeeded`,
tối đa 2.5 s/lần) khi status chưa `on`, phòng trường hợp `<video>` xuất hiện muộn.
Vì `<video>` có thể nằm sau biên same-origin, mức được `postMessage` dọc cây frame.

**Giới hạn đã biết.** Khi một phim phải fallback sang iframe embed **cross-origin**
(`buildEmbedHTML`), trang chủ không chèn được script vào tài liệu của frame, nên
không có graph và không có tăng âm — đúng cùng lý do native phải tự bôi mirror cho
quảng cáo vẽ trong frame. Bù lại, chính khung chủ (do native tạo) vẫn nhận
`postMessage` và áp mức cho `<video>` của nó nếu có.

**Giao diện.** Một nút trên thanh điều khiển (`speaker.wave.2` → `speaker.wave.3.fill`
khi bật) chỉ hiện khi `movieContext != nil`, bấm để xoay vòng 4 mức; và bốn mục
`✓` trong menu `•••` ở khối phim. Cả hai đều `showHUD` mức vừa chọn.

**Test.** `tests/audio-boost.test.js` (node + `vm`, script lấy nguyên văn từ
`FloatWindow.swift`) kiểm: unity không đụng graph; context `running` capture
**đúng một lần** rồi chỉ đổi gain; x1 → x2.8 giữ nguyên graph; context
`suspended` **không** capture element và trả `pending`; sự kiện `playing` sau đó
áp mức đã nhớ; relay `postMessage` tới frame con; và khi chưa có `<video>` thì
báo `no-video`.

---

## Sửa tiếp: thanh đen chỉ có **một phía** (2026-09-26, Tập 24)

Người dùng báo thanh đen phía trên vẫn còn. Đo ảnh `paste-1790401517467`
(3712×2130) trước khi sửa, theo đúng cách app nhìn:

* Panel là **borderless**; thanh tiêu đề AppKit chỉ là lớp phủ 36 pt **đè lên**
  `webView`, nên snapshot của app là **toàn bộ lòng cửa sổ**, không phải phần dưới
  thanh tiêu đề. Lòng cửa sổ = 3620×2038 → aspect **1,776 ≈ 16:9** (đúng bằng
  `videoAspectRatio` mặc định, tức app **chưa từng** đọc được `videoWidth/Height`
  thật — dấu hiệu `<video>` nằm sau biên không chạm tới được).
* Trong snapshot: dải đen ở **mép trên**, ~**5,3 %** chiều cao (≈109 dòng), mỗi dòng
  ~93 % pixel gần đen (phần còn lại là logo VTVgo in đè). **Không có** dải nào ở
  đáy — ảnh chạy tới dòng cuối cùng.

Dựng lại snapshot đúng (chèn 72 dòng bị thanh tiêu đề che) rồi cho công cụ chạy
**code thật**, trước khi sửa:

```
renderedLetterbox: top=0.000 bottom=1.000 span=1.000 -> no crop (full picture)
smartFill transform: translateY(0.000%) scale(1.0000)
```

**Nguyên nhân:** cả hai bộ dò (JS `smartFillJavaScript` và native
`renderedLetterbox`) đòi **cả hai** mép đều có dải (`top >= 3 && bottom <= 68` /
`upper >= thick && (1 - lower) >= thick`). Khung này chỉ có dải trên, đáy là hình
tới dòng cuối → phép thử hai-mép không bao giờ nổ → không cắt.

**Sửa:** một dải ở **một trong hai** mép cũng tính, kèm điều kiện mới là **khung
hình phải gần giữa** (`|(upper+lower)/2 − 0.5| ≤ 0.12`). Phép thử hình ở 3 dòng
giữa (`picture`) vẫn nguyên, nên cảnh tối / fade-đen vẫn không bị crop; chỉ dải
lệch quá ~12 % mới bị từ chối.

Kiểm lại **cùng snapshot đó** sau khi sửa:

```
renderedLetterbox: top=0.053 bottom=1.000 span=0.947 -> CROPS
smartFill transform: translateY(-2.941%) scale(1.0588)
black bars  : CROP   native band 0.053..1.000 -> iframe/video scaled 1.06x
```

Với khung này, `__floatApplyHostLetterbox` là đường cắt thực sự: không có `<video>`
ở tài liệu gốc nên nó nhân `scale` và dịch `top` cho **iframe của provider**, đẩy
dải đen lên khỏi mép trên.

**Test.** `tests/black-bars.test.js` thêm hai ca: dải **chỉ ở trên** (cũ:
`scale(1.0000)`, mới: `scale(1.0588)`) và dải **chỉ mờ** (không tính là bar →
`scale(1.0000)`).

---

## Chuẩn hoá giao diện (2026-09-26)

Giao diện bị đánh giá là "đơn sơ, thiếu chuyên nghiệp". Đọc code thì thấy nguyên
nhân rất cụ thể, không phải "thiếu phong cách":

* **Giá trị trang trí viết thẳng tại từng chỗ dùng** — ba bán kính góc khác nhau
  (6/7/8/16), sáu cỡ chữ (10.5/11/12/12.5/13/15), hàng loạt alpha rời
  (0.55/0.14/0.12/0.08/0.82/0.18). Thêm một nút là thêm một biến thể nữa, nên
  bề mặt trôi dần khỏi nhau thay vì được thiết kế.
* **Mỗi công tắc tự chọn một màu "bật"**: xanh lá (tự chuyển tập, tự cuộn,
  khóa vị trí), xanh dương (bỏ qua GT), tím (xuyên chuột), đỏ (hạ tiếng). Năm
  màu nhấn tranh nhau nên không màu nào mang nghĩa "đang bật".
* **Nút không có phản hồi khi rê chuột.** `StripIconButton` chỉ đổi alpha khi
  *nhấn* (0.5). Không có hover, các glyph đọc như hình minh hoạ chứ không như
  nút — đây là lý do chính khiến thanh điều khiển trông tĩnh.
* **Menu dùng tiền tố chuỗi `"✓ "`** thay vì checkmark thật, nên nhãn bị đẩy
  lệch và dấu không thẳng cột.

**Đã làm.** Một tầng token duy nhất `VibeTheme` (màu, bán kính, khoảng cách theo
lưới 4, cỡ chữ) — **mọi** literal trang trí giờ nằm ở đó, chỉ còn hai chỗ dùng
font tham số hoá theo cỡ glyph là ngoại lệ. Cụ thể:

* **Hover/press** cho nút trên strip qua `StripIconButton.Wash`: `.glyph` cho nút
  biểu tượng, `.chip(màu)` cho chip đang sở hữu nền riêng (hover *đậm lên* chứ
  không xoá nền — nếu xoá thì chip mất nền khi rời chuột).
* **Một accent duy nhất** (`VibeTheme.accent`) cho mọi trạng thái "bật", cho
  chip kích thước đang chọn và cho thanh tiến trình.
* **Bốn chấm trên thanh tiêu đề** thành `TitleCircleButton`: có viền mảnh cho
  khỏi dán phẳng, và **glyph hiện dần khi hover** (như traffic light macOS) —
  `hitTest` được chặn để glyph không nuốt cú bấm.
* **Hai đường hairline** chia thanh tiêu đề khỏi video và chia hàng timeline với
  hàng nút trong strip (72 pt = hai dải, trước đây không có gì phân cách). Chúng
  là `HairlineView` với `hitTest` trả `nil` — nét 1 pt mà nhận chuột thì mất một
  dải kéo cửa sổ và một dải bấm nút.
* **Overlay tải** có vòng nền mờ, cung quay tô accent và nhãn "Đang tải…".
* **Menu "Tùy chọn"** dùng `NSMenuItem.state` (checkmark vào đúng cột), gom lại
  theo nhóm Phát lại / Tập phim / Kích thước / Cửa sổ, và "Tăng âm thanh" thành
  menu con hiện mức đang dùng ở tiêu đề cha. Tỉ lệ phát dùng chung
  `formatRate` với badge tốc độ nên cùng một giá trị không còn được viết hai kiểu.

**Kiểm chứng.** `swift build` sạch, cả 6 suite test đều pass. Đây là thay đổi
thuần trình bày nên test không phủ được hình thức: **cần build rồi chạy app để
xem mắt thường**. Phần hình học được giữ nguyên (nét chia đặt ở `barH - 32`, nằm
giữa hàng nút kết thúc ở 37 và hàng timeline bắt đầu ở 42), nên không có chồng lấn
mới.

---

## Quảng cáo **video** 9922 inline (2026-09-26)

Người dùng báo một spot 9922 dạng **video chạy ngay trong khung phát** và **app
không phản ứng gì** — không che mờ, không tua, không thông báo.

Mọi bộ dò hiện có đều chạy trên **một khung hình tĩnh**, qua hai tín hiệu: màu
(vàng/đỏ/neon) và chữ (OCR + `AdClassifier`). Một creative động, không có dòng chữ
nào đủ rõ, không có bảng màu đặc trưng thì **không tín hiệu nào nổ** — đúng với
"không phản ứng gì".

Tín hiệu duy nhất không phụ thuộc chữ/hình là **âm thanh**, và khi rà đường đó thì
thấy một lỗi có thật trong code:

* `hearAdvertisement` đã có nhánh `loadingStrategy == .siteEmbed` (dùng
  `looksLike9922Ad`), tức tác giả *đã định* cho trang provider dùng tín hiệu âm
  thanh.
* Nhưng tap âm thanh (`startAdAudioTap`) **chỉ được cài trong `buildVideoHTML`** —
  trang player mà app tự dựng. Provider page không bao giờ có tap, nên nhánh
  `.siteEmbed` đó **không thể chạy**.
* Tap còn trộn lẫn: nó là một bản sao dài nằm giữa script của player.

**Đã sửa:**

* Tách tap thành script dùng chung `adAudioTapJavaScript` (cùng kiểu với
  `smartFillJavaScript`, `bannerBlurJavaScript`, `audioBoostJavaScript`) và cài ở
  **cả ba** đường inject, nên **bất kỳ frame nào sở hữu `<video>` cũng tap được** —
  kể cả frame của provider. Nó tự tìm lại player đến muộn (sự kiện `playing` +
  vòng 2 s).
* Guard của `hearAdvertisement` giờ chỉ loại YouTube (nơi quảng cáo do chính trang
  xử lý) thay vì loại cả `fullPageInject`.
* **Xả phần PCM dở** khi `seeked`/`loadeddata`: app tua rất nhiều, và một cú tua
  nối hai đoạn audio rời vào cùng "một giây", làm bản nhận dạng mất tin cậy. Ngưỡng
  im lặng (không gửi chunk rỗng) vẫn giữ.
* Tap vẫn đi qua `__floatEnsureAudioGraph`, nên khi AudioContext chưa được phép
  chạy thì element **không bị capture** (capture vào graph suspended = im lặng).

**Ghi vết để lần sau đo được.** Bật `VIBEFLOAT_AD_TRACE=1` (hoặc
`defaults write … vibefloat.adTrace -bool YES`) thì mỗi lần quét sẽ log: bằng chứng
khung hình (splash/slot/kind/band/text), **trạng thái player trực tiếp** (file đang
phát, `currentTime`, `duration`, `paused`, `readyState`), **mọi** transcript âm
thanh (không chỉ câu khớp), và lý do đường âm thanh không chạy (chưa được cấp quyền
nhận dạng giọng nói, hay không có tap). Trước đây tất cả những thứ này đều im lặng,
đó là lý do không thể phân biệt "không nhìn thấy" với "thấy rồi từ chối".

**Chưa chứng minh được:** spot cụ thể này có *nói* tên thương hiệu trong audio hay
không. Tôi **không** thêm bộ dò theo thời gian (cắt cảnh / đổi `src`) vì chưa có
khung hình thật để chỉnh ngưỡng — thêm vào lúc này chỉ là đoán, đúng kiểu đã bị từ
chối trước đó. Bản ghi vết sẽ trả lời câu đó bằng một lần quảng cáo chạy qua.

**Test.** `tests/ad-audio-tap.test.js` (node + `vm`, script lấy nguyên văn): nửa
giây dở không gửi; một giây đầy gửi payload 16 kHz Int16; cài lần hai không dựng
tap thứ hai; seek xả phần dở (không nối hai đoạn); context suspended không capture;
chunk im lặng không gửi; player đến muộn được tap ở vòng kiểm tra; sự kiện `playing`
relay tap đúng frame. `swift build` sạch, **7** suite pass.


## Bỏ qua giới thiệu / cuối phim (2026-09-26)

Người dùng báo tính năng tự chuyển tập cuối phim **có lỗi**. Rà lại toàn bộ
đường quyết định thì thấy nó nằm gọn trong một hàm, trộn lẫn chính sách với trạng
thái cửa sổ, và dựa vào một giả định không đứng vững.

### Lỗi đo được: `dur` có thể **không phải** độ dài tập phim

Cửa sổ "phần giới thiệu cuối" được đặt ở `dur - 180`. Nhưng `pollVideoState` lấy
`dur` theo thứ tự sau:

```
var dur = v.duration;                       // có thể là Infinity
if (!isFinite(dur) || dur < 1) {
    dur = v.seekable.end(v.seekable.length - 1);   // ← mốc **đệm**, không phải độ dài
}
if (clock && clock.dur > dur) dur = clock.dur;
```

`seekable.end()` là **mép vùng đệm** (và với luồng trực tiếp là cửa sổ DVR), luôn
lớn hơn vị trí đang phát vài chục giây — không bao giờ là độ dài một tập. Với giá
trị đó, `dur - 180` rơi vào **giữa phim**, nên:

* bộ đệm trước vị trí phát **≥ 180 s** → `ct >= dur - 180` đúng rất sớm (mỗi khi
  `watchedEnough` cho phép) → app **nhảy tập khi phim chưa hết**;
* bộ đệm **mỏng hơn 180 s** → `ct` không bao giờ chạm `dur - 180` (nó không thể vượt
  `seekable.end()`) → **không bao giờ nhảy**, và không có gì trong log.

Cả hai đều là "lỗi skip phần giới thiệu cuối", chỉ khác chiều.

### Sửa

1. **`dur` giờ có nguồn.** Poll trả thêm `durSrc`: `media` (`duration` thật),
   `clock` (độ dài do chính player provider công bố: `jwplayer`, `__floatClock`,
   `getPlayerState`), `seekable` (mép đệm), `unknown`. Chỉ **hai** nguồn đầu được
   phép **đặt cửa sổ credits**; `seekable`/`unknown` thì không — chúng vẫn dùng cho
   thanh tiến trình, nhưng không quyết định việc chuyển tập.
2. **Tín hiệu không cần độ dài vẫn nguyên giá trị**: `ended` (và "dừng trong 15 s
   cuối của một độ dài **thật**") luôn chuyển tập, kể cả khi `dur` chỉ là mốc đệm.
   Nhờ vậy luồng trực tiếp không tự nhảy giữa buổi, mà hết file thì vẫn nhảy.
3. **Không còn HUD nói dối.** `NSLog("Skip outro …")` + `showHUD("Đã bỏ qua giới
   thiệu cuối")` chạy **trước** khi biết có tập kế tiếp hay không, nên ở tập cuối
   người dùng thấy "đã bỏ qua" rồi ngay sau là "Hết mùa / hết danh sách". Giờ chỉ
   `switchEpisode` phát thông báo: nó biết tên tập mới, và tự nói lý do khi hết
   danh sách.

### Chính sách tách ra thành `Sources/WatchAssist.swift`

Toàn bộ phán đoán nằm trong một hàm **thuần** `WatchAssist.decide(_:)` — không
AppKit, không web view — trả về `action` (`.skipIntro`/`.advanceToNextEpisode`),
`reason`, và cờ `introPassed`. `handleWatchAssist` chỉ còn là adapter: dựng sample,
gọi policy, thi hành.

Ngưỡng giữ nguyên con số đang chạy để log so được với hành vi cũ: intro 90 s (nhớ
theo slug), tối thiểu 360 s mới có intro, chỉ chuyển tập sau khi xem quá nửa tập,
cửa sổ credits 180 s, 15 s cuối tính là hết file.

**Ghi vết một dòng mỗi lần verdict đổi** (`lastWatchAssistReason`), in ra
`ct`/`dur`/`durSrc`/`ended`/hành động. Poll 0.5 s nên log mỗi lần quét là 2
dòng/giây; đổi-trạng-thái thì mỗi tập vài dòng, và đúng những dòng cần. Ví dụ khi
`dur` chỉ là mốc đệm:

```
[FloatVideo] Watch assist: no real episode length to place the credits — ct=2520.0 dur=2700.0 src=seekable ended=no step=none
[FloatVideo] Watch assist: skipped end credits — ct=2520.0 dur=2700.0 src=media ended=no step=advanceToNextEpisode
[FloatVideo] Watch assist: less than half the episode watched — ct=900.0 dur=2700.0 src=media ended=no step=none
```

### Test

* `tests/watch-assist/main.swift` (native, biên dịch cùng `Sources/WatchAssist.swift`,
  chạy trong `tests/run.sh`): 29 check trên một tập 45 phút — 42:00 cắt credits,
  41:59 thì không, `ended` chuyển tập, `ended` ở giây 30 (preroll) thì không, mốc
  đệm **không** đặt credits, mép DVR trực tiếp **không** chuyển tập, "dừng ở 2692"
  tính là hết file, intro theo slug nhớ được, quay lại sau intro không bị cắt lại,
  clip 5 phút không có intro nhưng hết file vẫn chuyển, các guard (suppress / không
  phải phim / đang tạm dừng / duration vô hạn / chưa rõ nguồn) và hai công tắc.
* `tests/poll-duration-source.test.js` (node + `vm`, lấy nguyên văn script poll):
  `duration` hữu hạn ⇒ `media`; `Infinity` + `seekable` ⇒ `seekable`; clock lớn hơn
  ⇒ `clock`; clock nhỏ hơn **không** rút ngắn độ dài thật; frame chỉ có clock;
  nhánh `jwplayer`; mọi payload đều mang `durSrc`; video trong iframe cùng origin.

`swift build` sạch, **9** suite (2 native + 7 node) đều pass.

**Còn lại:** nếu provider chỉ báo mốc đệm **và** không bao giờ phát `ended`, việc
chuyển tập cuối phim sẽ không xảy ra (giữ nguyên ghi chú cũ bên dưới) — log giờ nói rõ đúng câu đó
(`no real episode length to place the credits`) thay vì im lặng, và đó là lựa chọn
có chủ ý: thà không nhảy còn hơn cắt mất đoạn kết.



## Cinema: giao diện Netflix, cuộn tải thêm, kho thuyết minh (2026-09-26)

Ba yêu cầu trong một lượt: giao diện `catalog.html` giống Netflix, cuộn để tải
thêm thay vì bấm phân trang, và thêm nguồn phim thuyết minh.

### 1. Nguồn: cái gì còn sống, cái gì đã chết (đo bằng curl, không đoán)

Dò ~40 host (các bản sao Ophim CMS, rophim, vsmov, phimhay, motphim, 2phim,
hhkungfu, các TLD `ophim*.cc`, mirror `phimapi.*`…). **Chỉ hai API trả JSON:**

| Nguồn | Trạng thái | Đo được |
|---|---|---|
| `phimapi.com` (KKPhim) | sống | `phim-thuyet-minh`: **2.344 phim / 98 trang**; `phim-long-tieng`: **1.379 / 58**; 24 phim/trang; **24/24** phim trang 1 có `lang = "Vietsub + Thuyết Minh"` |
| `phim.nguonc.com` (NguonC) | sống một phần | `phim-moi-cap-nhat`, `phim-bo`, `phim-le`, `hoat-hinh`, `tv-shows`, `the-loai` trả 200. `dang-chieu` và `phim-chieu-rap` trả **404** `Category movie doesn't exist!` |
| mọi host khác | chết | 404 openresty, Cloudflare challenge, SPA không có API, hoặc domain rao bán |

Hệ quả đo được trong code cũ: `_getNguonCList('moi')` và `('chieurap')` trỏ vào
`dang-chieu` → **404**, nên cả nửa NguonC của trang chủ (`getHomeSections` cũng
gọi `_getNguonCList('dangchieu', 1)`) im lặng rỗng. `_getNguonCList('thuyetminh')`
thì lọc `hasThuyetMinh` trên **một** trang 10 phim: tỉ lệ gắn nhãn đo được là
**4/50** (`phim-moi-cap-nhat`), **1/30** (`phim-bo`), **1/30** (`phim-le`) — tức
lọc ra gần như không còn gì.

Sửa:

* `_nguoncCategoryPath()` là bảng đường dẫn **duy nhất**, chỉ chứa những path đã
  kiểm tra; `chieurap` trả rỗng vì NguonC không có mục chiếu rạp (thà thiếu còn
  hơn gán sai nhãn cho phim lẻ).
* `_getNguonCAudioList()` thay cho việc lọc một trang: quét **10 trang** song song
  (100 phim → ~8 TM, 3 LT), cache trong phiên 10 phút, rồi phân trang kết quả theo
  24. Có log đúng con số quét được.
* `_getKKPhimList('thuyetminh' | 'longtieng')` **buộc** cờ audio, vì cả mục đã là
  bản đó: nếu không, pill lọc "Thuyết minh" có thể xoá sạch danh sách.
* `SOURCES` thêm hai mục **"Kho Thuyết Minh"** và **"Kho Lồng Tiếng"**: chọn chúng
  là duyệt trọn kho 2.344/1.379 phim, không phải vài bản mới nhất có lẫn thuyết
  minh. `getLatest()` gắn nguồn với đúng mục của nó.
* `getHomeSections()`: `dangchieu` → `moi`; rail Thuyết minh/Lồng tiếng giờ là
  hợp của kho KKPhim với phần NguonC quét được (`_withNguonCAudio`).

Đo lại bằng `node` chạy thẳng `movie-service.js` với `fetch` thật:
`getLatest('thuyetminh','moi',2)` → 24 phim TM; `getLatest('nguonc','moi',1)` → 10
(trước là 0); `getLatest('all','thuyetminh',1)` → 29 phim, **tất cả** đều TM;
`getHomeSections('all')` → 7 rail đầy đủ.

### 2. Cuộn để tải thêm (thay phân trang)

`catalog.js` từ chỗ "một trang một lần render" thành một **feed**:

* `feed` giữ `key` (nguồn + mục + thể loại + quốc gia + pill + từ khoá),
  `page`, `loading`, `done`, `seen`, `count`. Nếu người dùng đổi view giữa lúc
  request bay, `feed !== target` nên kết quả cũ bị bỏ, không nối vào danh sách mới.
* `appendToGrid()` chèn **chỉ thẻ mới**: dựng vào một node tạm, bind riêng các thẻ
  đó rồi mới chuyển sang lưới. Bind cả lưới về sau sẽ gắn trùng listener (một cú
  bấm mở hai lần) và làm ảnh đang tải bị thay.
* Khử trùng theo `source:slug`, nên trang chồng nhau (nhất là chế độ "Đa nguồn")
  không lặp thẻ.
* `IntersectionObserver` trên `#feed-sentinel` (`rootMargin` 700px) + `#feed-retry-btn`
  cho ca lỗi; trần 60 trang; dừng khi nguồn trả trang rỗng hoặc hai trang liên tiếp
  bị pill lọc sạch.
* Trạng thái hiển thị ở `#feed-footer`: "Đang tải thêm…" (có vòng quay), "Đã hết
  danh sách", "Thử lại". Bỏ hẳn `currentPage`, `updatePagination`, nút Trang
  trước/sau và các biến đếm trang rải rác.
* Nguồn "Kho" luôn mở dạng lưới (không rơi vào trang chủ nhiều rail), vì người
  dùng chọn kho là để duyệt kho.

Kiểm chứng trong trình duyệt thật (harness tạm, dữ liệu thật của cả hai API):
`24 → 48 → 72 thẻ`, `page 1 → 4`, rồi footer **"Đã hết danh sách"**; cuộn thêm
không phát sinh request nào.

Test hồi quy: `node extension/tests/catalog-feed.test.js` — 9 ca, chạy `catalog.js`
trong `vm` với vài node DOM giả: trang 1 gắn đúng, trang chồng nhau bị khử trùng
(không thẻ nào lặp), hai trang không thêm gì thì kết thúc, feed đã xong không tải
lại, phản hồi của view cũ bị bỏ, trang rỗng kết thúc, hai trang bị pill lọc sạch
thì kết thúc, phim có thuyết minh qua được pill, và tìm kiếm chỉ một trang.

#### Hồi quy do chính lần đổi đó: "loading cover" không bao giờ được gỡ

Ảnh người dùng gửi: lưới dạng Poster hiện **12 ô đen** rồi mới đến 4 phim thật.
Đó đúng là `Array(12).fill('<div class="skeleton-card"></div>')` trong
`loadFeedView`, và `skeleton-card` là `aspect-ratio: 2/3` + gradient tối — tức là
ảnh chứa đúng 12 ô như số đo.

Nguyên nhân là **bước thay thế bị mất** khi chuyển từ "render cả trang" sang
"nối thêm": bản cũ đặt `grid.innerHTML = cards` nên lớp phủ loading bị cuốn theo;
bản mới chỉ `appendChild` các thẻ mới vào sau 12 ô đó, và không ai gỡ chúng.
`catalog.html` cũng có sẵn 6 ô như vậy trong `#movie-grid`, nên cả hai nguồn phủ
đều phải được gỡ ở cùng một chỗ.

Sửa: `clearLoadingCovers(grid)` — gỡ mọi `.skeleton-card` trong lưới **trước khi**
nối trang đầu tiên có thẻ. Kèm theo đó là nửa còn lại của cùng lỗi: danh sách kết
thúc mà **không có thẻ nào** thì 12 ô phủ cũng ở lại mãi, nên giờ nó được thay bằng
một dòng nói rõ lý do (`showGridMessage` + `feedEmptyMessage`, có nêu tên pill lọc
hoặc từ khoá đang tìm). Ca lỗi tải cũng dùng cùng một hàm thay vì tự ghép
`innerHTML`.

Kiểm chứng: `catalog-feed.test.js` lên **12 ca**; ba ca mới — "trang đầu gỡ lớp phủ",
"danh sách rỗng thì đổi sang thông báo", "danh sách thuyết minh rỗng thì nêu tên
pill". DOM giả mô hình `innerHTML` thành các node `.skeleton-card` có `remove()`.
**Đã xác nhận test bắt được lỗi**: bỏ dòng `clearLoadingCovers(grid)` thì ca đầu
`FAIL … 12 !== 0`, đúng 12 ô như trong ảnh; khôi phục thì xanh.

#### Tự kiểm tra sau mỗi lần tải

Lỗi lớp phủ ở trên chỉ hiện **trên màn hình** — một node tạm sót lại trông y như
nội dung thật — nên nó không tự tố cáo. Thêm một bước tự kiểm tra sau **mỗi** lần
tải của feed: `loadMoreMovies` gọi `auditTransientNodes(grid, context, settled)`
ngay trong `finally`, khi lần tải vừa chạm vào DOM. `loadHomePage` gọi cùng hàm
đó sau khi các mục trang chủ đã render.

Nó soi lại đúng những thứ chỉ được sống trong lúc tải: `.skeleton-card` và
`.home-section-skeleton` trong `root` (chỉ khi `settled` — tức đã có dữ liệu hoặc
feed đã xong — vì lúc danh sách thật sự còn rỗng thì lớp phủ là hợp lệ),
`#feed-status` còn hiện khi trạng thái không phải `loading`, và `#feed-sentinel`
còn hiện khi feed đã `end`/`error`. `isOnScreen()` bỏ qua node nằm trong tổ tiên
`.hidden` (ví dụ `#grid-view.hidden` lúc đang ở trang chủ) nên không kêu oan. Mỗi
thứ sót lại được nêu rõ trong console: `[catalog] leftover … after … — N node(s)
still in the DOM (selector) — a finished load should have removed or hidden them.`
Hàm trả về danh sách lỗi để test (và chỗ khác) dùng lại được, và chỉ đọc DOM nên
không đổi hành vi.

#### Banner debug trên trang

Cảnh báo chỉ nằm trong console thì phải mở DevTools mới thấy, nên cùng dữ liệu đó
được đưa lên **banner tại chỗ** `#catalog-audit` (góc dưới-phải, chỉ đọc, có nút
đóng và tự ẩn sau 8 s). Banner **mặc định tắt** — `auditDebugEnabled()` chỉ bật khi
có `?audit=1` trên URL, `localStorage['catalog-audit'] = '1'`, hoặc
`window.CATALOG_AUDIT_DEBUG = true` từ console; nếu không có lỗi thì banner vẫn ẩn.
Mọi truy cập (URL, localStorage) đều bọc trong `try` để một công cụ gỡ lỗi không
bao giờ làm sập trang mà nó đang soi. `renderAuditBanner()` gọi trong
`auditTransientNodes`, nên mọi lần tải đều đi qua cùng một đường.

Kiểm chứng: `catalog-feed.test.js` lên **17 ca**. Ca 11 — một lần tải sạch không
phát ra cảnh báo `leftover` nào (để chắc bước kiểm tra không kêu oan). Ca 12 —
đặt lại một cover mà `remove()` không làm gì (đúng cảm giác của lỗi gốc), tải một
trang có thẻ, và cảnh báo phải nêu `leftover … skeleton-card`. Ca 13 — cùng bước
kiểm tra trả về `home-section-skeleton` của trang chủ như một issue có tên. Ca 14
và 15 — cờ debug tắt thì banner vẫn ẩn, bật thì banner hiện và nêu đúng
`skeleton-card` (`window.CATALOG_AUDIT_DEBUG`). Console trong vm được bắt lại để
đọc. **Đã xác nhận test bắt được lỗi**: bỏ lời gọi `auditTransientNodes` khỏi
`finally` thì ca 12 `FAIL … expected a leftover warning, got: []`; khôi phục thì
xanh.

### 3. Giao diện theo phong cách Netflix

Bảng màu cũ là "dashboard": nền xanh-đen, bán kính 12px, năm màu nhấn tranh nhau
(xanh lá, xanh dương, tím, đỏ, hổ phách). Đổi token (`:root`) sang nền **đen
tuyệt đối**, mặt **#181818**, **một** màu nhấn đỏ `#e50914`, bán kính **4px**, và
thêm lớp `--nf-*`. Toàn bộ tên class giữ nguyên nên script không đổi.

Lớp "Netflix pass" ở cuối `catalog.css`:

* **Navbar** trong suốt trên billboard, đặc đen khi cuộn (`catalog.js` gắn
  `.navbar-scrolled`) — thương hiệu chuyển sang chữ đỏ in hoa.
* **Billboard** full-bleed (bỏ margin/bo góc/đổ bóng), `min-height` 76vh, ảnh
  `object-fit: cover`, gradient đáy đổ về đen tuyệt đối; tiêu đề `clamp(34px,5vw,66px)`
  weight 900; nút chính **trắng chữ đen** và nút phụ xám mờ — đúng hai nút của
  Netflix thay cho gradient hồng.
* **Card**: `translateY(-6px) scale(1.035)`, bóng sâu, hàng nút hành động hiện khi
  hover; rail 16:9.
* **Top 10**: số thứ tự viền rỗng cỡ `clamp(72px,7.4vw,116px)` nằm **bên trái**
  artwork, bị artwork phủ lên nửa phải (đúng kiểu bảng xếp hạng). Phải cho
  `overflow: visible` và để artwork nhường một cột 48px, nếu không số bị cắt cụt
  hoặc thẻ tràn ra ngoài rail.
* **Điều hướng mục**: link xám, mục đang mở là **pill trắng chữ đen**; bỏ các
  `style=` inline ở nút "Truyền hình"/"Dán link" (đó là lý do thanh này trước đây
  lệch màu) và style chúng bằng CSS.
* **Pill lọc + công tắc dạng xem** thành một segmented control (viền mảnh, mục
  chọn nền trắng); **mũi tên cuộn rail** chỉ hiện khi hover/focus (trước đây luôn
  hiện, nằm chồng lên ảnh).
* Thanh cuộn, skeleton, modal, dropdown gợi ý, toast theo cùng hệ.

**Chưa kiểm chứng:** trạng thái hover (không có chuột thật trong lượt này), và
toàn bộ việc này vẫn chạy trong harness với `fetch` giả — cần mở tiện ích trong
Chrome để xác nhận lần cuối. Harness đã xoá (`extension/harness-preview.html`
không còn), không commit gì.

## TikTok phát nổi: hai nguyên nhân, đo trên trang thật (2026-09-26)

Ảnh người dùng gửi: cửa sổ dọc TikTok, thanh tiêu đề "TikTok Dành Cho Bạn", video
hiển thị **0:00 / 0:18**, và toàn bộ khung hình là một **bảng rất sáng** kèm nút
"Tiếp tục…", "Đăng nhập" và dòng điều khoản. Phía trên bảng vẫn thấy **wordmark của
chính TikTok**. Video chưa từng chạy.

Trước khi sửa, tôi dựng lại trang thật ở đúng khổ 420×860 trong trình duyệt của
ứng dụng (cửa sổ ẩn danh, chưa đăng nhập) và **mở bảng đăng nhập thật** để đo:

| Phần tử | class | vị trí | phủ | z-index |
| --- | --- | --- | --- | --- |
| bảng | `…--DivModalContainer` | fixed | **0.96** | 3001 |
| lớp mờ | `…--DivModalMask` | fixed | 0.96 | — |
| vỏ mới | `tux-base-dialog` | fixed | 0.96 | 9999 |
| nội dung | `…--DivModalContent` | static | 0.65 | — (role=dialog, data-e2e=login-modal) |
| nút đóng | `…--DivCloseWrapper` | — | — | `data-e2e="modal-close-inner-button"`, `aria-label="Đóng"` |

Bấm đúng nút đóng đỏ **gỡ hẳn bảng khỏi DOM** (`modalStillInDom: false`). Lặp lại
phép đo khi bảng đã đóng: **0** phần tử nào trên toàn trang thỏa cùng điều kiện —
tức là tập luật dưới đây không có dương tính giả trên feed thật.

### Nguyên nhân 1 (đo được, không phải suy đoán): trang thay chính nó, app không tiêm lại

CSS của app **có** chứa `div[class*="DivModalContainer"]` — nếu bảng style còn trong
tài liệu thì bảng đăng nhập đã bị ẩn. Ảnh chụp cho thấy điều ngược lại: **wordmark
và header của TikTok vẫn hiện**, trong khi CSS của app ẩn `header`. Vậy tài liệu
trong ảnh **không có stylesheet do app tiêm vào**.

Cơ chế nằm ở một dòng:

```swift
func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    if loadingStrategy == .fullPageInject {
        guard !hasInjectedJS else { return }   // ← "đã tiêm vào *một* tài liệu nào đó"
```

`hasInjectedJS` là biến của **web view**, không phải của **tài liệu**, và chỉ được
đặt lại trong `loadVideo`/`reloadEpisode`. Khi chính trang tự đổi tài liệu (đổi
locale, vòng đăng nhập, một link trên site không SPA), tài liệu mới **không nhận
gì cả**: không CSS bố cục, không vòng `applyLayout`, không hook quảng cáo. App vẫn
poll tài liệu mới (nên thanh tiến trình vẫn đọc được `0:18`), nhưng không ai gọi
`play()` cho nó. Đúng trạng thái trong ảnh.

**Sửa:** không tin `didFinish` nữa mà **kiểm tra bất biến** — mỗi 3 s hỏi thẳng
trang `!!(window.__floatVideoApplyLayout && document.getElementById('__floatvideo-style'))`;
thiếu thì đặt `hasInjectedJS = false` và tiêm lại (kèm `injectAdSkip()` cho
YouTube, vì nó cũng được cài theo tài liệu). Một chỗ, tự chữa cho **mọi** site,
không phụ thuộc ngữ nghĩa sự kiện điều hướng của WebKit. Log:

```
[FloatVideo] Injected document was replaced; re-injecting (site: tiktok)
```

### Nguyên nhân 2: che theo **tên class** là sai công cụ, và ẩn bằng CSS là chưa đủ

Hai điều đo được trên chính trang đó:

1. TikTok đã chuyển sang bộ component **TUX** với tên class **băm kèm phiên bản**:
   `tux-button__element__ZBq38f_v1_8_0`. Vỏ hộp thoại mới `tux-base-dialog`
   **không** chứa chữ "modal" lẫn "login" — danh sách `div[class*="DivModal*"]`
   không bao giờ thấy nó, và mỗi bản build lại đổi tên một lần.
2. Ẩn bằng CSS **không gỡ** hộp thoại: nó vẫn mounted, vẫn giữ **khoá cuộn** của
   feed và video vẫn đứng ở 0:00. Chỉ cú bấm vào nút đóng của chính TikTok mới
   unmount (đo ở trên: bấm là mất khỏi DOM).

**Sửa:** thêm một bộ quét trong trang, `tiktokWallJavaScript`, nhận diện theo
**hình học** chứ không theo tên: hộp `fixed`/`absolute` phủ ≥ 40 % khung nhìn (và
≥ 50 % mỗi chiều), **không chứa** `<video>`, và thuộc một trong các dấu hiệu —
`role="dialog"`, `aria-modal="true"`, `data-e2e` chứa `modal`/`login`, tên class
có `modal|login|dialog|sheet|popup|mask|wall`, hoặc **nền sáng** (bảng là trắng,
feed là đen). Với mỗi hộp: bấm nút đóng của nó (chỉ các selector đóng thật:
`[data-e2e*="modal-close"]`, `aria-label` chứa `đóng`/`close`), rồi mới `display:
none` làm lưới an toàn, gỡ khoá cuộn, và **cho video đang ở 0:00 cú `play()` mà nó
chưa từng nhận** — video đã chạy rồi thì không đụng vào (tôn trọng ý người dùng).

Danh sách CSS cũng được nới bằng thuộc tính thay vì tên: `[role="dialog"]`,
`[aria-modal="true"]`, `div[class*="Dialog" i]`, `div[class*="Modal" i]`,
`div[class*="Mask" i]`. Đo lại trên trang thật với bảng đã đóng: **8** phần tử
khớp, tất cả đều là hộp thoại rỗng `display:none` của TikTok — không có gì trong
thẻ video, không có gì chứa `<video>`.

Xoá luôn một selector cũ trong nhịp 1 s:
`[data-e2e="login-modal"] button` — nó nhắm vào **nút của chính bảng đăng nhập**.
Đo trên bản build hiện tại: selector đó khớp **0** phần tử (hành động của bảng là
`tux-*` div, không phải `button`), nên cú bấm vẫn rơi đúng vào nút đóng; nhưng ở
bản build đổi tên thuộc tính đóng thì nó sẽ bắt đầu bấm nút "Tiếp tục với…" mỗi
giây. Chỉ nút đóng là luật không thể làm sai điều đó.

### Kiểm chứng

* `native-app/tests/tiktok-wall.test.js` — **13** ca, chạy đúng đoạn script được
tách nguyên văn từ `FloatWindow.swift` trên một DOM dựng theo số đo thật (class,
toạ độ, z-index của bảng đăng nhập): 3 lớp che bị gỡ và **nút đóng được bấm đúng 1
lần**; bảng không có nút đóng thì bị che và **không** bấm vào nút "Tiếp tục"; bảng
tên băm nền trắng vẫn bị bắt nhờ hình học + màu; **4** ca chống dương tính giả
(thẻ video, overlay của thẻ, `#float-ad-blur`, thanh fixed thấp, phần tử chứa
`<video>`); feed bình thường là no-op; video 0:00 được `play()` còn video pause ở
giây 12 thì không; gỡ khoá cuộn; quét lại không bấm lần hai; cài hai lần vẫn một
bộ quét; và các ca ở mức mã nguồn (payload poll mang `walls`, bộ dò tự chữa được
nối vào timer, không còn selector bấm nút đăng nhập).
* `swift build` sạch, **10** suite (2 native + 8 node) pass, `tools/build-diagnose.sh`
vẫn dựng được.
* **Cần máy thật:** build lại app rồi mở TikTok. Hai dòng log cần tìm:
  `TikTok overlays cleared by sweeper: N` (đã gỡ N lớp che) và
  `Injected document was replaced; re-injecting` (trang tự thay tài liệu). Nếu
  bảng đăng nhập vẫn hiện mà **không** có dòng `Injected document was replaced`,
  thì bảng đó mang hình học khác giả định ở đây — lúc đó cần số đo mới
  (`getBoundingClientRect` + `className` của nó) chứ không phải nới ngưỡng mù.

## Refactor module TikTok: `Sources/TikTokPlayer.swift` (2026-09-26)

Ảnh thứ hai người dùng gửi: video TikTok chỉ chiếm một **cột** giữa khung dọc, hai
bên là nền trang. Đo lại trên trang thật ở đúng khổ cửa sổ app (420×860, chưa đăng
nhập) thì thấy cả ba luật CSS mà app dùng để "làm đầy khung" đều **không khớp gì
cả**:

| Luật cũ | Khớp trên DOM thật | Ghi chú |
| --- | --- | --- |
| `div[data-e2e="recommend-list-item-container"]` | **không** | mục là `<article>`, không phải `div` |
| `div[class*="DivVideoCardContainer"]` | **không** | class đã đổi tên |
| `div[class*="DivItemContainer"]` | **không** | class đã đổi tên |

Chuỗi thật đo được: `VIDEO 348×619 tại (74,121)` ← `SECTION.SectionMediaCardContainer`
(`aspect-ratio: 0.5625/1`, `min-width: 348px`) ← `DIV.DivContentFlexLayout` (flex,
420 rộng) ← `ARTICLE.ArticleItemContainer` (404×860, padding 16px) ←
`DIV.DivColumnListContainer` ← `MAIN.DivMainContainer` (x=72, track của sidebar).

Hai thí nghiệm trên trang thật định hình toàn bộ cách sửa:

1. **Chỉ đặt `width: 100vw` cho mục là không đủ.** Hộp 9:16 của card bị giữ bởi
   `aspect-ratio` và bị hàng flex co lại — đo được: vẫn `369` rộng. Phải **kéo cả
   chuỗi ra khỏi luồng** (`position: absolute; inset: 0; aspect-ratio: auto`): sau
   đó đo lại đúng `420×860` tại `(0,0)`. Đây là kết quả trên ảnh chụp thật.
2. **Feed cuộn trong một hộp con, không phải trong document.**
   `window.scrollBy(0, 900)` chỉ dịch document được **16 px** (hết mức), trong khi
   `scrollTop` trên hộp con dịch cả một mục. Nghĩa là tính năng tự cuộn và phím mũi
   tên — cả hai đều `window.scrollBy` — **không có tác dụng gì**, và
   `scroll-snap-type` lại đặt trên `html, body` thay vì trên hộp thật sự cuộn.
   `scrollTo` trên hộp đó nhảy đúng từng mục: đo được `0 → 876.5`.

### Cấu trúc sau refactor

Toàn bộ phần TikTok nằm trong `Sources/TikTokPlayer.swift`: CSS, script trang, câu
lệnh gọi vào trang, khoá preference, chuỗi menu/strip/HUD, và bộ đọc status. Sáu
global rời rạc trong trang (`__tiktokTimer`, `__tiktokNavInstalled`,
`__tiktokAutoScrollInstalled/Enabled/Advancing`, `__tiktokApplyAutoScroll`) gộp
thành **một** đối tượng `window.__floatTikTok` với `install/pass/advance/setAutoScroll/status`.
`FloatWindow` chỉ còn ba dòng: chèn CSS, chèn script, gọi `install(seed)`.

Ba thứ đổi **cách tìm**, không chỉ đổi tên:

* **Scroller** tìm bằng hành vi: tổ tiên gần nhất có `overflow-y: auto|scroll` và
  `scrollHeight > clientHeight`. Không phụ thuộc `DivColumnListContainer`.
* **Mục** tìm bằng cấu trúc: con trực tiếp của scroller chứa `<video>` (đo lại:
  đúng `ARTICLE`, là con trực tiếp, là tổ tiên của video). Không phụ thuộc tên class.
* **Bảng che** tìm bằng hình học (như mục trước): hộp phủ ≥ 40% khung nhìn, không
  chứa `<video>`, có `role`/`aria-modal`/`data-e2e` hoặc nền sáng.

Script không còn phụ thuộc vào việc `FloatWindow` có mặt đúng lúc: `pass()` chạy mỗi
giây, tự dựng lại scroller nếu nó bị thay, và bỏ qua video đã đúng kích thước nên
không giành giật layout với player của TikTok.

### Kiểm chứng

* `tests/tiktok-module.test.js` — **21** ca, chạy script được trích **nguyên văn**
từ `Sources/TikTokPlayer.swift` trên một DOM dựng theo số đo thật, kèm một mô hình
layout nhỏ tái hiện đúng chuỗi: `filled` chỉ đạt `420×860` khi mục là `100vw/100vh`
và **cả chuỗi** ra khỏi luồng — ca "kéo khỏi hàng flex" chứng minh điều đó bằng
cách chỉ ép hàng mà không ép chuỗi thì video vẫn `369` rộng. Thêm: `advance()` gọi
`scrollTo` trên hộp cuộn thật (không còn `window.scrollBy`), `ended` chỉ nhảy khi
bật, phím mũi tên, `loop` bị ngắt khi bật, gỡ bảng che theo hình học, 4 ca chống
dương tính giả, resume đúng ca 0:00, status `filled=1/1 walls=3`.
* `tests/tiktok-player/main.swift` — **35** ca native cho phần thuần Swift: đọc
status (thiếu khoá, khoá lạ, giá trị sai kiểu, chuỗi rỗng), dòng log, chuỗi giao
diện, khoá preference được ghim, và các bất biến khi lồng chuỗi (CSS không chứa
backtick hay `${`, script không thể đóng literal Swift).
* `swift build` sạch; **11** suite (3 native + 8 node) pass; `tools/build-diagnose.sh`
vẫn dựng được. `tests/tiktok-wall.test.js` được gộp vào bộ test module (file cũ đã xoá).
* **Đo lại trên trang thật**: `scrollerOf` tìm đúng `DivColumnListContainer`
  (scroll 860/15480), `itemOf` tìm đúng `ARTICLE` là con trực tiếp của nó và là tổ
  tiên của `<video>`, và cả ba luật cũ đều trả `false`.
* **Cần máy thật:** build lại, mở TikTok, và đọc dòng mới trong log:
  `TikTok autoScroll=on scroller=yes filled=1/1 items=18 walls=0`. `filled` phải
  bằng số video đang mount; nếu là `0/1` thì bố cục chưa áp được và dòng đó chính
  là thứ cần gửi lại thay vì ảnh chụp.

## Quyết định Audit: Gỡ bỏ hoàn toàn tính năng TikTok PiP (2026-09-26)

Theo kết quả audit toàn diện và sự đồng thuận của người dùng:
1. **Lý do gỡ bỏ**:
   - Xung đột triết lý "Vibe Coding" (lập trình tập trung sâu vs dopamine doom-scrolling).
   - Cuộc chiến kỹ thuật không bền vững với kiến trúc TUX, login modal, dynamic hashed class names và anti-bot của TikTok Web.
   - Gánh nặng tài nguyên: WKWebView chạy full SPA ngốn CPU/RAM và hao pin.
2. **Các thành phần đã gỡ**:
   - Xoá `Sources/TikTokPlayer.swift` và các test liên quan (`tests/tiktok-player/`, `tests/tiktok-module.test.js`).
   - `FloatWindow.swift`: Gỡ nút auto-scroll trên strip, gỡ menu item, gỡ TikTok CSS injection, gỡ allowlist domain và Referer headers của TikTok (`tiktok.com`, `tiktokcdn.com`, `tiktokv.com`, `byteoversea.com`, `ibytedtos.com`).
   - Extension: Gỡ tab & panel TikTok khỏi `popup.html`, `popup.js`, `popup.css`; gỡ `tiktok.com` khỏi `manifest.json`, `content.js` và `background.js`.
3. **Kết quả**:
   - `swift build` thành công sạch sẽ.
   - Toàn bộ test suites còn lại (AdClassifier, WatchAssist, movie ad, audio boost, black bars, banner blur, v.v.) pass 100%.
   - Giao diện popup tinh gọn thành 3 tab cốt lõi: **Video tab**, **Kho phim** và **Đã xem**.
