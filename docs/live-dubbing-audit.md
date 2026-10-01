# Audit phụ đề live và lồng tiếng AI — 2026-09-27

## Luồng thực tế

Chrome: `sub-interceptor.js` nhận VTT/SRT/timedtext từ `fetch`/XHR → `ai-dubbing.js` ghép timeline hoặc đọc `TextTrack.activeCues`/DOM → native messaging → `AppDelegate` dịch sang tiếng Việt → `EdgeTTSManager` tạo MP3 → `AVAudioPlayer` phát. Cửa sổ nổi dùng script riêng trong `FloatWindow.swift` và cùng các dịch vụ dịch/TTS native.

## Phát hiện và xử lý

| Mức | Phát hiện | Xử lý |
| --- | --- | --- |
| Cao | Extension gọi `prefetchUpcomingTrackCues` nhưng hàm không tồn tại; sự kiện cue và thêm track có thể dừng bởi `TypeError`. | Dùng trích cue + `pollChunkAhead` hiện có. |
| Cao | Dịch/TTS bất đồng bộ có thể hoàn tất sau khi tua, pause, đổi video hoặc tắt lồng tiếng, rồi phát sai cảnh. | Thêm thế hệ phát ở JS và native; loại bỏ callback cũ, kiểm tra cue còn trong khoảng thời gian phát trước khi nói. |
| Cao | Extension dịch qua `fetch` từ content script, dù yêu cầu khác origin từ content script vẫn chịu same-origin policy; WKWebView cũng có thêm một vòng dịch JS trước native. Lỗi có thể khiến giọng Việt đọc nguyên câu ngoại ngữ hoặc mất câu. | Cả Chrome và cửa sổ nổi gửi văn bản gốc cho native; dịch và nạp trước dùng chung cache tại native. [Chrome: cross-origin requests](https://developer.chrome.com/docs/extensions/develop/concepts/network-requests). |
| Cao | Batch dịch nối câu bằng newline rồi tách kết quả theo vị trí; dịch vụ có thể thay đổi ngắt dòng, ghép nhầm thoại. | Dịch từng cue, giới hạn 4 yêu cầu đồng thời, giữ ánh xạ theo câu gốc. |
| Trung bình | Mọi `TextTrack` đang tắt bị bật `hidden`; nhiều ngôn ngữ cùng được đọc, kết quả phụ thuộc thứ tự track. | Chọn track đang hiện trước, sau đó track đã ẩn, rồi ưu tiên `vi`, `en`; cập nhật khi `TextTrackList.change`. `cuechange` và `activeCues` là tín hiệu chuẩn cho cue hiện tại. [MDN: cuechange](https://developer.mozilla.org/en-US/docs/Web/API/HTMLTrackElement/cuechange_event), [MDN: track change](https://developer.mozilla.org/en-US/docs/Web/API/TextTrackList/change_event). |
| Trung bình | Worker Edge TTS cache theo text + voice, bỏ qua tốc độ; cùng câu ở hai thời lượng tái dùng nhầm file. `terminateWorker` giữ lock rồi gọi hàm tự lấy lock. | Thêm rate vào khóa cache và sửa thứ tự khóa/dọn worker. |
| Trung bình | URL dịch ghép bằng `.urlQueryAllowed`; ký tự `&` trong thoại có thể thành tham số URL khác. | Dùng `URLComponents`/`URLQueryItem`. |
| Trung bình | Trang có thể đưa nội dung subtitle quá lớn qua `postMessage`, khiến parse và lưu timeline tốn bộ nhớ. | Giới hạn payload 2 MiB, kiểm tra URL và nguồn message trong extension. |

## Giới hạn còn lại

- Google Translate endpoint `client=gtx` và worker dựa vào các symbol nội bộ của `edge_tts.communicate`. Đây là phụ thuộc dễ đổi; cần thiết kế adapter cho nhà cung cấp dịch và TTS chính thức, kèm cấu hình khóa/dữ liệu trước khi chuyển. [edge-tts project](https://github.com/rany2/edge-tts), [Microsoft Speech REST API](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/rest-text-to-speech).
- Nội dung phụ đề được gửi ra Google Translate khi cần dịch và ra dịch vụ giọng Edge khi tổng hợp. Cần hiển thị rõ luồng dữ liệu này trong phần giới thiệu/quyền riêng tư trước khi phát hành rộng.
- Chưa đo được độ lệch tiếng với video và tỉ lệ mất câu trên trang phim thật trong môi trường tự động. Cần smoke test phim có VTT và iframe: bật/tắt, tua tới trước/sau, pause/resume, đổi track `vi`/`en`, phát liên tục 15 phút; ghi số câu sai/ngắt và độ lệch đầu tiếng so với cue.
- Hai script lồng tiếng (Chrome và WKWebView) vẫn có logic đọc phụ đề riêng. Khi thay parser hoặc lịch phát, cần chạy cùng bộ tình huống trên cả hai đường.

## Theo dõi độ trễ 1–3 giây

Sau báo cáo ban đầu, kiểm tra lại đường tạo giọng cho thấy nạp trước và phát dùng **hai tốc độ tổng hợp khác nhau**. Vì tốc độ là một phần của khóa cache, cue đến hạn thường tạo yêu cầu MP3 mới. Nhiều yêu cầu nạp trước trong cửa sổ 35 giây cũng có thể chiếm chỗ của cue hiện tại. Đã thống nhất tốc độ tổng hợp, gộp các yêu cầu TTS và dịch trùng nhau khi đang chạy, giữ tối đa 8 cue/12 giây nạp trước, giảm debounce DOM từ 200 ms xuống 40 ms, và để câu mới thay âm thanh câu cũ ngay khi MP3 sẵn sàng. Kết quả cũ đến sau câu mới hoặc sau khi cue hết thời gian sẽ bị bỏ. Bài thử Edge TTS thực xác nhận hai yêu cầu đồng thời dùng chung một file MP3.

Nếu phụ đề chỉ xuất hiện trong **pixel video**, không có cue/track/tệp phụ đề truy cập được, app phải chụp khung hình, OCR rồi mới tạo giọng; không thể nạp trước câu chưa biết. Đường OCR hiện dùng Vision `.accurate` với `vi-VN`. Apple nêu rõ `.fast` ưu tiên tốc độ nhưng giảm độ chính xác, và trên máy thử `vi-VN` không có trong danh sách ngôn ngữ hỗ trợ của `.fast`; chuyển mù sang `.fast` có thể làm mất phụ đề tiếng Việt. [Apple: recognition level](https://developer.apple.com/documentation/vision/vnrecognizetextrequest/recognitionlevel?changes=__7_4&language=objc), [Apple: language support](https://developer.apple.com/documentation/vision/recognizing-text-in-images?changes=_3_3).

### Kết quả test thực tế

`native-app/tests/live-dubbing-e2e.py` đã dựng một app bundle tạm có quyền macOS và phát video local 13 giây với 3 cue VTT tiếng Việt. Bản đo OCR cũ (để kiểm tra fallback chậm nhất) có độ trễ **0.660s, 0.538s, 0.499s** từ `OCR found cue` đến `window audio started`. Bản đo timeline hiện tại bắt được cue trước OCR: cue đầu tiên lạnh khoảng **0.808s**, hai cue đã nạp trước chỉ **0.016s và 0.018s**. Test pass với ngưỡng warm cue dưới 0.5 giây. Đây chưa phải phép đo trên website thật; cần thêm smoke test với iframe và track của từng nguồn video.

### Lỗi đồng bộ WebView được tìm thấy sau test

Native mặc định bật lồng tiếng nhưng script AI trong WebView khởi tạo `enabled: false`. `setAIDubEnabled(true)` chạy trước khi trang tồn tại và trả về sớm, nên track VTT có thể tồn tại nhưng timeline engine không chạy; app rơi xuống OCR. Đã sửa bằng cách đặt mặc định script đồng nhất với native và đồng bộ lại sau mỗi `didFinish` navigation. Test VTT sau sửa ghi nhận cue đầu tiên lạnh khoảng **0.808s**, còn hai cue đã nạp trước bắt đầu sau **0.016s và 0.018s**. Đây là nguyên nhân chính của độ lệch lớn khi mở video mới.

## Nghiên cứu nguồn phụ đề và chiến lược nhanh nhất

### Thứ tự ưu tiên nên dùng

1. **Cue native của player**: `TextTrack.cues`/`activeCues`, `cuechange`, và tệp VTT/SRT/timedtext đã được player tải. Đây là đường duy nhất biết chính xác thời điểm xuất hiện; nạp trước 8 cue trong 12 giây giúp TTS hoàn tất trước khi cue đến.
2. **Bắt response phụ đề không phụ thuộc tên URL**: nhiều CDN dùng URL JSON hoặc URL ký tên không có `.vtt`. Interceptor hiện kiểm tra thêm `Content-Type` và hình dạng payload, đồng thời vẫn giới hạn payload. Điều này đã được bổ sung cho fetch và XHR ở cả extension và WebView.
3. **OCR pixel**: chỉ dùng khi không có track hay response phụ đề. OCR không thể đọc trước chữ chưa xuất hiện, nên luôn có độ trễ nhận dạng + dịch + TTS; với tiếng Việt không nên ép Vision `.fast` nếu máy không hỗ trợ ngôn ngữ đó.
4. **Tìm phụ đề bên ngoài có định danh**: chỉ chạy khi trang cung cấp IMDb/TMDB hoặc người dùng nhập tên phim/tập. TMDB có endpoint tìm theo external ID; SubDL cho tìm theo `imdb_id`, `tmdb_id`, mùa/tập và ngôn ngữ nhưng yêu cầu API key; OpenSubtitles API yêu cầu API key và token người dùng cho tải. [TMDB: finding data](https://developer.themoviedb.org/docs/finding-data), [SubDL API](https://subdl.com/api-doc), [OpenSubtitles API overview](https://opensubtitles.stoplight.io/docs/opensubtitles-api/). Không nên tìm chỉ bằng tiêu đề vì dễ lấy nhầm tập hoặc bản phát hành lệch timestamp.

### Vì sao chưa tự động tải từ mọi trang

Phụ đề ngoài thường lệch bản phát hành, FPS, đoạn mở đầu hoặc quảng cáo. Muốn dùng được phải chấm điểm khớp theo định danh, ngôn ngữ, season/episode, release name và so sánh cue đầu tiên; nếu lệch cần áp dụng offset hoặc từ chối. API còn có khóa, quota và điều khoản riêng. Thiết kế phù hợp là một **subtitle source broker** có adapter OpenSubtitles/SubDL tùy chọn, lưu cache cục bộ, yêu cầu người dùng bật và không tải audio/video lên dịch vụ tìm kiếm.

### Các hướng giảm độ trễ TTS

- Giữ scheduler hiện tại: dịch từng cue, gộp request trùng, nạp trước ngắn, hủy thế hệ cũ khi tua/pause/đổi video.
- Nếu cần mức “đọc đồng thời” tuyệt đối, chuyển từ MP3 tạo xong rồi mới phát sang TTS streaming. Microsoft Speech hỗ trợ REST và luồng WebSocket/SDK; đổi lại cần credential, kết nối ổn định và bộ đệm phát. [Microsoft Speech REST TTS](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/rest-text-to-speech), [Speech synthesis latency](https://learn.microsoft.com/th-th/azure/ai-services/speech-service/how-to-lower-speech-synthesis-latency).
- Với Edge TTS hiện tại, độ trễ lạnh khoảng 0.8 giây là giới hạn đường mạng + tạo file; các cue warm đã chứng minh scheduler không còn tạo thêm độ lệch 1–3 giây.

## Offline Dub đã triển khai

Nút waveform hiện bật Offline Dub trực tiếp; đường Live Dub đã được loại khỏi giao diện và không còn bật mặc định:

1. Native yêu cầu WebView gửi toàn bộ timeline cue đã biết.
2. Từng cue được dịch và tổng hợp trước bằng cache dịch/TTS hiện có.
3. `OfflineDubSession` giữ các file audio và dùng `AVAudioPlayer.play(atTime:)` để đặt chúng theo đồng hồ video.
4. Khi pause hoặc seek, các player audio cũ bị dừng và lịch mới được dựng từ vị trí hiện tại.

Đây là sidecar audio nên chưa encode lại video; video vẫn giữ nguyên chất lượng và người dùng có thể tắt/mở lại Live Dub. Bước tiếp theo nếu cần file xuất là thêm exporter mux audio sidecar vào MP4 sau khi render hoàn tất.

### Sửa theo phản hồi giao diện

- Khi bật Offline Dub, video bị pause ngay lập tức; HUD hiển thị số cue đã dựng trên tổng số cue (`done/total`). Video chỉ chạy lại khi người dùng bấm Play sau khi chuẩn bị xong.
- Nút waveform và menu `…` đều bật Offline Dub, không phụ thuộc vào ⌥-click.
- Lớp che banner được re-assert trong 0/250/750/1500 ms, có fallback DOM nếu script blur chưa kịp cài, và thêm compositing `translateZ(1px)` để tránh bị lớp video GPU vẽ đè. Điều này áp dụng cho cả blur thủ công và detector banner tự động.
- Preset kích thước đã tăng lên khoảng **Nhỏ 480 px**, **Vừa 720 px**, **Rộng 1100 px**. Menu `…` có thêm **Toàn màn hình**, lấp đầy vùng hiển thị hiện tại nhưng vẫn giữ cửa sổ nổi và không giành focus khỏi trình soạn thảo.
