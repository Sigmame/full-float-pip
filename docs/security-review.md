# VibeFloat / Freebuff Desktop — Báo cáo review bảo mật & chất lượng (đã hiệu chỉnh)

- **Repo:** `full-float-pip` · **Nhánh:** `pr/native-vibe-player` · **Commit:** `317060e`
- **Phạm vi:** `extension/` (MV3), `native-app/Sources/` (AppKit + WKWebView), `scripts/`, `docs/`
- **Phương pháp:** đọc trực tiếp source, `git blame` cho các kết luận có tranh chấp. **Chưa** chạy app, chưa dynamic test.
- **Trạng thái:** bản này thay thế báo cáo review trước đó. Mọi kết luận đều có file:dòng kiểm chứng được.
- **Cập nhật xử lý:** mục 1.1, 2.2, 3.2 và phần `*.google.com` của 2.3 **đã được xử lý** trong working tree theo Phase 1 của `docs/remediation-plan.md` (chưa commit). Các mục còn lại vẫn nguyên trạng.

---

## 0. Kết luận nhanh

Báo cáo gốc có **7 phát hiện đúng**, **3 phát hiện sai/cần đính chính**, và **bỏ sót 3 bề mặt**. Mức độ nghiêm trọng tổng thể: **trung bình–cao**, tập trung ở một chỗ duy nhất là *đường cookie YouTube/Google → WebView native*.

- Không tìm thấy đường RCE, ghi file tùy ý, shell injection, hay native messaging mở ngoài `allowed_origins` khi Extension ID được cấu hình đúng.
- Toàn bộ listener HTTP chỉ bind `127.0.0.1`.
- Rủi ro cao nhất là *phạm vi* của đường cookie — rộng hơn báo cáo gốc mô tả (mục 2.2).

| # | Phát hiện | Báo cáo gốc | Sau đối chiếu | Mức |
|---|---|---|---|---|
| 1 | Cookie YouTube/Google bơm sang WebView native | có | **Đúng** (và rộng hơn) | Cao |
| 2 | HTML nhúng không escape (`buildEmbedHTML`) | có | **Đúng** | Cao |
| 3 | Không có `navigationPolicy` | có | **Đúng** | Trung bình |
| 4 | `/play`, `/health` không cần token | có | **Đúng**, nhưng tác động thấp | Thấp–TB |
| 5 | `install.sh` ghi `chrome-extension://*/` | có | **Đúng** | Trung bình |
| 6 | Hotkey Carbon toàn hệ thống, không giới hạn vòng đời | có | **Đúng** | Trung bình |
| 7 | `confirm()` luôn trả `true`, `alert()` tự dismiss | có | **Đúng** | Thấp |
| 8 | `preferVietnameseServerIndex` trả sai index | có | **SAI — false positive** | — |
| 9 | "Popup/catalog không gửi được message cookie" | có | **SAI — ngược lại** | — |
| 10 | `host_permissions` `*.google.com` là thừa | có | **SAI — quyền này đang dùng thật** | — |
| 11 | `loadHTMLString` với `baseURL` ngoài | — | **Bỏ sót** | Cao |
| 12 | Cờ `httpOnly` bị hạ cấp khi bơm cookie | — | **Bỏ sót** | Trung bình |
| 13 | `/play` không token: tác động thấp hơn mô tả | — | **Đính chính mức độ** | Thấp |

---

## 1. Phát hiện được xác nhận đúng

### 1.1 Cookie YouTube/Google được chuyển sang tiến trình native (Cao)

`extension/background.js:147-165`:

```js
if (videoInfo.site === 'youtube') {
    const ytCookies = await chrome.cookies.getAll({ domain: '.youtube.com' });
    const googleCookies = await chrome.cookies.getAll({ domain: '.google.com' });
    const allCookies = [...ytCookies, ...googleCookies];
    message.cookies = allCookies.map(c => ({
        name: c.name, value: c.value, domain: c.domain,
        path: c.path, secure: c.secure, httpOnly: c.httpOnly,
    }));
}
```

Bao gồm cả cookie `httpOnly`. Ở phía native, `FloatWindow.swift:1365` `injectCookies(_:completion:)` dựng lại `HTTPCookie` **với `domain` do chính message tự khai** (`FloatWindow.swift:1373`: `cookieData["domain"] as? String ?? ".youtube.com"`) rồi nạp vào `httpCookieStore` của WebView; sau đó `FloatWindow.swift:1323-1327` mở watch page trong session đã đăng nhập.

