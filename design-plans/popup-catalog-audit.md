# Audit popup và kho phim VibeFloat — 30/09/2026

Đối chiếu source tại commit `eb3a262` cùng các thay đổi chưa commit trong workspace. Các nhận xét dưới đây ghi lại trạng thái trước khi sửa. Cả ba điểm đã được thực hiện theo yêu cầu người dùng; xem kết quả ở cuối báo cáo.

## Design language

- **Audited surface:** `extension/popup.html` và `extension/catalog.html`: chọn phim, tìm kiếm, bộ lọc, mở danh sách tập/server và phát nổi. Popup phục vụ thao tác nhanh, catalog phục vụ duyệt phim và xem thông tin.
- **Design sources:** `DESIGN.md` là tài liệu hiện hành, nêu rõ áp dụng cho popup Chrome và kho phim. Phạm vi nguồn phim theo yêu cầu người dùng và guard `VibeSiteAccess` đang chạy.
- **Documented decisions:** nền tối, màu accent `#ff3b5c`, system font; chữ tương tác tối thiểu 11 px ở popup và 13 px ở catalog; nguồn/phát YouTube giới hạn theo danh sách cho phép; cỡ popup do Chrome quản lý; catalog có menu cho màn hình nhỏ.
- **Governing owners and consumers:** HTML link trực tiếp `popup.css` / `catalog.css`. `popup.js` dùng `renderPopupMovies` và `renderPopupEpisodes`; `catalog.js` dùng `renderMovieCardsHtml` và render danh sách tập/server. `site-access.js`, được nạp cả trong popup/catalog và background, định nghĩa phạm vi nguồn; background kiểm tra trước khi mở video. Các rule cuối `catalog.css` ghi đè token và một số component của các lớp cinema cũ; đã kiểm tra các rule này trước khi kết luận.
- **Explicit exceptions:** popup desktop có chiều rộng cố định; ảnh phim, logo nguồn và badge nội dung được phép có màu riêng; platform traffic lights và hairline một pixel là ngoại lệ ghi trong DESIGN.md.

## Findings — trước khi sửa

| # | Problem | Evidence | Proposed change | Scope | Confidence |
| --- | --- | --- | --- | --- | --- |
| 1 | Lời hướng dẫn nhập link hứa phạm vi rộng hơn phạm vi được hỗ trợ. | `popup.html:74` ghi “Phát nhanh link bất kỳ”, `:76` đặt ví dụ YouTube. Trong cùng luồng, `popup.js:99–102` dùng `allowsPage` và trả lỗi nguồn không được phép. `catalog.html:303–304` hứa “mọi luồng HLS… MP4, YouTube… link nhúng”; request từ catalog vẫn qua `background.js:63–64` kiểm tra `allowsPlayback`. Đây là mâu thuẫn trực tiếp giữa hướng dẫn người dùng và giới hạn đã yêu cầu, không phải đề xuất nới quyền. | Viết lại nhãn, ví dụ và mô tả nhập link theo nguồn được hỗ trợ; chỉ dẫn YouTube về danh sách phim đã tuyển trong popup. | Popup Video tab + modal Dán link trong catalog. | Cao — chữ hiển thị và guard của đúng luồng được xác nhận từ source. |
| 2 | Chữ trên nút lọc/chọn tập thấp hơn chuẩn kích thước của sản phẩm. | `DESIGN.md:29` bắt buộc chữ tương tác ≥11 px ở popup, ≥13 px ở catalog. `popup.css:704` đặt chip 10.5 px, `:1048` server 10 px, `:1082` tập 10 px; class được tạo bởi `popup.html` và `popup.js:930/:940`. `catalog.css:918/:1565/:1610` lần lượt đặt audio-pill 11.5 px, server 12 px, tập 11.5 px; class nằm trong `catalog.html` và `catalog.js:1984/:2039`. Rule audio-pill muộn hơn ở `catalog.css:3354` không đổi font-size; rule cuối cho mobile nav không bao gồm ba class catalog này. | Nâng chữ của các owner hiện có: `.chip-btn`, `.popup-server-btn`, `.popup-ep-btn` lên tối thiểu 11 px; `.audio-pill`, `.server-tab-btn`, `.ep-btn` lên tối thiểu 13 px. | Bộ lọc và chọn bản/tập của cả hai giao diện. | Cao — vi phạm giá trị cụ thể, đã kiểm tra ghi đè CSS cuối. |
| 3 | Nhãn của cùng nút chọn tập không nhất quán giữa lần đầu và khi thu gọn. | `popup.js:745` tạo `.ep-pick-btn` với nhãn “Chi tiết”. Khi thu gọn ở `:780`, hoặc mở một phim khác ở `:786`, cùng nút trở thành “Tập ▾”. Nội dung được dựng ở `:947` chỉ là server tabs + episode buttons. Cùng trạng thái thu gọn, cùng hành động nhưng hai tên khác nhau. | Dùng “Chọn tập ▾” cho tất cả trạng thái thu gọn của `.ep-pick-btn`, giữ nhãn mở rộng thể hiện thao tác thu gọn. | Danh sách phim trong popup. | Cao — mâu thuẫn nhãn nằm trong cùng handler và cùng component. |

