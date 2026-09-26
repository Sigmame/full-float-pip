// movie-service.js — Unified API for KKPhim (phimapi.com) and NguonC (phim.nguonc.com)
// High-frequency fresh updates (2025-2026 prioritized, eliminates stale 2014-2019 titles).
// Supports Cinema, Thuyết Minh, Lồng Tiếng, Home Sections, and Instant Live Search.

const MovieImages = {
    fallback: "data:image/svg+xml," + encodeURIComponent("<svg xmlns='http://www.w3.org/2000/svg' width='80' height='112' viewBox='0 0 80 112'><rect width='80' height='112' fill='#1c1c24'/><circle cx='40' cy='46' r='14' fill='#2a2a36'/><polygon points='36,40 48,46 36,52' fill='#d4d4dc'/></svg>"),

    install(root = document) {
        if (!root || root.__ffPosterGuard) return;
        root.__ffPosterGuard = true;
        root.addEventListener('error', (event) => {
            const img = event.target;
            if (!img || img.tagName !== 'IMG') return;
            const alt = img.dataset.altSrc;
            if (alt && img.dataset.altTried !== '1' && img.src !== alt) {
                img.dataset.altTried = '1';
                img.src = alt;
                return;
            }
            if (img.dataset.final !== '1') {
                img.dataset.final = '1';
                img.removeAttribute('srcset');
                img.src = this.fallback;
            }
        }, true);
    },

    isCompactSafe(url) {
        if (!url) return false;
        if (/ex-cdn|danviet|vnexpress|thanhnien|tuoitre|kenh14|fbcdn|googleusercontent/i.test(url)) return false;
        if (/\.webp(\?|$)/i.test(url)) return true;
        if (/phimimg\.com|nguonc\.com|image\.tmdb\.org|i\.ytimg\.com|wikimedia\.org/i.test(url)) return true;
        return /thumb|w185|w300|w500|small/i.test(url);
    },

    pick(item, kind = 'thumb') {
        const poster = (item && (item.poster || item.poster_url)) || '';
        const thumb = (item && (item.thumb || item.thumb_url)) || '';
        const compact = kind !== 'hero' && kind !== 'backdrop';
        let src = '';
        let alt = '';
        if (kind === 'poster') {
            if (this.isCompactSafe(poster)) src = poster;
            else if (this.isCompactSafe(thumb)) src = thumb;
            else src = thumb || poster;
            alt = src === poster ? thumb : poster;
        } else if (compact) {
            if (this.isCompactSafe(thumb)) src = thumb;
            else if (this.isCompactSafe(poster)) src = poster;
            else src = thumb || poster;
            alt = src === thumb ? poster : thumb;
        } else {
            src = poster || thumb;
            alt = src === poster ? thumb : poster;
        }
        if (alt === src) alt = '';
        return { src: src || this.fallback, alt };
    },

    attr(item, kind) {
        const picked = this.pick(item, kind);
        const alt = picked.alt ? ` data-alt-src="${this.esc(picked.alt)}"` : '';
        return `src="${this.esc(picked.src)}"${alt} referrerpolicy="no-referrer" decoding="async"`;
    },

    apply(img, item, kind) {
        if (!img) return;
        const picked = this.pick(item, kind);
        img.referrerPolicy = 'no-referrer';
        img.decoding = 'async';
        delete img.dataset.altTried;
        delete img.dataset.final;
        if (picked.alt) img.dataset.altSrc = picked.alt;
        else img.removeAttribute('data-alt-src');
        img.src = picked.src;
    },

    applyBackground(el, item, kind = 'hero') {
        if (!el) return;
        const picked = this.pick(item, kind);
        const paint = (url) => { el.style.backgroundImage = `url("${String(url).replace(/"/g, '')}")`; };
        const probe = new Image();
        probe.referrerPolicy = 'no-referrer';
        probe.onload = () => paint(picked.src);
        probe.onerror = () => {
            if (!picked.alt) return;
            const second = new Image();
            second.referrerPolicy = 'no-referrer';
            second.onload = () => paint(picked.alt);
            second.src = picked.alt;
        };
        probe.src = picked.src;
    },

    esc(value) {
        return String(value || '').replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;');
    }
};

