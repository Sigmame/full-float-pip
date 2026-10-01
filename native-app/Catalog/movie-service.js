// movie-service.js — Unified API for KKPhim (phimapi.com) and NguonC (phim.nguonc.com)
// High-frequency fresh updates prioritize recent titles.
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
    //
    // `thuyetminh` and `longtieng` are not extra providers: they are the two
    // dubbed catalogues, which is what a viewer browsing "Thuyết minh" actually
    // wants (2.344 and 1.379 titles measured, 24 per page) instead of the newest
    // ten releases that happen to carry a dub.
    SOURCES: [
        { id: 'kkphim', name: 'KKPhim (HLS FHD)', badge: 'VIP' },
        { id: 'nguonc', name: 'NguonC (Cập nhật liên tục)', badge: 'Đang Chiếu' },
        { id: 'thuyetminh', name: 'Kho Thuyết Minh (2.300+ phim)', badge: 'TM' },
        { id: 'longtieng', name: 'Kho Lồng Tiếng (1.300+ phim)', badge: 'LT' },
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
                thumb: 'https://i.ytimg.com/vi/rFZHOHl-L8A/maxresdefault.jpg',
                poster: 'https://i.ytimg.com/vi/rFZHOHl-L8A/maxresdefault.jpg',
                quality: 'Live Stream',
                lang: 'Lofi Music',
                source: 'livetv',
                youtubeId: 'rFZHOHl-L8A',
                streamUrl: 'https://www.youtube.com/watch?v=rFZHOHl-L8A'
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
            title: title || stream?.name || 'Nhạc nền',
            site: 'youtube',
            width: 520,
            height: 292,
            currentTime: 0,
            preferEmbed: true,
            focusSession: true
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

    getYouTubeMovies(keyword = '', filter = 'all') {
        const normalize = value => String(value || '').toLowerCase().normalize('NFD')
            .replace(/[\u0300-\u036f]/g, '').replace(/đ/g, 'd');
        const query = normalize(keyword).trim();
        return VibeSiteAccess.youtubeMovies.filter(movie => {
            if (filter === 'hongkong' && !movie.hongKongCast) return false;
            if (filter === 'vietnamese' && !movie.audio.includes('Việt')) return false;
            return !query || normalize([movie.name, movie.original_name, movie.cast,
                movie.year, movie.region, movie.genre, movie.channel].join(' ')).includes(query);
        }).map(movie => ({
            ...movie,
            url: `https://www.youtube.com/watch?v=${movie.id}`,
            thumb: `https://i.ytimg.com/vi/${movie.id}/mqdefault.jpg`
        }));
    },

    buildYouTubeMovieFloatInfo(movie) {
        const id = VibeSiteAccess.youtubeMovies.find(item => item.id === movie?.id)?.id;
        if (!id) throw new Error('Phim YouTube chưa được cho phép.');
        return {
            pageUrl: `https://www.youtube.com/watch?v=${id}`,
            embedUrl: `https://www.youtube.com/embed/${id}?autoplay=1&rel=0`,
            title: VibeSiteAccess.youtubeMovies.find(item => item.id === id).name,
            site: 'youtube', width: 640, height: 360, currentTime: 0,
            preferEmbed: true, aiDubEnabled: false, focusSession: false
        };
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

    // --- Home page cache: last good result per source, shown instantly on the next visit ---
    _homeCacheMaxAgeMs: 12 * 60 * 60 * 1000,
    _homeCacheKey(source) { return `vibe_home_v1_${source}`; },
    _favoritesSection(favorites) {
        return favorites.length ? {
            id: 'mylist',
            title: 'Danh sách của tôi',
            subtitle: 'Phim đã lưu để xem sau',
            items: favorites.slice(0, 12),
            categoryKey: 'favorites'
        } : null;
    },
    // Identifies what the visitor sees, so a refresh that changed nothing does not redraw the page.
    homeSignature(data) {
        const spots = (data.spotlights || []).map(m => m.slug).join(',');
        const rows = (data.sections || []).filter(s => s.id !== 'mylist')
            .map(s => `${s.id}:${(s.items || []).map(m => m.slug).join(',')}`).join('|');
        return `${spots}#${rows}`;
    },
    homeRowCount(data) {
        return (data.sections || []).filter(s => s.id !== 'mylist').length;
    },
    async getCachedHome(source) {
        const key = this._homeCacheKey(source);
        let entry = null;
        try { entry = (await chrome.storage.local.get(key))[key]; } catch {}
        if (!entry || !Array.isArray(entry.sections) || !entry.sections.length) return null;
        if (!(Date.now() - entry.at < this._homeCacheMaxAgeMs)) return null;
        // "My list" is personal and local: always rebuilt from current favourites, never from the cache.
        let favorites = [];
        try { favorites = await this.getFavorites(); } catch {}
        const sections = entry.sections.filter(s => s.id !== 'mylist');
        const mine = this._favoritesSection(favorites);
        if (mine) sections.unshift(mine);
        const spotlights = entry.spotlights || [];
        return { spotlight: spotlights[0] || null, spotlights, sections, cachedAt: entry.at };
    },
    async _saveHomeCache(source, result) {
        // Judge what would be stored, not what was returned: a page holding only "My list" is an outage.
        const sections = (result.sections || []).filter(s => s.id !== 'mylist');
        if (!sections.length) return;
        const key = this._homeCacheKey(source);
        try {
            // A partial outage returns fewer rows without failing; never let it replace a fuller, still-valid page.
            const existing = (await chrome.storage.local.get(key))[key];
            const valid = existing && Array.isArray(existing.sections)
                && (Date.now() - existing.at) < this._homeCacheMaxAgeMs;
            if (valid && existing.sections.length > sections.length) return;
            await chrome.storage.local.set({ [key]: { at: Date.now(), spotlights: result.spotlights, sections } });
        } catch {}
    },

    // --- Grid cache: page 1 of each list, so reopening a category is instant ---
    _feedCacheKey: 'vibe_feed_cache_v1',
    _feedCacheMaxEntries: 12,
    _feedCacheMaxAgeMs: 6 * 60 * 60 * 1000,
    feedSignature(items) {
        return (items || []).map(m => `${m.source || ''}:${m.slug}`).join(',');
    },
    async _readFeedCache() {
        try {
            const stored = (await chrome.storage.local.get(this._feedCacheKey))[this._feedCacheKey];
            return stored && typeof stored === 'object' && stored.entries ? stored : { entries: {}, order: [] };
        } catch { return { entries: {}, order: [] }; }
    },
    async getCachedFeed(key) {
        const entry = (await this._readFeedCache()).entries[key];
        if (!entry || !Array.isArray(entry.items) || !entry.items.length) return null;
        if (!(Date.now() - entry.at < this._feedCacheMaxAgeMs)) return null;
        return { items: entry.items, at: entry.at };
    },
    async saveFeedPage(key, items) {
        if (!Array.isArray(items) || !items.length) return;
        try {
            const cache = await this._readFeedCache();
            const existing = cache.entries[key];
            const valid = existing && Array.isArray(existing.items) && (Date.now() - existing.at) < this._feedCacheMaxAgeMs;
            // A partial outage answers with a fraction of a page; never let it replace a fuller one.
            if (valid && items.length * 2 < existing.items.length) return;
            cache.entries[key] = { at: Date.now(), items };
            cache.order = (cache.order || []).filter(k => k !== key);
            cache.order.push(key);
            while (cache.order.length > this._feedCacheMaxEntries) delete cache.entries[cache.order.shift()];
            await chrome.storage.local.set({ [this._feedCacheKey]: cache });
        } catch {}
    },

    _requestTimeoutMs: 8000,
    _audioEnrichTimeoutMs: 3500,
    // Resolve with `fallback` instead of waiting on a provider that never answers.
    _withTimeout(promise, ms, fallback) {
        let timer;
        const timeout = new Promise(resolve => { timer = setTimeout(() => resolve(fallback), ms); });
        return Promise.race([Promise.resolve(promise).catch(() => fallback), timeout]).finally(() => clearTimeout(timer));
    },

    /**
     * Get home sections for VibeWatch Cinema dashboard experience
     */
    async getHomeSections(source = 'kkphim', options = {}) {
        const T = this._requestTimeoutMs;
        const guard = p => this._withTimeout(p, T, []);
        // Billboard lists first: they decide the spotlight, whose detail requests then
        // run while the slower rows (dubbed, anime, favourites) are still loading.
        const primary = [
            guard(this._getKKPhimList('chieurap', 1)),
            guard(this._getNguonCList('moi', 1)),
            guard(this._getKKPhimList('bo', 1)),
            guard(this._getKKPhimList('le', 1))
        ];
        const secondary = Promise.allSettled([
            guard(this._getKKPhimList('thuyetminh', 1).then(items => this._withNguonCAudio(items, 'thuyetminh'))),
            guard(this._getKKPhimList('longtieng', 1).then(items => this._withNguonCAudio(items, 'longtieng'))),
            guard(this._getKKPhimList('hoathinh', 1)),
            this.getFavorites(),
            this.getBecauseYouWatched(12)
        ]);
        const primaryResults = await Promise.allSettled(primary);
        const listOf = r => (r.status === 'fulfilled' && Array.isArray(r.value)) ? r.value : [];
        const chieuRapRaw = listOf(primaryResults[0]);
        const dangChieuRaw = listOf(primaryResults[1]);
        const phimBoRaw = listOf(primaryResults[2]);
        const phimLeRaw = listOf(primaryResults[3]);

        const seenSlugs = new Set();
        const candidatePool = [...chieuRapRaw, ...dangChieuRaw, ...phimBoRaw, ...phimLeRaw];
        const spotlightCandidates = [];
        for (const m of candidatePool) {
            if (!m || !m.slug || seenSlugs.has(m.slug)) continue;
            if (m.thumb || m.poster) {
                seenSlugs.add(m.slug);
                spotlightCandidates.push(m);
                if (spotlightCandidates.length >= 6) break;
            }
        }
        const detailsPromise = Promise.allSettled(
            spotlightCandidates.map(m => this._withTimeout(this.getDetail(m.slug, m.source || 'kkphim'), T, null))
        );
        // The billboard is ready as soon as its details are; hand it over before the slower rows finish.
        const spotlightsPromise = detailsPromise.then(spotlightDetails => {
            const ready = spotlightCandidates.map((m, i) => {
                const d = spotlightDetails[i];
                return d.status === 'fulfilled' && d.value ? { ...m, ...d.value } : m;
            });
            try { options.onSpotlights?.(ready); } catch (e) { console.warn('[MovieService] onSpotlights failed:', e); }
            return ready;
        });
        const [secondaryResults, spotlights] = await Promise.all([secondary, spotlightsPromise]);
        const thuyetMinhRaw = listOf(secondaryResults[0]);
        const longTiengRaw = listOf(secondaryResults[1]);
        const animeRaw = listOf(secondaryResults[2]);
        const favorites = secondaryResults[3].status === 'fulfilled' ? secondaryResults[3].value : [];
        const because = secondaryResults[4].status === 'fulfilled' ? secondaryResults[4].value : { items: [] };

        const spotlight = spotlights[0] || null;

        const topTrending = this.buildTopTrending([chieuRapRaw, phimBoRaw, phimLeRaw, dangChieuRaw], 10);
        const phimBoCombined = this._mergeAndDeduplicate(dangChieuRaw, phimBoRaw);

        const sections = [];

        const mine = this._favoritesSection(favorites);
        if (mine) sections.push(mine);

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
                subtitle: 'Kho 2.300+ bản thuyết minh tiếng Việt',
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
                subtitle: 'Kho 1.300+ bản lồng tiếng chọn lọc',
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

        const result = {
            spotlight,
            spotlights,
            sections: sections.filter(s => s.items && s.items.length > 0)
        };
        await this._saveHomeCache(source, result);
        return result;
    },

    /**
     * Get latest movies with pagination and category support
     */
    async getLatest(source = 'kkphim', category = 'moi', page = 1) {
        if (category === 'livetv') {
            return this.getLiveTVChannels();
        }
        // Browsing the dubbed catalogue itself: the category the user picked
        // follows the source, so "Kho Thuyết Minh" stays dubbed even on
        // "Trang chủ".
        const effectiveCategory = (source === 'thuyetminh' || source === 'longtieng')
            ? source
            : category;
        if (source === 'all') {
            const [kkResult, ncResult] = await Promise.allSettled([
                this._getKKPhimList(effectiveCategory, page),
                this._getNguonCList(effectiveCategory, page)
            ]);
            const kkItems = kkResult.status === 'fulfilled' ? kkResult.value : [];
            const ncItems = ncResult.status === 'fulfilled' ? ncResult.value : [];
            return this._mergeAndDeduplicate(kkItems, ncItems);
        } else if (source === 'nguonc') {
            return this._getNguonCList(effectiveCategory, page);
        } else {
            return this._getKKPhimList(effectiveCategory, page);
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
                // Prefer an item with both poster and backdrop.
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
                // Prefer current-year releases without hard-coding a calendar year.
                if (page === 1) {
                    const year = new Date().getFullYear();
                    const [crRes, boRes, leRes] = await Promise.allSettled([
                        fetch('https://phimapi.com/v1/api/danh-sach/phim-chieu-rap?page=1').then(r => r.json()),
                        fetch(`https://phimapi.com/v1/api/danh-sach/phim-bo?year=${year}&page=1`).then(r => r.json()),
                        fetch(`https://phimapi.com/v1/api/danh-sach/phim-le?year=${year}&page=1`).then(r => r.json())
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
                    const year = new Date().getFullYear();
                    const [resCurrent, resAll] = await Promise.allSettled([
                        fetch(`https://phimapi.com/v1/api/danh-sach/phim-bo?year=${year}&page=1`).then(r => r.json()),
                        fetch('https://phimapi.com/v1/api/danh-sach/phim-bo?page=1').then(r => r.json())
                    ]);
                    const itemsCurrent = (resCurrent.status === 'fulfilled' && resCurrent.value?.data?.items) || [];
                    const itemsAll = (resAll.status === 'fulfilled' && resAll.value?.data?.items) || [];
                    const combined = [...itemsCurrent, ...itemsAll];
                    const norm = combined.map(it => this._normalizeKKPhimItem(it));
                    return this._sortNewestFirst(this._deduplicateList(norm));
                } else {
                    const res = await fetch(`https://phimapi.com/v1/api/danh-sach/phim-bo?page=${page}`);
                    const data = await res.json();
                    items = data?.data?.items || [];
                }
            } else if (category === 'le') {
                if (page === 1) {
                    const year = new Date().getFullYear();
                    const [resCurrent, resPrevious] = await Promise.allSettled([
                        fetch(`https://phimapi.com/v1/api/danh-sach/phim-le?year=${year}&page=1`).then(r => r.json()),
                        fetch(`https://phimapi.com/v1/api/danh-sach/phim-le?year=${year - 1}&page=1`).then(r => r.json())
                    ]);
                    const itemsCurrent = (resCurrent.status === 'fulfilled' && resCurrent.value?.data?.items) || [];
                    const itemsPrevious = (resPrevious.status === 'fulfilled' && resPrevious.value?.data?.items) || [];
                    const combined = [...itemsCurrent, ...itemsPrevious];
                    const norm = combined.map(it => this._normalizeKKPhimItem(it));
                    return this._sortNewestFirst(this._deduplicateList(norm));
                } else {
                    const res = await fetch(`https://phimapi.com/v1/api/danh-sach/phim-le?page=${page}`);
                    const data = await res.json();
                    items = data?.data?.items || [];
                }
            } else if (category === 'hoathinh') {
                if (page === 1) {
                    const year = new Date().getFullYear();
                    const recentResponse = await fetch(`https://phimapi.com/v1/api/danh-sach/hoat-hinh?year=${year}&page=1`);
                    const recentData = await recentResponse.json();
                    const recentItems = recentData?.data?.items || [];
                    if (recentItems.length > 0) {
                        return recentItems.map(it => this._normalizeKKPhimItem(it));
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

        let normalized = items.map(item => this._normalizeKKPhimItem(item));
        // The category *is* the audio track. Measured on `phim-thuyet-minh`: all
        // 24 items of page 1 read "Vietsub + Thuyết Minh", and every item of
        // `phim-long-tieng` carries a dub. Marking them here means the audio
        // pill can never filter one of these lists down to nothing.
        if (category === 'thuyetminh') {
            normalized = normalized.map(it => ({ ...it, hasThuyetMinh: true }));
        } else if (category === 'longtieng') {
            normalized = normalized.map(it => ({ ...it, hasLongTieng: true }));
        }
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
            quality: item.quality || '',
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
            quality: movie.quality || '',
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

    /**
     * NguonC answers 404 - "Category movie doesn't exist!" - for every category
     * the extension used to ask for (`dang-chieu` and `phim-chieu-rap`), because
     * that site renames and drops its lists. The result was a silently empty
     * NguonC half of the home page. Only these paths answer today, probed one by
     * one: `phim-moi-cap-nhat`, `phim-bo`, `phim-le`, `hoat-hinh`, `tv-shows`.
     */
    _nguoncCategoryPath(category) {
        switch (category) {
            case 'bo': return '/api/films/danh-sach/phim-bo';
            case 'le': return '/api/films/danh-sach/phim-le';
            case 'hoathinh': return '/api/films/danh-sach/hoat-hinh';
            case 'tvshows': return '/api/films/danh-sach/tv-shows';
            // No cinema category exists on NguonC, and guessing one is what broke
            // the home page: return nothing and let KKPhim (which does have one)
            // fill the Chiếu rạp row.
            case 'chieurap': return '';
            default: return '/api/films/phim-moi-cap-nhat';
        }
    },

    async _getNguonCList(category = 'moi', page = 1) {
        if (category === 'thuyetminh' || category === 'longtieng') {
            return this._getNguonCAudioList(category, page);
        }
        const path = this._nguoncCategoryPath(category);
        if (!path) return [];
        const url = `https://phim.nguonc.com${path}?page=${page}`;

        try {
            const res = await fetch(url);
            const data = await res.json();
            const items = data.items || [];
            const normalized = items.map(item => this._normalizeNguonCItem(item));
            return this._sortNewestFirst(normalized);
        } catch (e) {
            console.warn('[MovieService] _getNguonCList error:', e);
            return [];
        }
    },

    /**
     * Dubbed titles from NguonC.
     *
     * NguonC labels audio per title (`language: "Vietsub + Thuyết Minh"`) and
     * publishes no dubbed list, and its pages hold ten titles each. Measured hit
     * rates: 4/50 on `phim-moi-cap-nhat`, 1/30 on `phim-bo`, 1/30 on `phim-le`.
     * Filtering one page therefore returns nothing at all, which is why the
     * dubbed views used to look empty. This scans a window of the newest pages
     * once and caches the (small) result for the session, then pages through it.
     */
    _nguoncAudioCache: null,
    _nguoncAudioScan: null,
    _nguonCAudioPageSize: 24,
    // One scan serves both kinds and is shared by concurrent callers, so the
    // dubbed and voiced rows on the home page cost ten requests, not twenty.
    async _scanNguonCAudio(scanPages = 10) {
        const entry = this._nguoncAudioCache;
        if (entry && (Date.now() - entry.at) < 10 * 60 * 1000) return entry;
        if (!this._nguoncAudioScan) {
            this._nguoncAudioScan = (async () => {
                const pages = [];
                for (let p = 1; p <= scanPages; p++) pages.push(p);
                const results = await Promise.allSettled(
                    pages.map(p => this._withTimeout(
                        fetch(`https://phim.nguonc.com/api/films/phim-moi-cap-nhat?page=${p}`).then(r => r.json()),
                        this._requestTimeoutMs, null))
                );
                const all = [];
                results.forEach(r => {
                    if (r.status !== 'fulfilled') return;
                    (r.value?.items || []).forEach(item => all.push(this._normalizeNguonCItem(item)));
                });
                const scanned = {
                    at: Date.now(),
                    thuyetminh: all.filter(it => it.hasThuyetMinh),
                    longtieng: all.filter(it => it.hasLongTieng)
                };
                // An empty scan is usually an outage; do not cache it for ten minutes.
                if (all.length) this._nguoncAudioCache = scanned;
                return scanned;
            })().finally(() => { this._nguoncAudioScan = null; });
        }
        return this._nguoncAudioScan;
    },
    async _getNguonCAudioList(kind, page = 1, scanPages = 10) {
        const scanned = await this._scanNguonCAudio(scanPages);
        const list = scanned[kind] || [];
        const size = this._nguonCAudioPageSize;
        return list.slice((page - 1) * size, page * size);
    },

    /**
     * KKPhim's dubbed list with anything dubbed NguonC has and it does not.
     * Different catalogues, same category: the merge is what makes a dubbed row
     * wider than either source on its own.
     */
    async _withNguonCAudio(kkItems, kind) {
        // The scan is slow; the KKPhim rows must not wait on it indefinitely.
        const ncItems = await this._withTimeout(
            this._getNguonCAudioList(kind).catch(() => []), this._audioEnrichTimeoutMs, []);
        return this._mergeAndDeduplicate(kkItems, ncItems);
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

    /** Remove a single movie from continue watching history by slug. */
    async removeContinueWatching(slug) {
        if (!slug) return;
        const list = await this.getContinueWatching();
        const filtered = list.filter(it => it.slug !== slug);
        return new Promise(resolve => {
            if (typeof chrome !== 'undefined' && chrome.storage?.local) {
                chrome.storage.local.set({ vibe_continue_watching: filtered }, resolve);
            } else if (typeof localStorage !== 'undefined') {
                localStorage.setItem('vibe_continue_watching', JSON.stringify(filtered));
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

    // --- Watched / hidden marks: two small lists kept like "My list" (newest first) ---
    _marksMax: 500,
    async _readMarks(key) {
        try {
            if (typeof chrome !== 'undefined' && chrome.storage?.local) {
                const stored = (await chrome.storage.local.get(key))[key];
                return Array.isArray(stored) ? stored : [];
            }
            const stored = JSON.parse(localStorage.getItem(key) || '[]');
            return Array.isArray(stored) ? stored : [];
        } catch { return []; }
    },
    async _writeMarks(key, list) {
        if (typeof chrome !== 'undefined' && chrome.storage?.local) await chrome.storage.local.set({ [key]: list });
        else localStorage.setItem(key, JSON.stringify(list));
    },
    /** What a card needs to be drawn again later, from a list item or a movie detail. */
    _movieMark(movie) {
        return {
            slug: movie.slug,
            name: movie.name || movie.slug,
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
            isChieuRap: !!movie.isChieuRap,
            markedAt: Date.now()
        };
    },
    async _setMark(key, movie, on) {
        if (!movie || !movie.slug) return false;
        const list = (await this._readMarks(key)).filter(item => item.slug !== movie.slug);
        if (on) list.unshift(this._movieMark(movie));
        await this._writeMarks(key, list.slice(0, this._marksMax));
        return !!on;
    },
    getWatched() { return this._readMarks('vibe_watched'); },
    getHidden() { return this._readMarks('vibe_hidden'); },
    async getWatchedSlugSet() { return new Set((await this.getWatched()).map(item => item.slug)); },
    async getHiddenSlugSet() { return new Set((await this.getHidden()).map(item => item.slug)); },
    /** Mark or unmark as watched; resolves with the new state. */
    setWatched(movie, watched) { return this._setMark('vibe_watched', movie, watched); },
    /** Hide a movie everywhere ("not interested") or bring it back; resolves with whether it is hidden. */
    setHidden(movie, hidden) { return this._setMark('vibe_hidden', movie, hidden); },
    /** `items` without anything in `hiddenSlugs`. */
    withoutHidden(items, hiddenSlugs) {
        if (!hiddenSlugs || !hiddenSlugs.size) return items || [];
        return (items || []).filter(item => !item || !hiddenSlugs.has(item.slug));
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