## Improve first

Sửa **#1 — hướng dẫn nhập link** trước. Nó xuất hiện trước khi phát, liên quan trực tiếp đến giới hạn nguồn người dùng đã chọn, và có thể khiến người dùng thử một link bị chặn rồi tưởng ứng dụng lỗi. Correction chỉ thay lời hướng dẫn, không mở rộng quyền hay thay chính sách nguồn.

## Giới hạn kiểm chứng

Công cụ Browser Use từ chối mở `chrome-extension://…/popup.html`: chính sách chỉ cho phép `http:` và `https:`. Không dùng cách vòng qua giới hạn này. Vì chưa có ảnh render mới, báo cáo không chấm điểm độ đẹp, độ chật, vị trí hero, số card nhìn thấy, clipping thực tế hay mức độ nổi bật của nút. Những phần đó cần ảnh hoặc phiên kiểm tra giao diện được phép.

Các điểm đã có trong implementation: popup khởi tạo ở Kho phim / Phim hot; có ô tìm kiếm, tiếp tục xem và nút mở catalog; catalog có trạng thái tải/lỗi và nút thử lại, nhãn metadata tùy nguồn, và menu ở viewport nhỏ. Đây là xác nhận từ source, không phải kết quả kiểm chứng tương tác thực tế.

Lượt audit ban đầu không thay đổi sản phẩm. Lượt sửa tiếp theo cập nhật HTML, CSS và JavaScript như ghi dưới đây.

## Kết quả thực hiện

- **#1 đã sửa:** popup và modal Dán link nói rõ HTTPS / nguồn phim được hỗ trợ, thay placeholder YouTube / example.com bằng nguồn phim, thêm hướng dẫn YouTube theo danh sách đã tuyển. Input liên kết với mô tả bằng `aria-describedby`; popup có label gắn với input. Câu lỗi nhập link trong catalog dùng cùng thuật ngữ. Bỏ `NSPanel` / `Float Window` khỏi hướng dẫn phát/chọn tập.
- **#2 đã sửa:** chip lọc, server và tập ở popup dùng 11 px; audio filter, server, tập, nguồn và bộ lọc dropdown ở catalog dùng 13 px. Giữ override 14 px của menu trên màn hình nhỏ. Sửa trực tiếp các declaration đang sở hữu giá trị, gồm cả rule nav-select-filter muộn, không thêm một lớp font override mới.
- **#3 đã sửa:** tất cả trạng thái thu gọn của nút popup dùng “Chọn tập ▾”; trạng thái mở dùng “Thu gọn ▲”; tooltip nói “Chọn tập và bản phát”.
- **Kiểm chứng:** kiểm tra cú pháp popup.js / catalog.js và `git diff --check` qua; các suite `site-access`, `popup-hot`, `catalog-feed`, `ai-dubbing-sync` đều qua. Không thêm quyền hay đổi danh sách nguồn / video YouTube. Không có thay đổi native nên không cần build/cài lại companion.
- **Giới hạn:** chưa xác minh render thực tế, do Browser Use trước đó chặn giao thức chrome-extension; không thử đường vòng. Đóng/mở lại popup và tải lại tab Kho phim để xem giao diện cập nhật từ extension unpacked.

## Rút gọn popup theo ảnh người dùng

Đã bỏ Video tab, Đã xem, thanh chuyển tab, ô tìm kiếm và các chip danh mục khỏi popup. Popup mở thẳng danh sách phim hot; giữ chọn nguồn, làm mới, phát/chọn tập, phim YouTube đã tuyển và mở catalog. “Xem tất cả” ở Tiếp tục xem mở catalog. Lịch sử và bộ lọc/tìm kiếm trong catalog được giữ. Kiểm tra `popup-startup.test.js` qua: khởi tạo không truy cập phần tử đã bỏ, tải phim khi mở, đổi nguồn/làm mới vẫn hoạt động, một lần bấm chỉ mở một tab catalog.