Hệ quả: tiến trình native (và bất kỳ JS chạy trong WebView đó) nắm được phiên Google/YouTube đầy đủ, không cần người dùng đăng nhập lại. Đây là bề mặt tấn công lớn nhất của app.

### 1.2 HTML nhúng không escape (Cao)

- `FloatWindow.swift:2251` — `buildEmbedHTML(embedUrl:)` nội suy thẳng `\(embedUrl)` vào `<iframe src="...">`, **không escape gì cả**. Một `embedUrl` chứa `"` sẽ thoát khỏi thuộc tính `src` và chèn được markup/thuộc tính tùy ý (kể cả event handler).
- `FloatWindow.swift:1897-1901` — `buildVideoHTML(videoSrc:currentTime:)` chỉ escape `\`, `"`, `\n`, `\r`; **không** escape `<`, `>`, `/`, nên `</script>` hoặc `</style>` đóng thẻ sớm và mở đường chèn `<script>` mới vào tài liệu đã nạp.

`embedUrl`/`videoSrc` đến từ `content.js` (`_getEmbedUrl()`) và từ trường `linkM3u8`/`linkEmbed` của API phim bên thứ ba — tức dữ liệu **không đáng tin**.

### 1.3 Không có navigation policy (Trung bình)

Class `FloatWindow: NSPanel, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler` (`FloatWindow.swift:479`) implement `didFinish`, `didFail`, `didFailProvisionalNavigation` và `createWebViewWith` (trả `nil` để chặn popup, `FloatWindow.swift:2256-2258`), nhưng **không có `decidePolicyFor`** (grep toàn repo: 0 match). Nghĩa là mọi redirect/`window.location`/`load(URLRequest)` do nội dung bên trong quyết định đều được cho phép, kể cả `http://` và host ngoài allowlist.

### 1.4 `/play` và `/health` thiếu xác thực (đã khắc phục)

Đã khắc phục trong working tree: `/play` yêu cầu capability riêng, `/health` yêu cầu `x-vibefloat-token`; các kiểm tra Origin/Referer chỉ còn là defense in depth.

### 1.5 `install.sh` có thể ghi wildcard origin (Trung bình)

`scripts/install.sh:77-83`: nếu người dùng bỏ trống Extension ID, script đặt `EXT_ID="*"` rồi ghi `"chrome-extension://*/"` vào manifest native messaging. Về mặt kỹ thuật Chrome yêu cầu origin extension cụ thể, nên giá trị này thường **không** khớp extension nào (fail-closed) — nhưng nó khuyến khích cấu hình sai, còn nếu khớp theo một cách diễn giải lỏng nào đó thì mọi extension đều gọi được native host. Nên chặn hẳn thay vì in cảnh báo.

### 1.6 Hotkey Carbon toàn hệ thống, không gắn với vòng đời cửa sổ (Trung bình)

- `VibeDock.swift:639-655` đăng ký 15 hotkey, trong đó có `⌘⇧Space`, `⌘⇧G`, `⌘⇧B`, `⌘⇧D` (id 1–4).
- `AppDelegate.swift:204` gọi `hotkeys.install(...)` ngay khi launch, **không** kiểm tra cửa sổ nổi có đang mở hay không.
- `AppDelegate.swift:239-241`: `applicationShouldTerminateAfterLastWindowClosed` trả `false` → tiến trình vẫn sống sau khi đóng cửa sổ, hotkey **vẫn chiếm** tổ hợp.

`⌘⇧G` trùng *Find Previous* (Xcode, Chrome, nhiều editor) và `⌘⇧B`/`⌘⇧D` trùng các lệnh build/debug quen thuộc. Đây là lỗi "chiếm phím toàn cục" điển hình: người dùng không có cách tắt trong UI.

### 1.7 `confirm()` luôn `true`, `alert()` tự dismiss (Thấp)

`FloatWindow.swift:2260-2273`: `runJavaScriptAlertPanelWithMessage` gọi `completionHandler()` ngay (coi như đã xác nhận), `runJavaScriptConfirmPanelWithMessage` gọi `completionHandler(true)` — mọi hộp thoại xác nhận từ nội dung bên thứ ba bị tự động chấp nhận.

