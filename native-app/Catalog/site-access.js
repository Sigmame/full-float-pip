// Only movie providers may be inspected. Match host boundaries, never URL substrings.
(function (root) {
    const movieDomains = Object.freeze(["phimapi.com", "ophim1.com", "nguonc.com", "streamc.xyz", "kkphimplayer.com", "kkphimplayer6.com", "kkphim.com", "ophim.com"]);
    // Curated movie videos only; this never grants access to YouTube browsing tabs.
    // Reviewed live-action films from publisher channels. AI dubbing is allowed.
    // See docs/youtube-movies.md for identity checks and exclusion policy.
    const youtubeMovies = Object.freeze([
        Object.freeze({"id": "4bjvj11fdV4", "name": "Phá chiến", "original_name": "Broken Mission / 破战", "year": 2024, "cast": "Ngô Trấn Vũ, Nhậm Đạt Hoa", "audio": "Thuyết minh Việt", "hongKongCast": true, "region": "Hồng Kông", "genre": "Hành động · Tội phạm", "channel": "YOUKU Phim Thuyết Minh", "channelId": "UCS8ZiSe7Mc7yQ0eltBs8cbg", "durationMinutes": 86, "reviewedOn": "2026-09-30"}),
        Object.freeze({"id": "VcVNNDxbMGM", "name": "12 giờ thịnh nộ", "original_name": "Fury 12 Hours / 怒火十二小时", "year": 2024, "cast": "An Chí Kiệt", "audio": "Thuyết minh Việt", "hongKongCast": true, "region": "Trung Quốc", "genre": "Hành động · Sinh tồn", "channel": "YOUKU Phim Thuyết Minh", "channelId": "UCS8ZiSe7Mc7yQ0eltBs8cbg", "durationMinutes": 83, "reviewedOn": "2026-09-30"}),
        Object.freeze({"id": "dk540-a-h-I", "name": "To Live Through Death — Quyết chiến sinh tử", "original_name": "殊死一搏", "year": 2024, "cast": "Phàn Thiếu Hoàng, An Chí Kiệt", "audio": "Phụ đề đa ngôn ngữ", "hongKongCast": true, "region": "Trung Quốc", "genre": "Hành động · Tội phạm", "channel": "iQIYI Movie Theater", "channelId": "UCZ8ZJNzzIiDQFuGxdGTyWcQ", "durationMinutes": 92, "reviewedOn": "2026-09-30"}),
        Object.freeze({"id": "_WcFyejYtZM", "name": "Second Life — Tái sinh", "original_name": "重见天日", "year": 2024, "cast": "Nguyên Thu, Ngũ Doãn Long", "audio": "Phụ đề đa ngôn ngữ", "hongKongCast": true, "region": "Trung Quốc", "genre": "Võ thuật · Hài", "channel": "Tencent / WeTV Movie", "channelId": "UCHKhnI50cb_qLV85Xwzgy4w", "durationMinutes": 106, "reviewedOn": "2026-09-30"}),
        Object.freeze({"id": "iZbKjlIU6Fo", "name": "Truy lùng tội ác", "original_name": "Hunt the Wicked / 缉恶", "year": 2024, "cast": "Tạ Miêu, An Chí Kiệt", "audio": "Phụ đề đa ngôn ngữ", "hongKongCast": true, "region": "Trung Quốc", "genre": "Hành động · Tội phạm", "channel": "iQIYI Movie Theater", "channelId": "UCZ8ZJNzzIiDQFuGxdGTyWcQ", "durationMinutes": 103, "reviewedOn": "2026-09-30"}),
        Object.freeze({"id": "Z40GTe-gsNo", "name": "Mục trung vô nhân 2", "original_name": "Eye for an Eye 2 / 目中无人2", "year": 2024, "cast": "Tạ Miêu, Dương Ân Hựu", "audio": "Thuyết minh Việt", "hongKongCast": false, "region": "Trung Quốc", "genre": "Võ hiệp · Hành động", "channel": "iQIYI Movie Vietnam", "channelId": "UCWOuIqENJv8lfIdgYixTU0A", "durationMinutes": 90, "reviewedOn": "2026-09-30"}),
        Object.freeze({"id": "XwDI36fOAXQ", "name": "Bão đen", "original_name": "Black Storm / 打黑", "year": 2024, "cast": "Thích Tiểu Long, Bao Bối Nhĩ", "audio": "Thuyết minh Việt", "hongKongCast": false, "region": "Trung Quốc", "genre": "Hành động · Tội phạm", "channel": "YOUKU Phim Thuyết Minh", "channelId": "UCS8ZiSe7Mc7yQ0eltBs8cbg", "durationMinutes": 98, "reviewedOn": "2026-09-30"}),
        Object.freeze({"id": "YMVvVM4eGEY", "name": "Câu chuyện cảnh sát Đông Bắc 2", "original_name": "Fight Against Evil 2 / 东北警察故事2", "year": 2023, "cast": "Tạ Miêu, Trương Hạo Sâm", "audio": "Thuyết minh Việt", "hongKongCast": false, "region": "Trung Quốc", "genre": "Hành động · Cảnh sát", "channel": "iQIYI Movie Vietnam", "channelId": "UCWOuIqENJv8lfIdgYixTU0A", "durationMinutes": 90, "reviewedOn": "2026-09-30"}),
        Object.freeze({"id": "-fi7M_sA7l8", "name": "The Mob — Long hổ tranh bá", "original_name": "龙虎制霸", "year": 2023, "cast": "Từ Phương Châu, Trương Quân Nhiên", "audio": "Phụ đề đa ngôn ngữ", "hongKongCast": false, "region": "Trung Quốc", "genre": "Hành động · Băng đảng", "channel": "iQIYI English", "channelId": "UCZrZaZM9IfX-uB-9yWf5gfQ", "durationMinutes": 103, "reviewedOn": "2026-09-30"}),
        Object.freeze({"id": "4uh1SexAXPU", "name": "Firestorm — Phong bạo lừa đảo", "original_name": "断卡风暴", "year": 2023, "cast": "Thích Ngạn Năng, Trần Nhiên", "audio": "Phụ đề đa ngôn ngữ", "hongKongCast": false, "region": "Trung Quốc", "genre": "Hành động · Tội phạm", "channel": "iQIYI Movie Theater", "channelId": "UCZ8ZJNzzIiDQFuGxdGTyWcQ", "durationMinutes": 80, "reviewedOn": "2026-09-30"}),
        Object.freeze({"id": "wwqcuiyeckk", "name": "Chiến binh mù", "original_name": "Blind War / 盲战", "year": 2022, "cast": "An Chí Kiệt, Dương Hạnh", "audio": "Phụ đề Anh", "hongKongCast": true, "region": "Trung Quốc", "genre": "Hành động · Cảnh sát", "channel": "iQIYI Action Movie", "channelId": "UCwy7vUQNbyuj8E3_A7VQiEw", "durationMinutes": 103, "reviewedOn": "2026-09-30"}),
        Object.freeze({"id": "rnikYJGo3j4", "name": "Mục trung vô nhân", "original_name": "Eye for an Eye / 目中无人", "year": 2022, "cast": "Tạ Miêu, Cao Duy Mạn", "audio": "Phụ đề đa ngôn ngữ", "hongKongCast": false, "region": "Trung Quốc", "genre": "Võ hiệp · Hành động", "channel": "iQIYI English", "channelId": "UCZrZaZM9IfX-uB-9yWf5gfQ", "durationMinutes": 74, "reviewedOn": "2026-09-30"}),
        Object.freeze({"id": "SMZulU8vVdg", "name": "Trương Tam Phong", "original_name": "The TaiChi Master / 张三丰", "year": 2022, "cast": "Ngô Việt, Liễu Nham", "audio": "Phụ đề đa ngôn ngữ", "hongKongCast": false, "region": "Trung Quốc", "genre": "Võ hiệp · Kỳ ảo", "channel": "iQIYI Movie Theater", "channelId": "UCZ8ZJNzzIiDQFuGxdGTyWcQ", "durationMinutes": 91, "reviewedOn": "2026-09-30"}),
        Object.freeze({"id": "bE0-VBWutqY", "name": "Nhà trọ Tây hành", "original_name": "Westbound Inn / 西行客栈", "year": 2022, "cast": "Nhậm Vũ, Trương Tinh Dao", "audio": "Thuyết minh Việt", "hongKongCast": false, "region": "Trung Quốc", "genre": "Võ hiệp · Hành động", "channel": "iQIYI Movie Vietnam", "channelId": "UCWOuIqENJv8lfIdgYixTU0A", "durationMinutes": 85, "reviewedOn": "2026-09-30"}),
        Object.freeze({"id": "6_UuGLoAnnU", "name": "Câu chuyện cảnh sát Đông Bắc", "original_name": "Fight Against Evil / 东北警察故事", "year": 2021, "cast": "Tạ Miêu, Lý Đại Cường", "audio": "Phụ đề Anh", "hongKongCast": false, "region": "Trung Quốc", "genre": "Hành động · Cảnh sát", "channel": "iQIYI Action Movie", "channelId": "UCwy7vUQNbyuj8E3_A7VQiEw", "durationMinutes": 83, "reviewedOn": "2026-09-30"})
    ]);
    function youtubeMovieID(raw) {
        try {
            const url = new URL(raw);
            if (url.protocol !== 'https:' || url.username || url.password || url.port) return '';
            let id = '';
            if (['www.youtube.com', 'youtube.com'].includes(url.hostname) && url.pathname === '/watch') {
                id = url.searchParams.get('v');
            } else if (['www.youtube.com', 'www.youtube-nocookie.com'].includes(url.hostname)) {
                id = url.pathname.match(/^\/embed\/([a-zA-Z0-9_-]{11})$/)?.[1];
            }
            return youtubeMovies.some(movie => movie.id === id) ? id : '';
        } catch { return ''; }
    }
    function allowsPlayback(raw) { return allowsPage(raw) || Boolean(youtubeMovieID(raw)); }
    function allowsPage(raw) {
        try {
            const url = new URL(raw);
            return url.protocol === 'https:' && !url.username && !url.password &&
                movieDomains.some(domain => url.hostname === domain || url.hostname.endsWith('.' + domain));
        } catch { return false; }
    }
    root.VibeSiteAccess = Object.freeze({ movieDomains, youtubeMovies, youtubeMovieID, allowsPage, allowsPlayback });
    if (typeof module === 'object' && module.exports) module.exports = root.VibeSiteAccess;
})(globalThis);
