// popup.js — Popup panel logic with Web Video Detection & VibeWatch Cinema Movie Hub (No Emojis, Clean UI/UX, TikTok VN Infinite Scroll)

let currentPopupTab = 'movies';
let popupMovieSource = 'all';
let popupCategory = 'moi';
let currentSearchKeyword = '';

document.addEventListener('DOMContentLoaded', async () => {
    MovieImages.install(document);
    initTabs();
    initFilterChips();
    initMoviePanel();
    initTikTokPanel();
    initRecentPanel();
    initLofiCoding();
    await initWebVideoPanel();
    // Ensure Kho Phim list paints on first open (default tab)
    loadPopupContinueStrip();
    loadPopupMovies();
});

// MARK: - Tabs Initialization
function initTabs() {
    const tabWeb = document.getElementById('tab-web');
    const tabMovies = document.getElementById('tab-movies');
    const tabTikTok = document.getElementById('tab-tiktok');
    const tabRecent = document.getElementById('tab-recent');
    const panelWeb = document.getElementById('panel-web');
    const panelMovies = document.getElementById('panel-movies');
    const panelTikTok = document.getElementById('panel-tiktok');
    const panelRecent = document.getElementById('panel-recent');

    function setActiveTab(name) {
        currentPopupTab = name;
        [tabWeb, tabMovies, tabTikTok, tabRecent].forEach(t => t?.classList.remove('active'));
        [panelWeb, panelMovies, panelTikTok, panelRecent].forEach(p => p?.classList.remove('active'));

        if (name === 'web') {
            tabWeb?.classList.add('active');
            panelWeb?.classList.add('active');
        } else if (name === 'movies') {
            tabMovies?.classList.add('active');
            panelMovies?.classList.add('active');
            loadPopupContinueStrip();
            loadPopupMovies(currentSearchKeyword);
        } else if (name === 'tiktok') {
            tabTikTok?.classList.add('active');
            panelTikTok?.classList.add('active');
        } else if (name === 'recent') {
            tabRecent?.classList.add('active');
            panelRecent?.classList.add('active');
            renderRecentPanel();
        }
    }

    tabWeb?.addEventListener('click', () => setActiveTab('web'));
    tabMovies?.addEventListener('click', () => setActiveTab('movies'));
    tabTikTok?.addEventListener('click', () => setActiveTab('tiktok'));
    tabRecent?.addEventListener('click', () => setActiveTab('recent'));
    setActiveTab('movies');

    // Ghost Mode Quick Toggle — sync real native state
    const ghostBtn = document.getElementById('popup-ghost-btn');
    let isGhost = true;
    const syncGhostBtn = (on) => {
        isGhost = !!on;
        ghostBtn?.classList.toggle('active', isGhost);
        if (ghostBtn) {
            ghostBtn.textContent = isGhost ? 'Xuyên chuột: Bật' : 'Xuyên chuột: Tắt';
            ghostBtn.setAttribute('aria-pressed', isGhost ? 'true' : 'false');
        }
    };
    chrome.runtime.sendMessage({ type: 'GET_NATIVE_STATUS' }).then((res) => {
        if (typeof res?.isGhost === 'boolean') syncGhostBtn(res.isGhost);
    }).catch(() => {});

    chrome.runtime.onMessage.addListener((msg) => {
        if (msg?.type === 'NATIVE_STATUS_BROADCAST' && typeof msg.isGhost === 'boolean') {
            syncGhostBtn(msg.isGhost);
        }
    });

    ghostBtn?.addEventListener('click', async () => {
        try {
            const res = await chrome.runtime.sendMessage({
                type: 'NATIVE_COMMAND',
                action: 'toggleGhost'
            });
            if (typeof res?.isGhost === 'boolean') {
                syncGhostBtn(res.isGhost);
            } else if (res?.success !== false) {
                syncGhostBtn(!isGhost);
            }
        } catch (e) {
            console.error(e);
        }
    });

    // Open Catalog Full Page button
    const openCatalogBtn = document.getElementById('btn-open-catalog');
    if (openCatalogBtn) {
        openCatalogBtn.addEventListener('click', () => {
            chrome.tabs.create({ url: chrome.runtime.getURL('catalog.html') });
        });
    }
}

// MARK: - Filter Chips
function initFilterChips() {
    const chips = document.querySelectorAll('.chip-btn[data-cat]');
    chips.forEach(chip => {
        chip.addEventListener('click', () => {
            chips.forEach(c => c.classList.remove('active'));
            chip.classList.add('active');
            popupCategory = chip.dataset.cat || 'moi';
            currentSearchKeyword = '';
            const searchInput = document.getElementById('popup-movie-search');
            if (searchInput) searchInput.value = '';
            document.getElementById('popup-search-clear')?.classList.add('hidden');
            loadPopupMovies();
        });
    });
}