---

## 2. Đính chính các phát hiện SAI trong báo cáo gốc

### 2.1 `preferVietnameseServerIndex` KHÔNG có bug (false positive — loại bỏ)

Báo cáo gốc mô tả hàm gán biến trong vòng lặp sai cách và trả về index sai. Code thực tế (`extension/movie-service.js:1229-1242`):

```js
preferVietnameseServerIndex(servers) {
    if (!servers?.length) return 0;
    let bestIdx = 0;
    let bestRank = Infinity;
    for (let i = 0; i < servers.length; i++) {
        const s = servers[i];
        if (s?.items && s.items.length === 0) continue;
        const rank = this._serverAudioRank(s);
        if (rank < bestRank) { bestRank = rank; bestIdx = i; }
    }
    return bestIdx;
}
```

`bestIdx`/`bestRank` khai báo **ngoài** vòng lặp, chỉ ghi lại khi `rank < bestRank` — đúng thuật toán chọn min, xử lý được cả mảng rỗng và mảng chỉ có server không item. `git blame` cho khối này (`a22aa59d`, 2026-09-24) xác nhận hàm đúng ngay từ lần thêm đầu tiên, **chưa từng có regression**. Kết luận: **không phải lỗi, không cần sửa**.

### 2.2 "Popup/catalog không gửi được message cookie" — SAI, và sự thật làm finding cookie NẶNG hơn

Báo cáo gốc cho rằng chỉ content script/shortcut mới đi vào đường cookie. Thực tế **cả popup và catalog cũng đi vào đường đó**, vì điều kiện kích hoạt cookie nằm ở `background.js` và chỉ phụ thuộc `videoInfo.site`, không phụ thuộc sender:

- `movie-service.js:294` — `buildYouTubeLiveFloatInfo()` đặt `site: 'youtube'`.
- `popup.js:189` và `popup.js:186` (gọi builder) → `FLOAT_VIDEO_REQUEST`.
- `catalog.js:283` và `catalog.js:845` (gọi builder ở `catalog.js:272`, float livetv ở `catalog.js:839`) → `FLOAT_VIDEO_REQUEST`.
- `background.js:344` route `FLOAT_VIDEO_REQUEST` → `manager.floatVideo()` → nhánh cookie ở `background.js:147`.

Vậy bề mặt cookie gồm **4 nguồn**: content script, `chrome.commands`, popup, catalog. Việc đính chính này không giảm nhẹ mà **tăng** mức độ nghiêm trọng của phát hiện 1.1.

### 2.3 `host_permissions: https://*.google.com/*` KHÔNG thừa

`chrome.cookies.getAll({ domain: '.google.com' })` (`background.js:150`) **bắt buộc** có host permission `google.com` — bỏ quyền này thì lệnh gọi sẽ throw. Ngược lại, ba quyền dưới đây mới thực sự thừa vì **không có lệnh gọi nào** dùng chúng (chỉ xuất hiện trong `extension/manifest.json:17-19`):

- `https://*.tiktokv.com/*`
- `https://*.tiktokcdn.com/*`
- `https://*.byteoversea.com/*`

Lưu ý về thứ tự đúng: "đúng thuốc" **không** phải là bỏ quyền `google.com` (đó là hệ quả), mà là **bỏ hẳn việc đọc cookie Google** trước, rồi mới gỡ quyền tương ứng. Nếu gỡ quyền trước khi sửa code, tính năng sẽ hỏng.

---

## 3. Bề mặt báo cáo gốc bỏ sót

### 3.1 `loadHTMLString` với `baseURL` do nguồn ngoài quyết định (Cao)

`FloatWindow.swift:1306`:

```swift
webView.loadHTMLString(html, baseURL: URL(string: videoSrc))
```

`videoSrc` đến từ `content.js` hoặc `linkM3u8` của API bên thứ ba. Trong WKWebView, `baseURL` (khi là URL http/https) trở thành **origin** của tài liệu HTML vừa nạp: nó quyết định `window.location.origin`, cách resolve URL tương đối, và Referer gửi ra. Nghĩa là bên ngoài kiểm soát được origin của một tài liệu mà app đang chạy trong WebView có đặc quyền.

