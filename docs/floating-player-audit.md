# Audit cửa sổ nổi VibeFloat — 30/09/2026

Phạm vi: khung video, thanh tiêu đề, thanh điều khiển rời, timeline, trạng thái phát, chuyển tập, menu, cỡ cửa sổ, rê chuột, kéo/resize và phím tắt. Đối chiếu giao diện AppKit đang chạy với `DESIGN.md`; giữ cơ chế panel không chiếm focus của trình soạn thảo.

## Ba vấn đề chính và thay đổi

1. **Nút phát phim mất chỗ ở cửa sổ nhỏ.** Bố cục cũ dành trước phần lớn chiều ngang cho chip kích thước, khóa, xuyên chuột và giảm âm. Các nút tua, âm lượng và chuyển tập có thể bị ẩn. Bố cục mới giữ phát/dừng, tua ±10 giây, tắt tiếng, menu và đóng ở mọi chiều rộng hỗ trợ. Các nút phụ xuất hiện theo khoảng trống; cỡ cửa sổ chuyển vào menu con. Nút chuyển tập dùng biểu tượng và tooltip, vô hiệu hóa tại đầu/cuối danh sách.

2. **Thiếu ngữ cảnh và khó đọc tiến độ.** Thanh tiêu đề biến mất khi không rê chuột; đồng hồ cũ chỉ có 92 pt. Thanh điều khiển mới có hàng tên phim 13 pt và trạng thái phát, tooltip cho tên đầy đủ, số tập và thời gian còn lại. Đồng hồ 144 pt đủ hiển thị giờ của cả vị trí hiện tại và tổng thời lượng. Ba hàng nằm trong 100 pt; VibePlacer dùng cùng hằng số để đặt cả video và thanh điều khiển trong màn hình.

3. **Theo dõi và thao tác chưa ổn định.** Poll trạng thái cũ ghi đè thời gian khi kéo timeline. Bản mới giữ thời gian xem trước khi rê/kéo, chỉ seek khi thả, và không cho seek khi chưa có thời lượng hợp lệ. Tạm dừng giữ thanh điều khiển hiện; phát tiếp khôi phục tự ẩn. Menu thêm “Luôn hiện thanh điều khiển”, chọn tốc độ trực tiếp, nhóm âm thanh/lồng tiếng, kích thước và tùy chọn khác. Nút phát có nhãn accessibility theo trạng thái và tooltip phím tắt.

## Kiểm chứng

- Debug và release build thành công.
- `floating-player-layout.swift`: kiểm tra mỗi bước 4 pt từ 280 đến 1.600 pt, có/không có danh sách tập; nút thiết yếu luôn tồn tại, không chồng nhau, không tràn, tên/trạng thái và timeline/đồng hồ tách biệt.
- Kiểm tra AppKit bằng Computer Use: cửa sổ video thật và fixture dùng **chính view điều khiển production** ở 380 pt; kiểm tra menu mới, chọn 1.5x và xác nhận nút cập nhật.
- `youtube-player.test.js` và `embedded-media-control.test.js`: bridge phát, seek, âm lượng và trạng thái qua player nhúng.
- `youtube-playback-e2e.py --controls`: WebView thật phát phim YouTube đã chọn, đồng hồ chạy, thời lượng phim hợp lệ, xuyên chuột tắt; kiểm tra pause, seek +10 giây và resume.
- `git diff --check`.
- Chạy `scripts/install.sh` thành công với extension ID hiện có; xác minh chữ ký bundle, UUID và các section mã thực thi khớp bản release. E2E pause/seek/resume cũng qua trên executable đã cài.

Fixture minh họa đồng hồ với dữ liệu mẫu, không dùng làm bằng chứng phát video. Kiểm chứng phát video là E2E riêng. Chưa có kiểm chứng phát trực tiếp cho mọi server phim bên thứ ba hay phiên lồng tiếng offline trong đợt audit này.

## Chạy lại

```sh
swift build --package-path native-app
swiftc native-app/Sources/FloatingPlayerLayout.swift native-app/tests/floating-player-layout.swift -o /tmp/vibefloat-layout-test
/tmp/vibefloat-layout-test
python3 native-app/tests/preview-floating-player.py
python3 native-app/tests/youtube-playback-e2e.py --controls
```

Bản cập nhật giữ lồng tiếng và xuyên chuột mặc định tắt, cùng phạm vi truy cập trang phim và danh sách YouTube đã chọn.

## Cập nhật kích thước sau audit

- Nhỏ 480 pt, Vừa 640 pt, Rộng tối đa 960 pt. Với video 16:9 trên màn hình đủ rộng, vùng video lần lượt là 480×270, 640×360 và 960×540 pt. Khi thanh điều khiển hiện, tổng chiều cao là 376, 466 và 646 pt.
- Ngân sách cỡ Rộng: tối đa 75% chiều ngang và 85% chiều cao vùng màn hình khả dụng, tính cả thanh điều khiển và khoảng cách. Trên màn hình chật, các cỡ nhỏ hơn cũng được giới hạn để thứ tự Nhỏ ≤ Vừa ≤ Rộng luôn đúng.
- Mở lại dùng preset đã lưu; mặc định khi chưa có lựa chọn là Vừa. Giới hạn màn hình và tỷ lệ video vẫn được áp dụng.
- Khi thiếu vùng trống, tự bố trí ưu tiên đổi vị trí và giữ kích thước preset hoặc kích thước kéo tay. Không tự thu về 380 pt hay khôi phục một khung cũ sau khi người dùng đã chọn cỡ mới. Cửa sổ lớn vẫn có thể che một phần vùng làm việc nếu màn hình không còn đủ chỗ.
- Menu và HUD dùng đơn vị `pt`. Cỡ Lớn theo ô trống vẫn được giữ riêng.

Kiểm chứng bổ sung: `floating-player-size-presets.swift` kiểm tra 480/640/960, các màn hình 640×480 đến 2560×1440, thứ tự các cỡ, ngân sách màn hình, tỷ lệ và giới hạn video dọc. `preview-floating-player.py --check-presets` chạy các cửa sổ AppKit production thật để kiểm tra nhớ preset khi mở, giữ kích thước khi tránh vùng làm việc, thay preset khi đang ở chế độ tránh vùng làm việc, và mở lại. Cả hai đã qua.