function initLofiCoding() {
    const btn = document.getElementById('btn-lofi-coding');
    btn?.addEventListener('click', async (e) => {
        e.stopPropagation();
        const original = btn.textContent;
        btn.disabled = true;
        btn.textContent = 'Đang mở...';
        try {
            const ok = await floatLofiCoding();
            btn.textContent = ok ? 'Đang phát' : 'Thử lại';
            if (!ok) {
                showFloatErrorHint('Không mở được Lofi. Kiểm tra native app (scripts/install.sh) rồi tải lại extension.');
            }
        } catch (err) {
            btn.textContent = 'Thử lại';
            showFloatErrorHint(err?.message || 'Lỗi mở Lofi coding');
        } finally {
            btn.disabled = false;
            setTimeout(() => { if (btn.textContent !== 'Đang phát') btn.textContent = original; }, 1800);
        }
    });
}

/** Float curated Lofi/Synthwave via YouTube embed (not the watch-page bot wall). */
async function floatLofiCoding() {
    const stream = MovieService.getDefaultLofiStream();
    if (!stream) return false;
    const videoInfo = MovieService.buildYouTubeLiveFloatInfo(stream);
    if (!videoInfo.pageUrl) return false;
    const res = await chrome.runtime.sendMessage({
        type: 'FLOAT_VIDEO_REQUEST',
        videoInfo
    });
    if (res?.success) {
        setTimeout(() => window.close(), 300);
        return true;
    }
    showFloatErrorHint(formatFloatError(res));
    return false;
}

// MARK: - Panel 1: Web Video Detection (Original FullFloatPiP)
async function initWebVideoPanel() {
    const videoList = document.getElementById('video-list');

    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
    if (!tab || !tab.id) {
        videoList.innerHTML = '<div class="empty">Không thể truy cập tab hiện tại</div>';
        return;
    }

    if (!tab.url || tab.url.startsWith('chrome://') || tab.url.startsWith('chrome-extension://')) {
        videoList.innerHTML = '<div class="empty">Không hỗ trợ quét trên trang nội bộ trình duyệt.<br><span style="font-size:10.5px;color:#888;margin-top:6px;display:block;">Hãy mở YouTube / Web Video hoặc chuyển sang tab "Kho Phim" để xem phim.</span></div>';
        return;
    }

    try {
        const response = await chrome.tabs.sendMessage(tab.id, { type: 'GET_VIDEOS' });
        renderVideos(response?.videos || []);
    } catch (e) {
        try {
            await chrome.scripting.executeScript({
                target: { tabId: tab.id },
                files: ['content.js'],
            });
            setTimeout(async () => {
                try {
                    const response = await chrome.tabs.sendMessage(tab.id, { type: 'GET_VIDEOS' });
                    renderVideos(response?.videos || []);
                } catch {
                    videoList.innerHTML = '<div class="empty">Không phát hiện video trên trang này<br><span style="font-size:10.5px;color:#888;margin-top:6px;display:block;">Bấm play video trên trang hoặc duyệt tab "Kho Phim"</span></div>';
                }
            }, 800);
        } catch {
            videoList.innerHTML = '<div class="error">Không thể chèn script quét video vào trang này.</div>';
        }
    }

    function renderVideos(videos) {
        if (!videos || videos.length === 0) {
            videoList.innerHTML = '<div class="empty">Không phát hiện video nào<br><span style="font-size:10.5px;color:#888;margin-top:6px;display:block;">Hãy mở tab YouTube / Bilibili hoặc sang tab "Kho Phim"</span></div>';
            return;
        }

        videoList.innerHTML = '';
        videos.forEach((video, index) => {
            const card = document.createElement('div');
            card.className = 'video-card';
            card.innerHTML = `
                <div class="video-info">
                  <span class="video-title" title="${escapeAttr(video.title)}">${escapeHtml(video.title)}</span>
                  <span class="video-meta">${video.width}×${video.height} · ${formatDuration(video.duration)}</span>
                  <span class="video-site">${escapeHtml(video.site)}</span>
                </div>
                <button class="float-btn" data-index="${index}">
                  Phát nổi
                </button>
            `;
            videoList.appendChild(card);
        });

        videoList.querySelectorAll('.float-btn').forEach(btn => {
            btn.addEventListener('click', async (e) => {
                const button = e.currentTarget;
                const index = parseInt(button.dataset.index);
                const video = videos[index];

                button.disabled = true;
                button.textContent = 'Đang mở...';

                try {
                    const playerPrefs = await capturePlayerPrefs(tab.id, video.site);
                    await chrome.tabs.sendMessage(tab.id, {
                        type: 'FLOAT_VIDEO',
                        videoIndex: index,
                    });

                    const result = await chrome.runtime.sendMessage({
                        type: 'FLOAT_VIDEO_REQUEST',
                        videoInfo: video,
                        playerPrefs,
                    });

                    if (result?.success) {
                        button.textContent = 'Đang phát';
                        setTimeout(() => window.close(), 300);
                    } else {
                        button.disabled = false;
                        button.textContent = 'Thử lại';
                        showFloatErrorHint(formatFloatError(result));
                    }
                } catch (err) {
                    button.disabled = false;
                    button.textContent = 'Thử lại';
                    showFloatErrorHint(err?.message || 'Không thể phát nổi video tab này.');
                }
            });
        });
    }
}