const MovieService = {
    currentSource: 'kkphim',

    // Available sources configuration
    SOURCES: [
        { id: 'kkphim', name: 'KKPhim (HLS FHD)', badge: 'VIP' },
        { id: 'nguonc', name: 'NguonC (Cập nhật liên tục)', badge: 'Đang Chiếu' },
        { id: 'all', name: 'Tổng Hợp Đa Nguồn (Khuyên Dùng)', badge: 'Đầy Đủ' }
    ],

    // Available categories
    CATEGORIES: [
        { id: 'moi', name: 'Trang chủ' },
        { id: 'chieurap', name: 'Chiếu rạp' },
        { id: 'bo', name: 'Phim bộ' },
        { id: 'le', name: 'Phim lẻ' },
        { id: 'thuyetminh', name: 'Thuyết minh' },
        { id: 'longtieng', name: 'Lồng tiếng' },
        { id: 'hoathinh', name: 'Anime' },
        { id: 'tvshows', name: 'TV Shows' },
        { id: 'livetv', name: 'Truyền hình' }
    ],

    // Available genres
    GENRES: [
        { id: 'hanh-dong', name: 'Hành động' },
        { id: 'tinh-cam', name: 'Tình cảm' },
        { id: 'co-trang', name: 'Cổ trang' },
        { id: 'kinh-di', name: 'Kinh dị' },
        { id: 'hai-huoc', name: 'Hài hước' },
        { id: 'vien-tuong', name: 'Viễn tưởng' },
        { id: 'tam-ly', name: 'Tâm lý' },
        { id: 'vo-thuat', name: 'Võ thuật' },
        { id: 'hinh-su', name: 'Hình sự' },
        { id: 'phieu-luu', name: 'Phiêu lưu' }
    ],

    // Available countries
    COUNTRIES: [
        { id: 'han-quoc', name: 'Hàn Quốc' },
        { id: 'trung-quoc', name: 'Trung Quốc' },
        { id: 'au-my', name: 'Âu Mỹ' },
        { id: 'viet-nam', name: 'Việt Nam' },
        { id: 'nhat-ban', name: 'Nhật Bản' },
        { id: 'thai-lan', name: 'Thái Lan' }
    ],

    /**
     * Curated Live TV & Vibecoding Music Streams
     */
    getLiveTVChannels() {
        return [
            {
                slug: 'livetv-anninh',
                name: 'ANTV HD — Truyền Hình Công An Nhân Dân',
                origin_name: 'Tin tức, thời sự & phóng sự điều tra 24/7',
                year: 'Live',
                thumb: 'https://upload.wikimedia.org/wikipedia/vi/thumb/9/9f/ANTV_logo_2016.svg/1200px-ANTV_logo_2016.svg.png',
                poster: 'https://upload.wikimedia.org/wikipedia/vi/thumb/9/9f/ANTV_logo_2016.svg/1200px-ANTV_logo_2016.svg.png',
                quality: '1080p FHD',
                lang: 'Trực Tiếp',
                source: 'livetv',
                streamUrl: 'https://liveh12.vtvprime.vn/hls/ANNINHTV/index.m3u8'
            },
            {
                slug: 'livetv-qpvn',
                name: 'QPVN HD — Quốc Phòng Việt Nam',
                origin_name: 'Tin tức chính luận, thời sự quân đội',
                year: 'Live',
                thumb: 'https://upload.wikimedia.org/wikipedia/vi/thumb/e/e4/QPVN_2019.svg/1200px-QPVN_2019.svg.png',
                poster: 'https://upload.wikimedia.org/wikipedia/vi/thumb/e/e4/QPVN_2019.svg/1200px-QPVN_2019.svg.png',
                quality: '1080p FHD',
                lang: 'Trực Tiếp',
                source: 'livetv',
                streamUrl: 'https://liveh12.vtvprime.vn/hls/QPTV/index.m3u8'
            },
            {
                slug: 'livetv-hanoi1',
                name: 'Hà Nội 1 TV HD — Thời Sự & Đời Sống Thủ Đô',
                origin_name: 'Đài Phát Thanh & Truyền Hình Hà Nội',
                year: 'Live',
                thumb: 'https://upload.wikimedia.org/wikipedia/vi/thumb/c/c5/Hanoitv.png/800px-Hanoitv.png',
                poster: 'https://upload.wikimedia.org/wikipedia/vi/thumb/c/c5/Hanoitv.png/800px-Hanoitv.png',
                quality: '1080p FHD',
                lang: 'Trực Tiếp',
                source: 'livetv',
                streamUrl: 'https://liveh34.vtvprime.vn/hls/HANOI1TV/index.m3u8'
            },
            {
                slug: 'livetv-cantho',
                name: 'Cần Thơ TV 1 HD — Truyền Hình Miền Tây',
                origin_name: 'Văn hóa, tin tức đồng bằng sông Cửu Long',
                year: 'Live',
                thumb: 'https://upload.wikimedia.org/wikipedia/vi/7/7b/Logo_THTPCT.png',
                poster: 'https://upload.wikimedia.org/wikipedia/vi/7/7b/Logo_THTPCT.png',
                quality: '1080p FHD',
                lang: 'Trực Tiếp',
                source: 'livetv',
                streamUrl: 'https://live.canthotv.vn/live/tv/chunklist.m3u8'
            },
            {
                slug: 'livetv-dongthap',
                name: 'Đồng Tháp TV 1 HD — Miền Đất Sen Hồng',
                origin_name: 'Tin tức, văn hóa & giải trí miền Tây',
                year: 'Live',
                thumb: 'https://upload.wikimedia.org/wikipedia/vi/e/eb/Logo_THDT.png',
                poster: 'https://upload.wikimedia.org/wikipedia/vi/e/eb/Logo_THDT.png',
                quality: '720p HD',
                lang: 'Trực Tiếp',
                source: 'livetv',
                streamUrl: 'https://liveh34.vtvprime.vn/hls/DONGTHAPTV/index.m3u8'
            },
            {
                slug: 'livetv-lofi',
                name: 'Lofi Girl — Beats to relax/study to 24/7',
                origin_name: 'Nhạc Chill Lofi Coding Không Lời 24/7',
                year: 'Live',
                thumb: 'https://i.ytimg.com/vi/jfKfPfyJRdk/maxresdefault.jpg',
                poster: 'https://i.ytimg.com/vi/jfKfPfyJRdk/maxresdefault.jpg',
                quality: 'Live Stream',
                lang: 'Lofi Music',
                source: 'livetv',
                youtubeId: 'jfKfPfyJRdk',
                streamUrl: 'https://www.youtube.com/watch?v=jfKfPfyJRdk'
            },
            {
                slug: 'livetv-synthwave',
                name: 'Synthwave Radio — Chill Synth & Cyberpunk',
                origin_name: 'Nhạc Coding Đêm Khuya Phong Cách Retro Sci-Fi',
                year: 'Live',
                thumb: 'https://i.ytimg.com/vi/4xDzrJKXOOY/maxresdefault.jpg',
                poster: 'https://i.ytimg.com/vi/4xDzrJKXOOY/maxresdefault.jpg',
                quality: 'Live Stream',
                lang: 'Synthwave',
                source: 'livetv',
                youtubeId: '4xDzrJKXOOY',
                streamUrl: 'https://www.youtube.com/watch?v=4xDzrJKXOOY'
            }
        ];
    },

    getLiveTVDetail(slug) {
        const ch = this.getLiveTVChannels().find(c => c.slug === slug) || this.getLiveTVChannels()[0];
        return {
            name: ch.name,
            origin_name: ch.origin_name,
            description: 'Kênh truyền hình & luồng phát trực tiếp 24/7 chất lượng Full HD phục vụ xem thời sự, tin tức hoặc nghe nhạc khi vibecoding.',
            poster: ch.poster,
            thumb: ch.thumb,
            year: 'Live',
            time: '24/7',
            episode_current: 'Đang phát sóng',
            episodes: [{
                serverName: 'Live HD Server',
                items: [{
                    name: 'Xem Trực Tiếp',
                    slug: ch.slug,
                    linkM3u8: ch.streamUrl.includes('.m3u8') ? ch.streamUrl : '',
                    linkEmbed: ch.youtubeId ? `https://www.youtube.com/embed/${ch.youtubeId}?autoplay=1` : '',
                    pageUrl: ch.streamUrl,
                    source: 'livetv'
                }]
            }],
            source: 'livetv'
        };
    },

    /** Curated YouTube lives for vibe-coding (float via site: youtube, not movie embed). */
    getLofiCodingStreams() {
        return this.getLiveTVChannels().filter(c => c.youtubeId && c.streamUrl);
    },

    getDefaultLofiStream() {
        const streams = this.getLofiCodingStreams();
        return streams.find(c => c.slug === 'livetv-lofi') || streams[0] || null;
    },

    extractYouTubeId(url) {
        const s = String(url || '');
        const m = s.match(/[?&]v=([a-zA-Z0-9_-]{11})/)
            || s.match(/youtu\.be\/([a-zA-Z0-9_-]{11})/)
            || s.match(/embed\/([a-zA-Z0-9_-]{11})/)
            || s.match(/shorts\/([a-zA-Z0-9_-]{11})/);
        return m ? m[1] : '';
    },

    /** Payload for native YouTube embed (preferEmbed avoids WKWebView watch-page bot wall). */
    buildYouTubeLiveFloatInfo(stream, title) {
        const id = stream?.youtubeId || this.extractYouTubeId(stream?.streamUrl || stream?.pageUrl || '');
        const pageUrl = stream?.streamUrl || stream?.pageUrl || (id ? `https://www.youtube.com/watch?v=${id}` : '');
        return {
            pageUrl,
            embedUrl: id ? `https://www.youtube.com/embed/${id}?autoplay=1&rel=0` : '',
            title: title || stream?.name || 'Lofi coding',
            site: 'youtube',
            width: 1280,
            height: 720,
            currentTime: 0,
            preferEmbed: true
        };
    },

    /**
     * Map genre display name → phimapi slug (best-effort).
     */
    genreNameToSlug(name) {
        if (!name) return '';
        const n = String(name).toLowerCase().normalize('NFD').replace(/[\u0300-\u036f]/g, '').replace(/\s+/g, '-');
        const hit = this.GENRES.find(g => {
            const gn = g.name.toLowerCase().normalize('NFD').replace(/[\u0300-\u036f]/g, '');
            return gn === String(name).toLowerCase().normalize('NFD').replace(/[\u0300-\u036f]/g, '')
                || g.id === n
                || n.includes(g.id);
        });
        if (hit) return hit.id;
        // common aliases
        if (/hanh.?dong|action/i.test(n)) return 'hanh-dong';
        if (/tinh.?cam|romance/i.test(n)) return 'tinh-cam';
        if (/kinh.?di|horror/i.test(n)) return 'kinh-di';
        if (/hai|comedy/i.test(n)) return 'hai-huoc';
        if (/vien.?tuong|sci/i.test(n)) return 'vien-tuong';
        if (/phieu.?luu|adventure/i.test(n)) return 'phieu-luu';
        if (/vo.?thuat|martial/i.test(n)) return 'vo-thuat';
        if (/hinh.?su|crime/i.test(n)) return 'hinh-su';
        if (/tam.?ly|drama/i.test(n)) return 'tam-ly';
        if (/co.?trang/i.test(n)) return 'co-trang';
        return '';
    },

    /**
     * Top thịnh hành — no dedicated ranking API; sort latest + cinema by rating.
     */
    buildTopTrending(pools, limit = 10) {
        const merged = this._deduplicateList([].concat(...pools.filter(Boolean)));
        const scored = merged.map(it => ({
            ...it,
            _score: (Number(it.rating) || 0) * 10 + (it.isChieuRap ? 3 : 0) + (it.hasThuyetMinh || it.hasLongTieng ? 1 : 0)
        }));
        scored.sort((a, b) => b._score - a._score || String(b.year).localeCompare(String(a.year)));
        return scored.slice(0, limit).map((it, i) => {
            const { _score, ...rest } = it;
            return { ...rest, rank: i + 1 };
        });
    },

    /**
     * "Vì bạn đã xem" / Gợi ý tương tự from last continue genres, else same-year hot series.
     */
    async getBecauseYouWatched(limit = 12) {
        const continueList = await this.getContinueWatching();
        const last = continueList[0];
        if (!last) return { title: 'Gợi ý cho bạn', subtitle: 'Phim đang hot để bắt đầu', items: [], categoryKey: 'bo' };

        let genreSlug = last.genreSlug || '';
        let genreLabel = last.genreName || '';
        if (!genreSlug && Array.isArray(last.genres) && last.genres.length) {
            genreLabel = last.genres[0];
            genreSlug = this.genreNameToSlug(genreLabel);
        }

        let items = [];
        if (genreSlug) {
            try {
                items = await this.getByGenre(genreSlug, 1);
            } catch (e) { /* ignore */ }
        }
        if (!items.length) {
            items = await this._getKKPhimList('bo', 1);
            genreLabel = '';
        }

        // Exclude titles already in continue list
        const seen = new Set(continueList.map(c => c.slug));
        items = items.filter(it => !seen.has(it.slug)).slice(0, limit);

        const title = genreLabel
            ? `Vì bạn đã xem · ${genreLabel}`
            : `Gợi ý tương tự · ${last.name || 'Phim gần đây'}`;

        return {
            title,
            subtitle: 'Dựa trên lịch sử xem gần nhất',
            items,
            categoryKey: genreSlug || 'bo',
            genreSlug
        };
    },

    /**
     * Get home sections for VibeWatch Cinema dashboard experience
     */
    async getHomeSections(source = 'kkphim') {
        const results = await Promise.allSettled([
            this._getKKPhimList('chieurap', 1),
            this._getNguonCList('dangchieu', 1),
            this._getKKPhimList('bo', 1),
            this._getKKPhimList('thuyetminh', 1),
            this._getKKPhimList('longtieng', 1),
            this._getKKPhimList('le', 1),
            this._getKKPhimList('hoathinh', 1),
            this.getFavorites(),
            this.getBecauseYouWatched(12)
        ]);

        const chieuRapRaw = results[0].status === 'fulfilled' ? results[0].value : [];
        const dangChieuRaw = results[1].status === 'fulfilled' ? results[1].value : [];
        const phimBoRaw = results[2].status === 'fulfilled' ? results[2].value : [];
        const thuyetMinhRaw = results[3].status === 'fulfilled' ? results[3].value : [];
        const longTiengRaw = results[4].status === 'fulfilled' ? results[4].value : [];
        const phimLeRaw = results[5].status === 'fulfilled' ? results[5].value : [];
        const animeRaw = results[6].status === 'fulfilled' ? results[6].value : [];
        const favorites = results[7].status === 'fulfilled' ? results[7].value : [];
        const because = results[8].status === 'fulfilled' ? results[8].value : { items: [] };

        // Billboard: 2–3 cinema titles with detail (parallel)
        const spotlightCandidates = chieuRapRaw
            .filter(m => m.thumb || m.poster)
            .slice(0, 3);
        const spotlightDetails = await Promise.allSettled(
            spotlightCandidates.map(m => this.getDetail(m.slug, m.source || 'kkphim'))
        );
        const spotlights = spotlightCandidates.map((m, i) => {
            const d = spotlightDetails[i];
            return d.status === 'fulfilled' ? { ...m, ...d.value } : m;
        });
        const spotlight = spotlights[0] || null;

        const topTrending = this.buildTopTrending([chieuRapRaw, phimBoRaw, phimLeRaw, dangChieuRaw], 10);
        const phimBoCombined = this._mergeAndDeduplicate(dangChieuRaw, phimBoRaw);

        const sections = [];

        if (favorites.length) {
            sections.push({
                id: 'mylist',
                title: 'Danh sách của tôi',
                subtitle: 'Phim đã lưu để xem sau',
                items: favorites.slice(0, 12),
                categoryKey: 'favorites'
            });
        }

        if (topTrending.length) {
            sections.push({
                id: 'top10',
                title: 'Top 10 thịnh hành',
                subtitle: 'Xếp theo điểm đánh giá & độ nóng',
                items: topTrending,
                categoryKey: 'chieurap',
                isTop10: true
            });
        }

        if (because?.items?.length) {
            sections.push({
                id: 'because',
                title: because.title,
                subtitle: because.subtitle,
                items: because.items,
                categoryKey: because.categoryKey || 'bo',
                genreSlug: because.genreSlug || ''
            });
        }

        sections.push(
            {
                id: 'chieurap',
                title: 'Chiếu rạp',
                subtitle: 'Bom tấn rạp mới nhất',
                items: chieuRapRaw.slice(0, 12),
                categoryKey: 'chieurap'
            },
            {
                id: 'thuyetminh',
                title: 'Thuyết minh',
                subtitle: 'Bản tiếng Việt chuẩn phòng thu',
                items: thuyetMinhRaw.slice(0, 12),
                categoryKey: 'thuyetminh'
            },
            {
                id: 'phimbo',
                title: 'Phim bộ hot',
                subtitle: 'Tập mới cập nhật liên tục',
                items: phimBoCombined.slice(0, 12),
                categoryKey: 'bo'
            },
            {
                id: 'longtieng',
                title: 'Lồng tiếng',
                subtitle: 'LT chọn lọc cho vibe coding',
                items: longTiengRaw.slice(0, 12),
                categoryKey: 'longtieng'
            },
            {
                id: 'anime',
                title: 'Anime',
                subtitle: 'Hoạt hình Nhật Bản & 3D hot',
                items: animeRaw.slice(0, 12),
                categoryKey: 'hoathinh'
            },
            {
                id: 'phimle',
                title: 'Phim lẻ',
                subtitle: 'Điện ảnh thế giới chọn lọc',
                items: phimLeRaw.slice(0, 12),
                categoryKey: 'le'
            }
        );

        return {
            spotlight,
            spotlights,
            sections: sections.filter(s => s.items && s.items.length > 0)
        };
    },

    /**
     * Get latest movies with pagination and category support
     */
    async getLatest(source = 'kkphim', category = 'moi', page = 1) {
        if (category === 'livetv') {
            return this.getLiveTVChannels();
        }
        if (source === 'all') {
            const [kkResult, ncResult] = await Promise.allSettled([
                this._getKKPhimList(category, page),
                this._getNguonCList(category, page)
            ]);
            const kkItems = kkResult.status === 'fulfilled' ? kkResult.value : [];
            const ncItems = ncResult.status === 'fulfilled' ? ncResult.value : [];
            return this._mergeAndDeduplicate(kkItems, ncItems);
        } else if (source === 'nguonc') {
            return this._getNguonCList(category, page);
        } else {
            return this._getKKPhimList(category, page);
        }
    },

    /**
     * Instant Live Search / Autocomplete suggestions for header dropdown
     */
    async quickSuggest(keyword, source = 'all', limit = 6) {
        if (!keyword || keyword.trim().length < 2) return [];
        try {
            const items = await this.search(keyword.trim(), source, 'all');
            return items.slice(0, limit);
        } catch (e) {
            console.warn('[MovieService] quickSuggest error:', e);
            return [];
        }
    },

    /**
     * Search movies across sources and optional audio filters
     */
    async search(keyword, source = 'all', audioFilter = 'all') {
        if (!keyword || !keyword.trim()) return [];
        const cleanKw = keyword.trim();

        let items = [];
        if (source === 'all') {
            const [kkResult, ncResult] = await Promise.allSettled([
                this._searchKKPhim(cleanKw),
                this._searchNguonC(cleanKw)
            ]);
            const kkItems = kkResult.status === 'fulfilled' ? kkResult.value : [];
            const ncItems = ncResult.status === 'fulfilled' ? ncResult.value : [];
            items = this._mergeAndDeduplicate(kkItems, ncItems);
        } else if (source === 'nguonc') {
            items = await this._searchNguonC(cleanKw);
        } else {
            items = await this._searchKKPhim(cleanKw);
        }

        // Apply audio filter if specified
        if (audioFilter === 'thuyetminh') {
            items = items.filter(it => it.hasThuyetMinh);
        } else if (audioFilter === 'longtieng') {
            items = items.filter(it => it.hasLongTieng);
        } else if (audioFilter === 'chieurap') {
            items = items.filter(it => it.isChieuRap);
        }

        return items;
    },

    /**
     * Get detail of a movie from specific source
     */
    async getDetail(slug, source = 'kkphim') {
        if (source === 'livetv' || (slug && slug.startsWith('livetv-'))) {
            return this.getLiveTVDetail(slug);
        }
        if (source === 'nguonc') {
            return this._getNguonCDetail(slug);
        } else {
            return this._getKKPhimDetail(slug);
        }
    },

    /**
     * Get movies by genre slug
     */
    async getByGenre(genreSlug, page = 1) {
        try {
            const url = `https://phimapi.com/v1/api/the-loai/${encodeURIComponent(genreSlug)}?page=${page}`;
            const res = await fetch(url);
            const data = await res.json();
            const items = data?.data?.items || [];
            return items.map(item => this._normalizeKKPhimItem(item));
        } catch (e) {
            console.warn('[MovieService] getByGenre error:', e);
            return [];
        }
    },

    /**
     * Get movies by country slug
     */
    async getByCountry(countrySlug, page = 1) {
        try {
            const url = `https://phimapi.com/v1/api/quoc-gia/${encodeURIComponent(countrySlug)}?page=${page}`;
            const res = await fetch(url);
            const data = await res.json();
            const items = data?.data?.items || [];
            return items.map(item => this._normalizeKKPhimItem(item));
        } catch (e) {
            console.warn('[MovieService] getByCountry error:', e);
            return [];
        }
    },

    /**
     * Get featured cinema / spotlight movie for Hero Banner
     */
    async getCinemaSpotlight() {
        try {
            const chieuRapItems = await this._getKKPhimList('chieurap', 1);
            if (chieuRapItems && chieuRapItems.length > 0) {
                // Find latest 2026/2025 movie with both poster and backdrop
                const top = chieuRapItems.find(it => it.poster && it.thumb) || chieuRapItems[0];
                const detail = await this.getDetail(top.slug, top.source || 'kkphim');
                return { ...top, ...detail };
            }
        } catch (e) {
            console.warn('[MovieService] Failed to load spotlight:', e);
        }
        return null;
    },

    // --- KKPhim Implementation ---
    async _getKKPhimList(category = 'moi', page = 1) {
        let items = [];

        try {
            if (category === 'moi') {
                // To avoid stale 2014-2019 movies on page 1, fetch fresh in-theater 2026 & new series 2026
                if (page === 1) {
                    const [crRes, boRes, leRes] = await Promise.allSettled([
                        fetch('https://phimapi.com/v1/api/danh-sach/phim-chieu-rap?page=1').then(r => r.json()),
                        fetch('https://phimapi.com/v1/api/danh-sach/phim-bo?year=2026&page=1').then(r => r.json()),
                        fetch('https://phimapi.com/v1/api/danh-sach/phim-le?year=2026&page=1').then(r => r.json())
                    ]);

                    const crItems = (crRes.status === 'fulfilled' && crRes.value?.data?.items) || [];
                    const boItems = (boRes.status === 'fulfilled' && boRes.value?.data?.items) || [];
                    const leItems = (leRes.status === 'fulfilled' && leRes.value?.data?.items) || [];

                    const merged = [...crItems, ...boItems, ...leItems];
                    const normalized = merged.map(it => this._normalizeKKPhimItem(it));
                    return this._sortNewestFirst(this._deduplicateList(normalized));
                } else {
                    const res = await fetch(`https://phimapi.com/danh-sach/phim-moi-cap-nhat?page=${page}`);
                    const data = await res.json();
                    items = data.items || data?.data?.items || [];
                }
            } else if (category === 'chieurap') {
                // In-theater movies (100% genuine blockbuster cinema releases)
                const res = await fetch(`https://phimapi.com/v1/api/danh-sach/phim-chieu-rap?page=${page}`);
                const data = await res.json();
                items = data?.data?.items || [];
            } else if (category === 'bo') {
                if (page === 1) {
                    const [res2026, resAll] = await Promise.allSettled([
                        fetch('https://phimapi.com/v1/api/danh-sach/phim-bo?year=2026&page=1').then(r => r.json()),
                        fetch('https://phimapi.com/v1/api/danh-sach/phim-bo?page=1').then(r => r.json())
                    ]);
                    const items2026 = (res2026.status === 'fulfilled' && res2026.value?.data?.items) || [];
                    const itemsAll = (resAll.status === 'fulfilled' && resAll.value?.data?.items) || [];
                    const combined = [...items2026, ...itemsAll];
                    const norm = combined.map(it => this._normalizeKKPhimItem(it));
                    return this._sortNewestFirst(this._deduplicateList(norm));
                } else {
                    const res = await fetch(`https://phimapi.com/v1/api/danh-sach/phim-bo?page=${page}`);
                    const data = await res.json();
                    items = data?.data?.items || [];
                }
            } else if (category === 'le') {
                if (page === 1) {
                    const [res2026, res2025] = await Promise.allSettled([
                        fetch('https://phimapi.com/v1/api/danh-sach/phim-le?year=2026&page=1').then(r => r.json()),
                        fetch('https://phimapi.com/v1/api/danh-sach/phim-le?year=2025&page=1').then(r => r.json())
                    ]);
                    const items2026 = (res2026.status === 'fulfilled' && res2026.value?.data?.items) || [];
                    const items2025 = (res2025.status === 'fulfilled' && res2025.value?.data?.items) || [];
                    const combined = [...items2026, ...items2025];
                    const norm = combined.map(it => this._normalizeKKPhimItem(it));
                    return this._sortNewestFirst(this._deduplicateList(norm));
                } else {
                    const res = await fetch(`https://phimapi.com/v1/api/danh-sach/phim-le?page=${page}`);
                    const data = await res.json();
                    items = data?.data?.items || [];
                }
            } else if (category === 'hoathinh') {
                if (page === 1) {
                    const res2026 = await fetch('https://phimapi.com/v1/api/danh-sach/hoat-hinh?year=2026&page=1');
                    const data2026 = await res2026.json();
                    const items2026 = data2026?.data?.items || [];
                    if (items2026.length > 0) {
                        return items2026.map(it => this._normalizeKKPhimItem(it));
                    }
                }
                const res = await fetch(`https://phimapi.com/v1/api/danh-sach/hoat-hinh?page=${page}`);
                const data = await res.json();
                items = data?.data?.items || [];
            } else if (category === 'thuyetminh') {
                const res = await fetch(`https://phimapi.com/v1/api/danh-sach/phim-thuyet-minh?page=${page}`);
                const data = await res.json();
                items = data?.data?.items || [];
            } else if (category === 'longtieng') {
                const res = await fetch(`https://phimapi.com/v1/api/danh-sach/phim-long-tieng?page=${page}`);
                const data = await res.json();
                items = data?.data?.items || [];
            } else if (category === 'tvshows') {
                const res = await fetch(`https://phimapi.com/v1/api/danh-sach/tv-shows?page=${page}`);
                const data = await res.json();
                items = data?.data?.items || [];
            }
        } catch (e) {
            console.warn('[MovieService] _getKKPhimList error:', e);
            return [];
        }

        const normalized = items.map(item => this._normalizeKKPhimItem(item));
        return this._sortNewestFirst(normalized);
    },

    async _searchKKPhim(keyword) {
        try {
            const url = `https://phimapi.com/v1/api/tim-kiem?keyword=${encodeURIComponent(keyword)}&limit=30`;
            const res = await fetch(url);
            const data = await res.json();
            const items = data?.data?.items || [];
            return items.map(item => this._normalizeKKPhimItem(item));
        } catch (e) {
            console.warn('[MovieService] _searchKKPhim error:', e);
            return [];
        }
    },

    _formatImageUrl(url, defaultHost = 'https://phimimg.com') {
        if (!url || typeof url !== 'string') return '';
        url = url.trim().replace(/\\\//g, '/');
        if (!url) return '';
        if (url.startsWith('http://') || url.startsWith('https://')) {
            return url;
        }
        const clean = url.replace(/^\/+/, '');
        if (clean.startsWith('upload/') || clean.startsWith('uploads/')) {
            return `${defaultHost}/${clean}`;
        }
        return `${defaultHost}/uploads/movies/${clean}`;
    },

    _normalizeKKPhimItem(item) {
        const thumb = this._formatImageUrl(item.thumb_url || item.poster_url);
        const poster = this._formatImageUrl(item.poster_url || item.thumb_url);

        const langStr = item.lang || '';
        const langKeys = Array.isArray(item.lang_key) ? item.lang_key : [];
        const name = item.name || '';
        const hasThuyetMinh = langKeys.includes('tm')
            || this.detectServerAudioType(langStr) === 'thuyetminh'
            || /thuyết\s*minh|thuyet\s*minh|(?:^|[^a-z0-9])tm(?:[^a-z0-9]|$)/i.test(langStr + ' ' + name);
        const hasLongTieng = langKeys.includes('lt')
            || /lồng\s*tiếng|long\s*tieng|(?:^|[^a-z0-9])lt(?:[^a-z0-9]|$)/i.test(langStr + ' ' + name)
            || (this.detectServerAudioType(langStr) === 'longtieng');
        const isChieuRap = !!item.chieurap;

        const rating = item.tmdb?.vote_average || item.imdb?.vote_average || null;

        return {
            id: item._id || item.slug,
            slug: item.slug,
            name: item.name,
            origin_name: item.origin_name || '',
            year: item.year || '',
            thumb: thumb,
            poster: poster,
            source: 'kkphim',
            quality: item.quality || 'FHD',
            lang: langStr || 'Vietsub',
            hasThuyetMinh: hasThuyetMinh,
            hasLongTieng: hasLongTieng,
            hasVietsub: /vietsub/i.test(langStr) || (!hasThuyetMinh && !hasLongTieng),
            isChieuRap: isChieuRap,
            rating: rating ? Number(rating).toFixed(1) : null,
            time: item.time || '',
            episode_current: item.episode_current || ''
        };
    },

    async _getKKPhimDetail(slug) {
        const url = `https://phimapi.com/phim/${slug}`;
        const res = await fetch(url);
        const data = await res.json();
        const movie = data.movie || {};
        const rawEpisodes = data.episodes || [];

        const episodes = rawEpisodes.map((srv, sIdx) => {
            const sName = srv.server_name || `Server #${sIdx + 1}`;
            const sType = this.detectServerAudioType(sName);

            return {
                serverName: sName,
                serverType: sType,
                items: (srv.server_data || []).map(ep => ({
                    name: ep.name,
                    slug: ep.slug,
                    linkM3u8: ep.link_m3u8 || '',
                    linkEmbed: ep.link_embed || '',
                    source: 'kkphim',
                    serverType: sType
                }))
            };
        });

        const poster = this._formatImageUrl(movie.poster_url || movie.thumb_url);
        const thumb = this._formatImageUrl(movie.thumb_url || movie.poster_url);

        const langStr = movie.lang || '';
        const hasThuyetMinh = /thuyết\s*minh|thuyet\s*minh|(?:^|[^a-z0-9])tm(?:[^a-z0-9]|$)/i.test(langStr)
            || episodes.some(s => s.serverType === 'thuyetminh');
        const hasLongTieng = /lồng\s*tiếng|long\s*tieng|(?:^|[^a-z0-9])lt(?:[^a-z0-9]|$)/i.test(langStr)
            || episodes.some(s => s.serverType === 'longtieng');

        return {
            id: movie._id || movie.slug,
            slug: movie.slug,
            name: movie.name,
            origin_name: movie.origin_name || '',
            description: movie.content ? movie.content.replace(/<[^>]*>?/gm, '').trim() : '',
            poster: poster,
            thumb: thumb,
            year: movie.year || '',
            time: movie.time || '',
            quality: movie.quality || 'FHD',
            lang: langStr || 'Vietsub',
            hasThuyetMinh: hasThuyetMinh,
            hasLongTieng: hasLongTieng,
            isChieuRap: !!movie.chieurap,
            rating: (movie.tmdb?.vote_average || movie.imdb?.vote_average) ? Number(movie.tmdb?.vote_average || movie.imdb?.vote_average).toFixed(1) : null,
            episode_current: movie.episode_current || '',
            genres: (movie.category || []).map(c => c.name),
            genreSlugs: (movie.category || []).map(c => c.slug).filter(Boolean),
            countries: (movie.country || []).map(c => c.name),
            director: (movie.director || []).join(', '),
            casts: (movie.actor || []).join(', '),
            episodes: episodes,
            source: 'kkphim'
        };
    },

    // --- NguonC Implementation ---
    async _getNguonCList(category = 'moi', page = 1) {
        let url = `https://phim.nguonc.com/api/films/phim-moi-cap-nhat?page=${page}`;

        if (category === 'moi' || category === 'dangchieu') {
            // NguonC's 'dang-chieu' has the freshest on-air 2026 episodes updating hourly
            url = `https://phim.nguonc.com/api/films/danh-sach/dang-chieu?page=${page}`;
        } else if (category === 'chieurap') {
            url = `https://phim.nguonc.com/api/films/danh-sach/dang-chieu?page=${page}`;
        } else if (category === 'bo') {
            url = `https://phim.nguonc.com/api/films/danh-sach/phim-bo?page=${page}`;
        } else if (category === 'le') {
            url = `https://phim.nguonc.com/api/films/danh-sach/phim-le?page=${page}`;
        } else if (category === 'hoathinh') {
            url = `https://phim.nguonc.com/api/films/danh-sach/hoat-hinh?page=${page}`;
        } else if (category === 'tvshows') {
            url = `https://phim.nguonc.com/api/films/danh-sach/tv-shows?page=${page}`;
        }

        try {
            const res = await fetch(url);
            const data = await res.json();
            const items = data.items || [];
            let normalized = items.map(item => this._normalizeNguonCItem(item));

            if (category === 'thuyetminh') {
                normalized = normalized.filter(it => it.hasThuyetMinh);
            } else if (category === 'longtieng') {
                normalized = normalized.filter(it => it.hasLongTieng);
            }

            return this._sortNewestFirst(normalized);
        } catch (e) {
            console.warn('[MovieService] _getNguonCList error:', e);
            return [];
        }
    },

    async _searchNguonC(keyword) {
        try {
            const url = `https://phim.nguonc.com/api/films/search?keyword=${encodeURIComponent(keyword)}`;
            const res = await fetch(url);
            const data = await res.json();
            const items = data.items || [];
            return items.map(item => this._normalizeNguonCItem(item));
        } catch (e) {
            console.warn('[MovieService] _searchNguonC error:', e);
            return [];
        }
    },

    _normalizeNguonCItem(item) {
        const langStr = item.language || '';
        const name = item.name || '';
        const blob = `${langStr} ${name}`;
        const hasThuyetMinh = /thuyết\s*minh|thuyet\s*minh|(?:^|[^a-z0-9])tm(?:[^a-z0-9]|$)/i.test(blob);
        const hasLongTieng = /lồng\s*tiếng|long\s*tieng|(?:^|[^a-z0-9])lt(?:[^a-z0-9]|$)/i.test(blob)
            || this.detectServerAudioType(langStr) === 'longtieng';
        const thumb = this._formatImageUrl(item.thumb_url || item.poster_url, 'https://phim.nguonc.com');
        const poster = this._formatImageUrl(item.poster_url || item.thumb_url, 'https://phim.nguonc.com');

        return {
            id: item.id || item.slug,
            slug: item.slug,
            name: item.name,
            origin_name: item.original_name || '',
            year: item.year || '',
            thumb: thumb,
            poster: poster,
            source: 'nguonc',
            quality: item.quality || 'HD',
            lang: langStr || 'Vietsub',
            hasThuyetMinh: hasThuyetMinh,
            hasLongTieng: hasLongTieng,
            hasVietsub: /vietsub/i.test(langStr) || (!hasThuyetMinh && !hasLongTieng),
            isChieuRap: false,
            rating: null,
            time: item.time || '',
            episode_current: item.current_episode || ''
        };
    },

    async _getNguonCDetail(slug) {
        const url = `https://phim.nguonc.com/api/film/${slug}`;
        const res = await fetch(url);
        const data = await res.json();
        const movie = data.movie || {};
        const rawEpisodes = movie.episodes || [];

        const episodes = rawEpisodes.map((srv, sIdx) => {
            const sName = srv.server_name || `Server #${sIdx + 1}`;
            const sType = this.detectServerAudioType(sName);

            return {
                serverName: sName,
                serverType: sType,
                items: (srv.items || []).map(ep => ({
                    name: `Tập ${ep.name}`,
                    slug: ep.slug,
                    linkM3u8: ep.m3u8 || '',
                    linkEmbed: ep.embed || '',
                    source: 'nguonc',
                    serverType: sType
                }))
            };
        });

        const langStr = movie.language || '';
        const hasThuyetMinh = /thuyết\s*minh|thuyet\s*minh|(?:^|[^a-z0-9])tm(?:[^a-z0-9]|$)/i.test(langStr)
            || episodes.some(s => s.serverType === 'thuyetminh');
        const hasLongTieng = /lồng\s*tiếng|long\s*tieng|(?:^|[^a-z0-9])lt(?:[^a-z0-9]|$)/i.test(langStr)
            || episodes.some(s => s.serverType === 'longtieng');
        const poster = this._formatImageUrl(movie.poster_url || movie.thumb_url, 'https://phim.nguonc.com');
        const thumb = this._formatImageUrl(movie.thumb_url || movie.poster_url, 'https://phim.nguonc.com');

        return {
            id: movie.id || movie.slug,
            slug: movie.slug,
            name: movie.name,
            origin_name: movie.original_name || '',
            description: movie.description ? movie.description.replace(/<[^>]*>?/gm, '').trim() : '',
            poster: poster,
            thumb: thumb,
            year: movie.year || '',
            time: movie.time || '',
            quality: movie.quality || 'HD',
            lang: langStr || 'Vietsub',
            hasThuyetMinh: hasThuyetMinh,
            hasLongTieng: hasLongTieng,
            isChieuRap: false,
            rating: null,
            episode_current: movie.current_episode || '',
            genres: [],
            countries: [],
            director: movie.director || '',
            casts: movie.casts || '',
            episodes: episodes,
            source: 'nguonc'
        };
    },

    // --- Helpers ---
    _sortNewestFirst(list) {
        return list.sort((a, b) => {
            const yearA = parseInt(a.year) || 0;
            const yearB = parseInt(b.year) || 0;
            return yearB - yearA;
        });
    },

    _deduplicateList(list) {
        const map = new Map();
        list.forEach(item => {
            const key = this._normalizeTitleKey(item.name);
            if (!map.has(key)) {
                map.set(key, item);
            }
        });
        return Array.from(map.values());
    },

    _mergeAndDeduplicate(list1, list2) {
        const map = new Map();
        // Prefer KKPhim first (M3U8 direct)
        list1.forEach(item => {
            const key = this._normalizeTitleKey(item.name);
            map.set(key, item);
        });

        // Add NguonC items if not already present or merge flags
        list2.forEach(item => {
            const key = this._normalizeTitleKey(item.name);
            if (map.has(key)) {
                const existing = map.get(key);
                if (item.hasThuyetMinh) existing.hasThuyetMinh = true;
                if (item.hasLongTieng) existing.hasLongTieng = true;
                if (!existing.episode_current && item.episode_current) {
                    existing.episode_current = item.episode_current;
                }
            } else {
                map.set(key, item);
            }
        });

        return Array.from(map.values());
    },

    _normalizeTitleKey(title) {
        return (title || '')
            .toLowerCase()
            .replace(/[^\p{L}\p{N}]/gu, '')
            .trim();
    },

    // --- Storage / User History & Favorites ---
    async getContinueWatching() {
        return new Promise(resolve => {
            if (typeof chrome !== 'undefined' && chrome.storage?.local) {
                chrome.storage.local.get(['vibe_continue_watching'], (res) => {
                    resolve(res.vibe_continue_watching || []);
                });
            } else {
                const stored = localStorage.getItem('vibe_continue_watching');
                resolve(stored ? JSON.parse(stored) : []);
            }
        });
    },

    /**
     * Persist continue-watching entry. opts may include currentTime, duration, serverIdx, epIdx.
     * When resuming the same episode, pass existing currentTime so progress is not wiped.
     */
    async saveContinueWatching(movie, episode, opts = {}) {
        const list = await this.getContinueWatching();
        const prev = list.find(it => it.slug === movie.slug);
        const sameEp = prev && (
            (episode.slug && prev.epSlug === episode.slug) ||
            (episode.name && prev.epName === episode.name)
        );
        const entry = {
            slug: movie.slug,
            name: movie.name,
            origin_name: movie.origin_name || '',
            poster: movie.poster || movie.thumb || '',
            source: movie.source || 'kkphim',
            epName: episode.name,
            epSlug: episode.slug,
            linkM3u8: episode.linkM3u8 || '',
            linkEmbed: episode.linkEmbed || '',
            genres: Array.isArray(movie.genres) ? movie.genres.slice(0, 6) : (prev?.genres || []),
            genreName: (Array.isArray(movie.genres) && movie.genres[0]) || prev?.genreName || '',
            genreSlug: (Array.isArray(movie.genreSlugs) && movie.genreSlugs[0])
                || (Array.isArray(movie.genres) && movie.genres[0]
                    ? this.genreNameToSlug(movie.genres[0])
                    : '') || prev?.genreSlug || '',
            countries: Array.isArray(movie.countries) ? movie.countries.slice(0, 4) : (prev?.countries || []),
            currentTime: opts.currentTime != null
                ? Number(opts.currentTime) || 0
                : (sameEp ? (Number(prev.currentTime) || 0) : 0),
            duration: opts.duration != null
                ? Number(opts.duration) || 0
                : (sameEp ? (Number(prev.duration) || 0) : 0),
            serverIdx: opts.serverIdx != null ? Number(opts.serverIdx) || 0 : (prev?.serverIdx ?? 0),
            epIdx: opts.epIdx != null ? Number(opts.epIdx) || 0 : (sameEp ? (prev?.epIdx ?? 0) : 0),
            updatedAt: Date.now()
        };

        const filtered = list.filter(it => it.slug !== movie.slug);
        filtered.unshift(entry);
        const clamped = filtered.slice(0, 10);

        return new Promise(resolve => {
            if (typeof chrome !== 'undefined' && chrome.storage?.local) {
                chrome.storage.local.set({ vibe_continue_watching: clamped }, resolve);
            } else {
                localStorage.setItem('vibe_continue_watching', JSON.stringify(clamped));
                resolve();
            }
        });
    },

    /** Upsert progress heartbeat from native PROGRESS messages (by slug). */
    async applyProgressUpdate(msg) {
        if (!msg || !msg.slug) return;
        const list = await this.getContinueWatching();
        const prev = list.find(it => it.slug === msg.slug) || {};
        const entry = {
            slug: msg.slug,
            name: msg.name || prev.name || '',
            origin_name: msg.origin_name || prev.origin_name || '',
            poster: msg.poster || prev.poster || '',
            source: msg.source || prev.source || 'kkphim',
            epName: msg.epName || prev.epName || '',
            epSlug: msg.epSlug || prev.epSlug || '',
            linkM3u8: msg.linkM3u8 || prev.linkM3u8 || '',
            linkEmbed: msg.linkEmbed || prev.linkEmbed || '',
            genres: prev.genres || [],
            genreName: prev.genreName || '',
            genreSlug: prev.genreSlug || '',
            countries: prev.countries || [],
            currentTime: Number(msg.currentTime) || 0,
            duration: Number(msg.duration) || Number(prev.duration) || 0,
            serverIdx: msg.serverIdx != null ? Number(msg.serverIdx) || 0 : (prev.serverIdx ?? 0),
            epIdx: msg.epIdx != null ? Number(msg.epIdx) || 0 : (prev.epIdx ?? 0),
            updatedAt: Date.now()
        };
        const filtered = list.filter(it => it.slug !== msg.slug);
        filtered.unshift(entry);
        const clamped = filtered.slice(0, 10);
        return new Promise(resolve => {
            if (typeof chrome !== 'undefined' && chrome.storage?.local) {
                chrome.storage.local.set({ vibe_continue_watching: clamped }, resolve);
            } else if (typeof localStorage !== 'undefined') {
                localStorage.setItem('vibe_continue_watching', JSON.stringify(clamped));
                resolve();
            } else {
                resolve();
            }
        });
    },

    /**
     * Classify a server/lang label into audio type.
     * @returns {'thuyetminh'|'longtieng'|'vietsub'|'other'}
     */
    detectServerAudioType(name) {
        const raw = String(name || '').normalize('NFC');
        if (!raw.trim()) return 'other';
        const folded = raw.normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase();

        // Thuyết minh / TM (before LT so "TM + LT" still ranks as TM)
        if (
            /thuyết\s*minh/i.test(raw) ||
            /thuyet\s*minh/.test(folded) ||
            /(?:^|[^a-z0-9])tm(?:[^a-z0-9]|$)/i.test(raw) ||
            /\(\s*tm\s*\)/i.test(raw)
        ) {
            return 'thuyetminh';
        }

        // Lồng tiếng / LT / generic Vietnamese audio
        if (
            /lồng\s*tiếng/i.test(raw) ||
            /long\s*tieng/.test(folded) ||
            /(?:^|[^a-z0-9])lt(?:[^a-z0-9]|$)/i.test(raw) ||
            /\(\s*lt\s*\)/i.test(raw) ||
            /audio\s*vi[eệ]t/i.test(raw) ||
            /tiếng\s*việt/i.test(raw) ||
            /tieng\s*viet/.test(folded) ||
            /vietnamese/i.test(raw)
        ) {
            return 'longtieng';
        }

        if (/vietsub/i.test(raw) || /phụ\s*đề/i.test(raw) || /phu\s*de/.test(folded)) {
            return 'vietsub';
        }
        return 'other';
    },

    /** Rank for preferVietnameseServerIndex: lower = better. TM > LT > Vietsub > other. */
    _serverAudioRank(server) {
        const type = server?.serverType || this.detectServerAudioType(server?.serverName || server?.name || '');
        if (type === 'thuyetminh') return 0;
        if (type === 'longtieng') return 1;
        if (type === 'vietsub') return 2;
        return 3;
    },

    /**
     * Prefer Vietnamese audio when present.
     * Priority: Thuyết minh > Lồng tiếng > Vietsub > other.
     * @param {Array} servers
     * @returns {number} index into servers (0 if empty / no preference)
     */
    preferVietnameseServerIndex(servers) {
        if (!servers?.length) return 0;
        let bestIdx = 0;
        let bestRank = Infinity;
        for (let i = 0; i < servers.length; i++) {
            const s = servers[i];
            if (s?.items && s.items.length === 0) continue;
            const rank = this._serverAudioRank(s);
            if (rank < bestRank) {
                bestRank = rank;
                bestIdx = i;
            }
        }
        return bestIdx;
    },

    /** Build movieContext playlist for native next/prev episode strip. */
    buildMovieContext(movie, serverIdx = null, epIdx = 0) {
        if (!movie) return null;
        const srcServers = (movie.episodes || []).filter(s => s.items?.length);
        const servers = srcServers.map(s => ({
            name: s.serverName || s.name || 'Server',
            items: (s.items || []).map(ep => ({
                name: ep.name,
                slug: ep.slug || '',
                linkM3u8: ep.linkM3u8 || '',
                linkEmbed: ep.linkEmbed || ''
            }))
        }));
        if (!servers.length) return null;
        let sIdx;
        if (serverIdx == null || !Number.isFinite(Number(serverIdx))) {
            // Brand-new / unspecified → prefer VN audio track for next/prev strip
            sIdx = this.preferVietnameseServerIndex(srcServers);
        } else {
            sIdx = Math.max(0, Math.min(Number(serverIdx) || 0, servers.length - 1));
        }
        const eIdx = Math.max(0, Math.min(Number(epIdx) || 0, (servers[sIdx].items.length - 1)));
        return {
            slug: movie.slug,
            name: movie.name,
            source: movie.source || 'kkphim',
            poster: movie.poster || movie.thumb || '',
            serverIdx: sIdx,
            epIdx: eIdx,
            servers
        };
    },

    findEpisodeIndices(movie, episode, preferredServer) {
        const servers = (movie?.episodes || []).filter(s => s.items?.length);
        let serverIdx = this.preferVietnameseServerIndex(servers);
        let epIdx = 0;
        if (preferredServer) {
            const sIdx = servers.indexOf(preferredServer);
            if (sIdx >= 0) serverIdx = sIdx;
        }

        // Prefer exact match on preferredServer; else best VN-ranked match among equals
        let best = null;
        for (let si = 0; si < servers.length; si++) {
            const ei = servers[si].items.findIndex(item =>
                (episode.slug && item.slug === episode.slug) ||
                (episode.name && item.name === episode.name) ||
                (episode.linkM3u8 && item.linkM3u8 === episode.linkM3u8) ||
                (episode.linkEmbed && item.linkEmbed === episode.linkEmbed)
            );
            if (ei < 0) continue;
            if (preferredServer && servers[si] === preferredServer) {
                return { serverIdx: si, epIdx: ei, servers };
            }
            const rank = this._serverAudioRank(servers[si]);
            // link match is more specific than name — prefer it
            const linkHit = !!(
                (episode.linkM3u8 && servers[si].items[ei].linkM3u8 === episode.linkM3u8) ||
                (episode.linkEmbed && servers[si].items[ei].linkEmbed === episode.linkEmbed)
            );
            const score = (linkHit ? -100 : 0) + rank;
            if (!best || score < best.score) {
                best = { si, ei, score };
            }
        }
        if (best) {
            serverIdx = best.si;
            epIdx = best.ei;
        }
        return { serverIdx, epIdx, servers };
    },

    progressPercent(item) {
        const t = Number(item?.currentTime) || 0;
        const d = Number(item?.duration) || 0;
        if (d <= 0 || t <= 0) return 0;
        return Math.min(100, Math.round((t / d) * 100));
    },

    async getFavorites() {
        return new Promise(resolve => {
            if (typeof chrome !== 'undefined' && chrome.storage?.local) {
                chrome.storage.local.get(['vibe_favorites'], (res) => {
                    resolve(res.vibe_favorites || []);
                });
            } else {
                const stored = localStorage.getItem('vibe_favorites');
                resolve(stored ? JSON.parse(stored) : []);
            }
        });
    },

    async isFavorite(slug) {
        if (!slug) return false;
        const list = await this.getFavorites();
        return list.some(it => it.slug === slug);
    },

    async getFavoriteSlugSet() {
        const list = await this.getFavorites();
        return new Set(list.map(it => it.slug));
    },

    async toggleFavorite(movie) {
        const list = await this.getFavorites();
        const exists = list.some(it => it.slug === movie.slug);
        let updated;
        if (exists) {
            updated = list.filter(it => it.slug !== movie.slug);
        } else {
            updated = [
                {
                    slug: movie.slug,
                    name: movie.name,
                    origin_name: movie.origin_name || '',
                    poster: movie.poster || movie.thumb || '',
                    thumb: movie.thumb || movie.poster || '',
                    source: movie.source || 'kkphim',
                    year: movie.year || '',
                    lang: movie.lang || '',
                    quality: movie.quality || '',
                    rating: movie.rating || null,
                    episode_current: movie.episode_current || '',
                    hasThuyetMinh: !!movie.hasThuyetMinh,
                    hasLongTieng: !!movie.hasLongTieng,
                    hasVietsub: movie.hasVietsub !== false,
                    isChieuRap: !!movie.isChieuRap
                },
                ...list
            ].slice(0, 80);
        }

        return new Promise(resolve => {
            if (typeof chrome !== 'undefined' && chrome.storage?.local) {
                chrome.storage.local.set({ vibe_favorites: updated }, () => resolve(!exists));
            } else {
                localStorage.setItem('vibe_favorites', JSON.stringify(updated));
                resolve(!exists);
            }
        });
    },

    async getRecentSearches() {
        return new Promise(resolve => {
            if (typeof chrome !== 'undefined' && chrome.storage?.local) {
                chrome.storage.local.get(['vibe_recent_searches'], (res) => {
                    resolve(res.vibe_recent_searches || []);
                });
            } else {
                try {
                    const stored = localStorage.getItem('vibe_recent_searches');
                    resolve(stored ? JSON.parse(stored) : []);
                } catch (e) {
                    resolve([]);
                }
            }
        });
    },

    async addRecentSearch(keyword) {
        const kw = String(keyword || '').trim();
        if (kw.length < 2) return;
        const list = await this.getRecentSearches();
        const filtered = list.filter(s => s.toLowerCase() !== kw.toLowerCase());
        filtered.unshift(kw);
        const clamped = filtered.slice(0, 8);
        return new Promise(resolve => {
            if (typeof chrome !== 'undefined' && chrome.storage?.local) {
                chrome.storage.local.set({ vibe_recent_searches: clamped }, resolve);
            } else {
                localStorage.setItem('vibe_recent_searches', JSON.stringify(clamped));
                resolve();
            }
        });
    },

    async clearRecentSearches() {
        return new Promise(resolve => {
            if (typeof chrome !== 'undefined' && chrome.storage?.local) {
                chrome.storage.local.set({ vibe_recent_searches: [] }, resolve);
            } else {
                localStorage.removeItem('vibe_recent_searches');
                resolve();
            }
        });
    }
};

if (typeof window !== 'undefined') {
    window.MovieService = MovieService;
}
if (typeof globalThis !== 'undefined') {
    globalThis.MovieService = MovieService;
}