Đây là **cùng họ** với lỗi escape ở 1.2 và nên được xử lý chung: validate scheme + host allowlist cho `videoSrc`/`embedUrl` **trước** khi nội suy vào HTML hoặc dùng làm `baseURL`.

### 3.2 Cờ `httpOnly` bị hạ cấp khi bơm cookie (Trung bình)

`background.js:158` có gửi kèm `httpOnly: c.httpOnly`, nhưng phía native **không dùng** giá trị này: `FloatWindow.swift:1378-1386` chỉ dựng `HTTPCookiePropertyKey` cho `name/value/domain/path/(secure)` — API `HTTPCookiePropertyKey` không có khoá `httpOnly`. Cookie sau khi bơm do đó **không còn `HttpOnly`**, và trở nên đọc được bằng `document.cookie` trong WebView đó. Kết hợp với 1.2 (chèn script được) và 3.1 (origin do nguồn ngoài quyết định), đây là mắt xích làm chuỗi khai thác liền mạch: code bên thứ ba → chèn script → đọc toàn bộ phiên YouTube/Google.

### 3.3 `/play` trước đây không token: tác động THẤP hơn báo cáo gốc ngụ ý (đã khắc phục)

Trước khi sửa, `/play` chỉ chấp nhận `site == "youtube"` và video ID hợp lệ nhưng không có capability, còn `/health` trả `"OK"` vô điều kiện. Hiện `/play` dùng capability riêng và `/health` dùng API token.

---

## 4. Lựa chọn thiết kế có chủ đích — KHÔNG phải lỗi

Ghi lại để lần review sau không đánh dấu nhầm:

- **Cửa sổ nổi trên mọi app**: mức `maximumWindow + 1`, `canJoinAllSpaces`, và quét cửa sổ qua Accessibility để né editor. Đây là *mục tiêu sản phẩm*, không phải bug. Rủi ro kèm theo (đã ghi nhận, không xếp loại lỗi): có thể che cả dialog xin quyền riêng tư của macOS; đọc được hình học ô nhập của app khác qua AX API.
- **`createWebViewWith` trả `nil`**: popup bị chặn là hành vi mong muốn.
- **Không có đường ghi file tùy ý / thực thi shell / native messaging mở**: native host chỉ nhận message từ extension đã đăng ký trong `allowed_origins` (`scripts/install.sh:90`), miễn ID được cấu hình đúng (xem 1.5).
- **Token API**: `UUID().uuidString` (`LocalHTTPServer.swift:11`) ≈ 122 bit ngẫu nhiên, đủ tốt. Vấn đề chỉ nằm ở *cách lưu* (mục 3.3 kế hoạch), không ở entropy.

---

## 5. Tổng kết thứ tự ưu tiên

| Ưu tiên | Nội dung | Nguồn |
|---|---|---|
| **P0** | Siết đường cookie: bỏ Google, chỉ giữ phiên YouTube, allowlist domain ở native | 1.1, 2.2, 3.2 |
| **P0** | Escape/validate `embedUrl`, `videoSrc`; kiểm soát `baseURL` | 1.2, 3.1 |
| **P1** | Thêm `decidePolicyFor` allowlist scheme + host | 1.3 |
| **P1** | Token cho `/play` + `/health`; hardening file token/port | 1.4, 3.3 |
| **P1** | `install.sh` từ chối wildcard Extension ID | 1.5 |
| **P1** | `confirm()` trả `false`; không tự dismiss `alert()` | 1.7 |
| **P2** | Hotkey chỉ đăng ký khi cửa sổ nổi mở, và cho phép tắt | 1.6 |
| **P2** | Dọn `host_permissions` thừa (tiktokv/tiktokcdn/byteoversea) | 2.3 |

Chi tiết cách xử lý, thứ tự commit và tiêu chí nghiệm thu: xem `docs/remediation-plan.md`.

## Audit follow-up fixes (2026-09-25)

- Cookie mirror đã giữ `HttpOnly` bằng cách parse `Set-Cookie` header và kiểm tra `cookie.isHTTPOnly`.
- Log URL native đã được redacted về scheme/host, loại bỏ query string và capability.
- Installer manifest và native host wrapper dùng file tạm, mode 0600, chống symlink và thay thế atomic.
- Các trường catalog remote `sec.id`, `rating`, `rank`, `year`, `quality` đã được escape trước khi nội suy HTML.