// MARK: - Panel 2: Movie Hub (VibeWatch Cinema style)
function initMoviePanel() {
    const searchInput = document.getElementById('popup-movie-search');
    const searchClear = document.getElementById('popup-search-clear');
    const sourceSelect = document.getElementById('popup-source-select');
    let debounceTimer = null;

    if (sourceSelect) {
        sourceSelect.addEventListener('change', (e) => {
            popupMovieSource = e.target.value;
            loadPopupMovies(currentSearchKeyword);
        });
    }

    if (searchInput) {
        searchInput.addEventListener('input', (e) => {
            const val = e.target.value.trim();
            if (val) {
                searchClear?.classList.remove('hidden');
            } else {
                searchClear?.classList.add('hidden');
            }

            clearTimeout(debounceTimer);
            debounceTimer = setTimeout(() => {
                currentSearchKeyword = val;
                loadPopupMovies(val);
            }, 350);
        });
    }

    if (searchClear) {
        searchClear.addEventListener('click', () => {
            searchInput.value = '';
            searchClear.classList.add('hidden');
            currentSearchKeyword = '';
            loadPopupMovies();
        });
    }

    document.getElementById('popup-goto-recent')?.addEventListener('click', () => {
        document.getElementById('tab-recent')?.click();
    });
}

async function loadPopupContinueStrip() {
    const strip = document.getElementById('popup-continue-strip');
    const rail = document.getElementById('popup-continue-rail');
    if (!strip || !rail) return;

    const items = await MovieService.getContinueWatching();
    if (!items.length) {
        strip.classList.add('hidden');
        rail.innerHTML = '';
        return;
    }

    strip.classList.remove('hidden');
    rail.innerHTML = items.slice(0, 6).map((item, idx) => {
        const pct = MovieService.progressPercent(item);
        const progressHtml = pct > 0
            ? `<div class="popup-cont-progress"><div class="popup-cont-bar" style="width:${pct}%"></div></div>`
            : '';
        return `
            <button type="button" class="popup-cont-card" data-idx="${idx}" title="Phát nổi tiếp — ${escapeAttr(item.name)}">
                <img class="popup-cont-thumb" loading="lazy" ${MovieImages.attr(item, 'thumb')} width="36" height="50" alt="">
                <div class="popup-cont-meta">
                    <div class="popup-cont-title">${escapeHtml(item.name)}</div>
                    <div class="popup-cont-ep">${escapeHtml(item.epName || 'Tiếp tục')}</div>
                    ${progressHtml}
                </div>
            </button>
        `;
    }).join('');

    rail.querySelectorAll('.popup-cont-card').forEach(card => {
        card.addEventListener('click', async () => {
            const idx = Number(card.dataset.idx);
            const item = items[idx];
            if (!item) return;
            card.disabled = true;
            try {
                const ok = await floatContinueItem(item);
                if (ok) loadPopupContinueStrip();
            } finally {
                card.disabled = false;
            }
        });
    });
}

async function loadPopupMovies(keyword = '') {
    const list = document.getElementById('popup-movie-list');
    list.innerHTML = '<div class="loading"><div class="spinner"></div><span>Đang tải danh sách phim...</span></div>';

    try {
        let items = [];
        if (keyword) {
            items = await MovieService.search(keyword, popupMovieSource);
        } else if (popupCategory === 'favorites') {
            items = await MovieService.getFavorites();
        } else {
            items = await MovieService.getLatest(popupMovieSource, popupCategory, 1);
        }

        renderPopupMovies(items.slice(0, 15));
    } catch (err) {
        console.error('Failed to load popup movies:', err);
        list.innerHTML = `<div class="empty">Lỗi tải phim từ nguồn ${popupMovieSource.toUpperCase()}. Hãy thử chọn nguồn khác.</div>`;
    }
}

function renderPopupMovies(items) {
    const list = document.getElementById('popup-movie-list');
    if (!items || items.length === 0) {
        list.innerHTML = '<div class="empty">Không tìm thấy phim phù hợp trong mục này.</div>';
        return;
    }

    list.innerHTML = items.map((item, idx) => {
        // Badges (VibeWatch Cinema style: clean color codes, no emojis)
        const badges = [];
        if (item.isChieuRap) badges.push('<span class="mini-badge badge-cr">RẠP</span>');
        if (item.hasThuyetMinh) badges.push('<span class="mini-badge badge-tm">TM</span>');
        if (item.hasLongTieng) badges.push('<span class="mini-badge badge-lt">LT</span>');
        if (item.hasVietsub && !item.hasThuyetMinh && !item.hasLongTieng) badges.push('<span class="mini-badge badge-vs">VIETSUB</span>');
        if (item.quality) badges.push(`<span class="mini-badge badge-quality">${escapeHtml(item.quality)}</span>`);

        return `
            <div class="popup-movie-wrap" data-slug="${escapeAttr(item.slug)}" data-source="${escapeAttr(item.source)}">
                <div class="popup-movie-item" data-idx="${idx}">
                    <img class="popup-movie-thumb" ${MovieImages.attr(item, 'thumb')} width="40" height="56" alt="">
                    <div class="popup-movie-details">
                        <div class="popup-movie-name" title="${escapeAttr(item.name)}">${escapeHtml(item.name)}</div>
                        <div class="popup-movie-badges">${badges.join('')}</div>
                        <div class="popup-movie-sub">${item.year ? item.year + ' · ' : ''}${escapeHtml(item.origin_name || item.time || '')}</div>
                    </div>
                    <div class="popup-movie-actions">
                        <button class="float-btn quick-float-btn" title="Phát nổi — Tập sau tự động / Bỏ qua GT trong PiP">Phát nổi</button>
                        <button class="float-btn ep-pick-btn" title="Chi tiết · chọn tập / server">Chi tiết</button>
                    </div>
                </div>
                <div class="popup-episodes-container hidden"></div>
            </div>
        `;
    }).join('');

    list.querySelectorAll('.popup-movie-wrap').forEach(wrap => {
        const slug = wrap.dataset.slug;
        const itemSource = wrap.dataset.source || popupMovieSource;
        const quickBtn = wrap.querySelector('.quick-float-btn');
        const pickBtn = wrap.querySelector('.ep-pick-btn');
        const container = wrap.querySelector('.popup-episodes-container');

        quickBtn?.addEventListener('click', async (e) => {
            e.stopPropagation();
            const original = quickBtn.textContent;
            quickBtn.textContent = '...';
            quickBtn.disabled = true;
            try {
                const ok = await quickFloatMovie(slug, itemSource);
                quickBtn.textContent = ok ? 'Đang phát' : 'Thử lại';
                if (ok) loadPopupContinueStrip();
                if (!ok) showFloatErrorHint('Không mở được phim. Chạy scripts/install.sh rồi tải lại extension.');
            } catch (err) {
                quickBtn.textContent = 'Thử lại';
                showFloatErrorHint(err?.message || 'Lỗi phát nổi');
            } finally {
                quickBtn.disabled = false;
                setTimeout(() => { if (quickBtn.textContent !== 'Đang phát') quickBtn.textContent = original; }, 1800);
            }
        });

        pickBtn.addEventListener('click', async (e) => {
            e.stopPropagation();
            if (!container.classList.contains('hidden')) {
                container.classList.add('hidden');
                pickBtn.textContent = 'Tập ▾';
                return;
            }

            // Close other open episode containers
            list.querySelectorAll('.popup-episodes-container').forEach(c => c.classList.add('hidden'));
            list.querySelectorAll('.ep-pick-btn').forEach(b => b.textContent = 'Tập ▾');

            pickBtn.textContent = '...';
            try {
                const detail = await MovieService.getDetail(slug, itemSource);
                renderPopupEpisodes(container, detail);
                container.classList.remove('hidden');
                pickBtn.textContent = 'Đóng ▲';
            } catch (err) {
                pickBtn.textContent = 'Thử lại';
            }
        });
    });
}

async function quickFloatMovie(slug, source) {
    const detail = await MovieService.getDetail(slug, source);
    if (!detail?.episodes?.length) return false;

    const servers = detail.episodes.filter(s => s.items?.length);
    if (!servers.length) return false;

    const continueList = await MovieService.getContinueWatching();
    const cont = continueList.find(c => c.slug === slug || c.name === detail.name);

    let server = servers[0];
    let ep = server.items[0];
    let serverIdx = MovieService.preferVietnameseServerIndex(servers);
    let epIdx = 0;
    server = servers[serverIdx] || servers[0];
    ep = server.items[0];

    if (cont && (cont.serverIdx != null || cont.epIdx != null || cont.epName || cont.epSlug)) {
        if (cont.serverIdx != null && servers[cont.serverIdx]?.items?.[cont.epIdx ?? 0]) {
            // Keep saved server unless dead
            serverIdx = Number(cont.serverIdx) || 0;
            epIdx = Number(cont.epIdx) || 0;
            server = servers[serverIdx];
            ep = server.items[epIdx];
        } else {
            // Saved server dead — locate episode, prefer VN audio among matches
            const wantName = cont.epName;
            const wantSlug = cont.epSlug;
            let best = null;
            for (let si = 0; si < servers.length; si++) {
                const matchIdx = servers[si].items.findIndex(item =>
                    (wantName && item.name === wantName) ||
                    (wantSlug && item.slug === wantSlug)
                );
                if (matchIdx >= 0) {
                    const rank = MovieService._serverAudioRank(servers[si]);
                    if (!best || rank < best.rank) best = { si, matchIdx, rank };
                }
            }
            if (best) {
                serverIdx = best.si;
                epIdx = best.matchIdx;
                server = servers[serverIdx];
                ep = server.items[epIdx];
            }
        }
    } else if (cont?.linkM3u8 || cont?.linkEmbed) {
        ep = {
            name: cont.epName || 'Tiếp tục',
            slug: cont.epSlug || '',
            linkM3u8: cont.linkM3u8 || '',
            linkEmbed: cont.linkEmbed || ''
        };
        const found = MovieService.findEpisodeIndices(detail, ep);
        serverIdx = found.serverIdx;
        epIdx = found.epIdx;
        if (found.servers[serverIdx]) server = found.servers[serverIdx];
    }

    // Live YouTube channels: float via youtube embed path, not movie HLS
    if ((detail.source === 'livetv' || slug?.startsWith('livetv-')) && (ep.pageUrl?.includes('youtube') || ep.linkEmbed?.includes('youtube'))) {
        const videoInfo = MovieService.buildYouTubeLiveFloatInfo({
            youtubeId: MovieService.extractYouTubeId(ep.pageUrl || ep.linkEmbed),
            streamUrl: ep.pageUrl,
            name: detail.name
        }, detail.name);
        const res = await chrome.runtime.sendMessage({
            type: 'FLOAT_VIDEO_REQUEST',
            videoInfo
        });
        if (res?.success) {
            setTimeout(() => window.close(), 300);
            return true;
        }
        showFloatErrorHint(formatFloatError(res));
        return false;
    }

    const movieContext = MovieService.buildMovieContext(detail, serverIdx, epIdx);
    const resumeAt = Number(cont?.currentTime) || 0;
    const srvTag = server.serverType === 'thuyetminh' ? ' [TM]' : (server.serverType === 'longtieng' ? ' [LT]' : '');
    const title = `${detail.name}${srvTag} — ${ep.name}`;
    const res = await chrome.runtime.sendMessage({
        type: 'FLOAT_VIDEO_REQUEST',
        videoInfo: {
            src: ep.linkM3u8 || '',
            embedUrl: ep.linkEmbed || '',
            title,
            site: 'movie',
            width: 640,
            height: 360,
            currentTime: resumeAt,
            movieContext
        }
    });
    if (res?.success) {
        await MovieService.saveContinueWatching(detail, ep, {
            currentTime: resumeAt,
            duration: Number(cont?.duration) || 0,
            serverIdx,
            epIdx
        });
        setTimeout(() => window.close(), 300);
        return true;
    }
    showFloatErrorHint(formatFloatError(res));
    return false;
}

function renderPopupEpisodes(container, movieDetail) {
    if (!movieDetail?.episodes?.length || !movieDetail.episodes.some(s => s.items?.length)) {
        container.innerHTML = '<div style="font-size: 11px; color: #888; padding: 6px;">Chưa có tập phim cho phim này.</div>';
        return;
    }

    const episodes = movieDetail.episodes.filter(s => s.items && s.items.length > 0);
    let activeServerIdx = MovieService.preferVietnameseServerIndex(episodes);

    // Render Server Tabs if multiple servers (e.g. Vietsub, Thuyết Minh, Lồng Tiếng)
    function updateServerView() {
        const srv = episodes[activeServerIdx];
        const serverTabsHtml = episodes.length > 1 ? `
            <div class="popup-server-tabs">
                ${episodes.map((s, idx) => `
                    <button class="popup-server-btn ${idx === activeServerIdx ? 'active' : ''}" data-sidx="${idx}">
                        ${escapeHtml(s.serverName)} (${s.items.length})
                    </button>
                `).join('')}
            </div>
        ` : '';

        const epButtonsHtml = `
            <div class="popup-episodes-dropdown">
                ${srv.items.map((ep, i) => `
                    <button class="popup-ep-btn" data-sidx="${activeServerIdx}" data-eidx="${i}" title="Phát nổi ${escapeAttr(ep.name)}">
                        ${escapeHtml(ep.name)}
                    </button>
                `).join('')}
            </div>
        `;

        container.innerHTML = serverTabsHtml + epButtonsHtml;

        // Bind server tabs
        container.querySelectorAll('.popup-server-btn').forEach(btn => {
            btn.addEventListener('click', (e) => {
                e.stopPropagation();
                activeServerIdx = parseInt(btn.dataset.sidx);
                updateServerView();
            });
        });

        // Bind episode buttons
        container.querySelectorAll('.popup-ep-btn').forEach(btn => {
            btn.addEventListener('click', async (e) => {
                e.stopPropagation();
                const sIdx = parseInt(btn.dataset.sidx);
                const eIdx = parseInt(btn.dataset.eidx);
                const curServer = episodes[sIdx];
                const ep = curServer.items[eIdx];

                const srvTag = curServer.serverType === 'thuyetminh' ? ' [TM]' : (curServer.serverType === 'longtieng' ? ' [LT]' : '');
                const title = `${movieDetail.name}${srvTag} — ${ep.name}`;
                const movieContext = MovieService.buildMovieContext(movieDetail, sIdx, eIdx);

                btn.textContent = 'Đang mở...';
                try {
                    const res = await chrome.runtime.sendMessage({
                        type: 'FLOAT_VIDEO_REQUEST',
                        videoInfo: {
                            src: ep.linkM3u8 || '',
                            embedUrl: ep.linkEmbed || '',
                            title: title,
                            site: 'movie',
                            width: 640,
                            height: 360,
                            currentTime: 0,
                            movieContext
                        }
                    });

                    if (res?.success) {
                        btn.textContent = 'Đang phát';
                        await MovieService.saveContinueWatching(movieDetail, ep, {
                            currentTime: 0,
                            duration: 0,
                            serverIdx: sIdx,
                            epIdx: eIdx
                        });
                        setTimeout(() => window.close(), 300);
                    } else {
                        btn.textContent = 'Thử lại';
                        showFloatErrorHint(formatFloatError(res));
                    }
                } catch (err) {
                    btn.textContent = 'Thử lại';
                    showFloatErrorHint(err?.message || 'Lỗi phát nổi');
                }
            });
        });
    }

    updateServerView();
}

// MARK: - Panel 3: TikTok Vietnam (Infinite Scroll PiP, No Hardcoded Channels)
function initTikTokPanel() {
    const input = document.getElementById('tiktok-url-input');
    const pasteBtn = document.getElementById('tiktok-paste-btn');
    const floatBtn = document.getElementById('tiktok-float-btn');
    const heroBtn = document.getElementById('tiktok-hero-launch-btn');
    const webBtn = document.getElementById('btn-open-tiktok-web');
    const topicBtns = document.querySelectorAll('.tiktok-topic-btn');

    // Hero Launch Button (For You VN with infinite scroll)
    heroBtn?.addEventListener('click', () => {
        floatTikTok('https://www.tiktok.com/foryou?lang=vi-VN', 'TikTok VN - Dành Cho Bạn');
    });

    // Paste button
    pasteBtn?.addEventListener('click', async () => {
        try {
            const text = await navigator.clipboard.readText();
            if (text && input) {
                input.value = text.trim();
                input.focus();
            }
        } catch {
            input?.focus();
            input?.select();
        }
    });

    // Float button
    floatBtn?.addEventListener('click', () => {
        if (input && input.value) {
            floatTikTok(input.value);
        } else {
            input?.focus();
        }
    });

    // Enter key in input
    input?.addEventListener('keydown', (e) => {
        if (e.key === 'Enter') {
            floatTikTok(input.value);
        }
    });

    // Topic Pills
    topicBtns.forEach(btn => {
        btn.addEventListener('click', () => {
            topicBtns.forEach(b => b.classList.remove('active'));
            btn.classList.add('active');
            const url = btn.dataset.url;
            const label = btn.textContent;
            floatTikTok(url, `TikTok VN - ${label}`);
        });
    });

    // Open Web Tab
    webBtn?.addEventListener('click', () => {
        chrome.tabs.create({ url: 'https://www.tiktok.com/foryou?lang=vi-VN' });
    });
}

async function floatTikTok(rawUrl, defaultTitle = 'TikTok Việt Nam') {
    if (!rawUrl || !rawUrl.trim()) return;
    let url = rawUrl.trim();

    if (!url.startsWith('http://') && !url.startsWith('https://')) {
        if (url.startsWith('@')) {
            url = 'https://www.tiktok.com/' + url;
        } else if (/^\d+$/.test(url)) {
            url = `https://www.tiktok.com/player/v1/${url}`;
        } else {
            url = 'https://' + url;
        }
    }

    let embedUrl = '';
    const videoIdMatch = url.match(/\/video\/(\d+)/) || url.match(/\/v1\/(\d+)/);
    if (videoIdMatch) {
        embedUrl = `https://www.tiktok.com/player/v1/${videoIdMatch[1]}`;
    }

    const floatBtn = document.getElementById('tiktok-float-btn');
    const heroBtn = document.getElementById('tiktok-hero-launch-btn');
    if (floatBtn) {
        floatBtn.disabled = true;
        floatBtn.textContent = 'Đang mở...';
    }
    if (heroBtn) {
        heroBtn.disabled = true;
        heroBtn.textContent = 'Đang khởi động...';
    }

    try {
        const resp = await chrome.runtime.sendMessage({
            type: 'FLOAT_VIDEO_REQUEST',
            videoInfo: {
                pageUrl: url,
                embedUrl: embedUrl,
                title: defaultTitle,
                site: 'tiktok',
                width: 340,
                height: 604,
                currentTime: 0,
            }
        });

        if (resp && resp.success) {
            if (floatBtn) floatBtn.textContent = 'Đang phát';
            if (heroBtn) heroBtn.textContent = 'Đang phát';
            setTimeout(() => window.close(), 300);
        } else {
            if (floatBtn) {
                floatBtn.disabled = false;
                floatBtn.textContent = 'Thử lại';
                setTimeout(() => { floatBtn.textContent = 'Phát PiP'; }, 1500);
            }
            if (heroBtn) {
                heroBtn.disabled = false;
                heroBtn.textContent = 'Phát Nổi Ngay';
            }
            showFloatErrorHint(formatFloatError(resp));
        }
    } catch (e) {
        console.error('Failed to float TikTok:', e);
        if (floatBtn) {
            floatBtn.disabled = false;
            floatBtn.textContent = 'Thử lại';
            setTimeout(() => { floatBtn.textContent = 'Phát PiP'; }, 1500);
        }
        if (heroBtn) {
            heroBtn.disabled = false;
            heroBtn.textContent = 'Phát Nổi Ngay';
        }
        showFloatErrorHint(e?.message || 'Không mở được TikTok nổi.');
    }
}

// MARK: - Panel 4: Recent / Continue Watching
function initRecentPanel() {
    const clearBtn = document.getElementById('btn-clear-recent');
    if (clearBtn) {
        clearBtn.addEventListener('click', async () => {
            if (confirm('Bạn có chắc muốn xóa lịch sử xem gần đây?')) {
                if (typeof chrome !== 'undefined' && chrome.storage?.local) {
                    await chrome.storage.local.set({ vibe_continue_watching: [] });
                } else {
                    localStorage.removeItem('vibe_continue_watching');
                }
                renderRecentPanel();
            }
        });
    }
}

async function renderRecentPanel() {
    const list = document.getElementById('recent-list');
    const items = await MovieService.getContinueWatching();

    if (!items || items.length === 0) {
        list.innerHTML = '<div class="empty-recent">Chưa có phim xem gần đây.<br><span style="font-size:10.5px;color:#888;">Chọn một tập phim ở tab "Kho Phim" để phát nổi!</span></div>';
        return;
    }

    list.innerHTML = items.map((item, idx) => {
        const pct = MovieService.progressPercent(item);
        const progressHtml = pct > 0
            ? `<div class="recent-progress"><div class="recent-progress-bar" style="width:${pct}%"></div></div>`
            : '';
        return `
        <div class="recent-item" data-idx="${idx}">
            <img class="recent-thumb" ${MovieImages.attr(item, 'thumb')} width="36" height="50" alt="">
            <div class="recent-info">
                <div class="recent-name" title="${escapeAttr(item.name)}">${escapeHtml(item.name)}</div>
                <div class="recent-ep">${escapeHtml(item.epName || 'Tập 1')}</div>
                ${progressHtml}
            </div>
            <button class="float-btn recent-play-btn" data-idx="${idx}">
                Tiếp tục
            </button>
        </div>
    `;
    }).join('');

    list.querySelectorAll('.recent-play-btn').forEach(btn => {
        btn.addEventListener('click', async (e) => {
            const idx = parseInt(btn.dataset.idx);
            const item = items[idx];
            btn.textContent = 'Đang mở...';
            try {
                const ok = await floatContinueItem(item);
                btn.textContent = ok ? 'Đang phát' : 'Thử lại';
            } catch (err) {
                btn.textContent = 'Thử lại';
                showFloatErrorHint(err?.message || 'Lỗi tiếp tục xem');
            }
        });
    });
}

/** Resume from Lịch sử / continue entry with playlist + seek. */
async function floatContinueItem(item) {
    if (!item) return false;
    let detail = null;
    try {
        detail = await MovieService.getDetail(item.slug, item.source || 'kkphim');
    } catch (e) {
        console.warn('[popup] detail fetch for continue failed:', e);
    }

    let movieContext = null;
    let serverIdx = Number(item.serverIdx) || 0;
    let epIdx = Number(item.epIdx) || 0;
    let ep = {
        name: item.epName || 'Tập 1',
        slug: item.epSlug || '',
        linkM3u8: item.linkM3u8 || '',
        linkEmbed: item.linkEmbed || ''
    };

    if (detail?.episodes?.length) {
        const servers = detail.episodes.filter(s => s.items?.length);
        // Keep saved serverIdx unless that server is dead
        if (item.serverIdx != null && servers[serverIdx]?.items?.[epIdx]) {
            ep = servers[serverIdx].items[epIdx] || ep;
            movieContext = MovieService.buildMovieContext(detail, serverIdx, epIdx);
        } else {
            const found = MovieService.findEpisodeIndices(detail, ep);
            if (found.servers.length) {
                serverIdx = found.serverIdx;
                epIdx = found.epIdx;
                ep = found.servers[serverIdx].items[epIdx] || ep;
                movieContext = MovieService.buildMovieContext(detail, serverIdx, epIdx);
            }
        }
    }

    const title = `${item.name} — ${ep.name || item.epName}`;
    const resumeAt = Number(item.currentTime) || 0;
    const res = await chrome.runtime.sendMessage({
        type: 'FLOAT_VIDEO_REQUEST',
        videoInfo: {
            src: ep.linkM3u8 || item.linkM3u8 || '',
            embedUrl: ep.linkEmbed || item.linkEmbed || '',
            title,
            site: 'movie',
            width: 640,
            height: 360,
            currentTime: resumeAt,
            movieContext
        }
    });

    if (res?.success) {
        if (detail) {
            await MovieService.saveContinueWatching(detail, ep, {
                currentTime: resumeAt,
                duration: Number(item.duration) || 0,
                serverIdx,
                epIdx
            });
        }
        setTimeout(() => window.close(), 300);
        return true;
    }
    showFloatErrorHint(formatFloatError(res));
    return false;
}

// MARK: - Helpers
function formatFloatError(res) {
    const err = (res && res.error) ? String(res.error) : 'Không thể mở cửa sổ nổi';
    if (/not connected|install\.sh/i.test(err)) {
        return `${err} — Chạy scripts/install.sh rồi tải lại extension.`;
    }
    if (/Already opening/i.test(err)) {
        return 'Đang mở cửa sổ khác — đợi giây lát rồi thử lại.';
    }
    if (/timeout/i.test(err)) {
        return `${err} — Tải lại extension hoặc chạy lại install.sh.`;
    }
    return err;
}

function showFloatErrorHint(message) {
    const panels = [
        document.getElementById('panel-movies'),
        document.getElementById('panel-recent'),
        document.getElementById('panel-tiktok'),
        document.getElementById('panel-web')
    ];
    const active = panels.find(p => p?.classList.contains('active')) || panels[0];
    if (!active) return;
    let hint = active.querySelector('.float-error-hint');
    if (!hint) {
        hint = document.createElement('div');
        hint.className = 'float-error-hint';
        active.prepend(hint);
    }
    hint.textContent = message;
    clearTimeout(hint._hideTimer);
    hint._hideTimer = setTimeout(() => hint.remove(), 6000);
}

async function capturePlayerPrefs(tabId, site) {
    if (site !== 'youtube') return null;
    try {
        const [res] = await chrome.scripting.executeScript({
            target: { tabId },
            world: 'MAIN',
            func: () => {
                const out = { localStorage: {}, captionTrack: null, playbackRate: 1 };
                try {
                    for (let i = 0; i < localStorage.length; i++) {
                        const k = localStorage.key(i);
                        if (k && k.indexOf('yt-player-') === 0) {
                            out.localStorage[k] = localStorage.getItem(k);
                        }
                    }
                } catch (e) {}
                try {
                    const p = document.getElementById('movie_player');
                    if (p && typeof p.getOption === 'function') {
                        const t = p.getOption('captions', 'track');
                        if (t && t.languageCode) {
                            out.captionTrack = { languageCode: t.languageCode };
                            if (t.kind) out.captionTrack.kind = t.kind;
                        }
                    }
                    if (p && typeof p.getPlaybackRate === 'function') {
                        out.playbackRate = p.getPlaybackRate();
                    }
                } catch (e) {}
                return out;
            },
        });
        return res?.result || null;
    } catch (e) {
        return null;
    }
}

function escapeHtml(text) {
    const div = document.createElement('div');
    div.textContent = text || '';
    return div.innerHTML;
}

function escapeAttr(text) {
    return (text || '').replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

function formatDuration(seconds) {
    if (!seconds || isNaN(seconds) || !isFinite(seconds)) return '--:--';
    const h = Math.floor(seconds / 3600);
    const m = Math.floor((seconds % 3600) / 60);
    const s = Math.floor(seconds % 60);
    if (h > 0) {
        return `${h}:${m.toString().padStart(2, '0')}:${s.toString().padStart(2, '0')}`;
    }
    return `${m}:${s.toString().padStart(2, '0')}`;
}
