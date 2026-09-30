// popup.js — Popup panel logic with Web Video Detection & VibeWatch Cinema Movie Hub (No Emojis, Clean UI/UX)

let popupMovieSource = 'all';
let popupCategory = 'hot';

document.addEventListener('DOMContentLoaded', async () => {
    MovieImages.install(document);
    initMoviePanel();
    renderPopupYouTubeMovies();
    initNativeStatus();
    await initPopupControls();
});

async function initNativeStatus() {
    await NativeStatus.init()?.check();
}

// MARK: - Movie popup controls
async function initPopupControls() {
    loadPopupContinueStrip();
    loadPopupMovies();
    document.getElementById('btn-open-catalog')?.addEventListener('click', openMovieCatalog);

    // Ghost Mode Quick Toggle — sync real native state
    const ghostBtn = document.getElementById('popup-ghost-btn');
    let isGhost = false;
    const syncGhostBtn = (on) => {
        isGhost = !!on;
        ghostBtn?.classList.toggle('active', isGhost);
        if (ghostBtn) {
            ghostBtn.querySelector('.ghost-state').textContent = isGhost ? 'Bật' : 'Tắt';
            ghostBtn.setAttribute('aria-label', `Xuyên chuột: ${isGhost ? 'Bật' : 'Tắt'}`);
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
        ghostBtn.disabled = true;
        try {
            const res = await chrome.runtime.sendMessage({
                type: 'NATIVE_COMMAND',
                action: 'toggleGhost'
            });
            if (typeof res?.isGhost === 'boolean') {
                syncGhostBtn(res.isGhost);
            } else if (res?.success) {
                syncGhostBtn(!isGhost);
            } else {
                showFloatErrorHint(formatFloatError(res));
            }
        } catch (e) {
            showFloatErrorHint(e?.message || 'Không đổi được chế độ xuyên chuột.');
        } finally {
            ghostBtn.disabled = false;
        }
    });

    // AI Dubbing Quick Toggle — sync storage and native state
    const aidubBtn = document.getElementById('popup-aidub-btn');
    let isAIDub = false;
    const syncAIDubBtn = (on) => {
        isAIDub = !!on;
        aidubBtn?.classList.toggle('active', isAIDub);
        if (aidubBtn) {
            const stateEl = aidubBtn.querySelector('.aidub-state');
            if (stateEl) stateEl.textContent = isAIDub ? 'Bật' : 'Tắt';
            aidubBtn.setAttribute('aria-label', `Lồng tiếng AI: ${isAIDub ? 'Bật' : 'Tắt'}`);
            aidubBtn.setAttribute('aria-pressed', isAIDub ? 'true' : 'false');
        }
    };

    chrome.storage.local.get('vibe_ai_dubbing_enabled_v2').then((data) => {
        if (data.vibe_ai_dubbing_enabled_v2 != null) syncAIDubBtn(data.vibe_ai_dubbing_enabled_v2);
        else syncAIDubBtn(false);
    }).catch(() => syncAIDubBtn(false));

    chrome.runtime.sendMessage({ type: 'GET_NATIVE_STATUS' }).then((res) => {
        if (typeof res?.isAIDubEnabled === 'boolean') syncAIDubBtn(res.isAIDubEnabled);
    }).catch(() => {});

    aidubBtn?.addEventListener('click', async () => {
        aidubBtn.disabled = true;
        try {
            const nextState = !isAIDub;
            const native = await chrome.runtime.sendMessage({ type: 'NATIVE_COMMAND', action: 'toggleAIDub' });
            const noNativeWindow = /No active window|Not connected/i.test(native?.error || '');
            if (!native?.success && !noNativeWindow) {
                throw new Error(formatFloatError(native));
            }
            if (native?.success && typeof native.isAIDubEnabled === 'boolean' && native.isAIDubEnabled !== nextState) {
                throw new Error('Chế độ lồng tiếng trong cửa sổ nổi chưa đổi. Thử lại trong thanh điều khiển video.');
            }
            await chrome.storage.local.set({ 'vibe_ai_dubbing_enabled_v2': nextState });
            syncAIDubBtn(nextState);
            if (!native?.success) showFloatErrorHint('Đã lưu cho tab Chrome. Mở video nổi để dùng lồng tiếng trong App.');

            // Notify active tab content script
            const [tab] = await chrome.tabs.query({ active: true, currentWindow: true }).catch(() => []);
            if (tab?.id) {
                await chrome.tabs.sendMessage(tab.id, { type: 'TOGGLE_AI_DUB', enabled: nextState }).catch(() => {});
            }
        } catch (e) {
            showFloatErrorHint(e?.message || 'Không đổi được lồng tiếng AI. Thử lại.');
        } finally {
            aidubBtn.disabled = false;
        }
    });

}

/** Float curated Lofi/Synthwave via YouTube embed (not the watch-page bot wall). */

// MARK: - Panel 1: Web Video Detection (Original FullFloatPiP)

// MARK: - Panel 2: Movie Hub (VibeWatch Cinema style)
function openMovieCatalog() {
    chrome.tabs.create({ url: chrome.runtime.getURL('catalog.html') });
}

function initMoviePanel() {
    document.getElementById('popup-source-select')?.addEventListener('change', (event) => {
        popupMovieSource = event.target.value;
        loadPopupMovies();
    });
    document.getElementById('popup-refresh-hot')?.addEventListener('click', () => loadPopupMovies());
    document.getElementById('popup-open-continue-catalog')?.addEventListener('click', openMovieCatalog);
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
    rail.innerHTML = items.slice(0, 2).map((item, idx) => {
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

function renderPopupYouTubeMovies() {
    const list = document.getElementById('popup-youtube-list');
    if (!list) return;
    const search = document.getElementById('popup-youtube-search');
    const filter = document.getElementById('popup-youtube-filter');
    const movies = MovieService.getYouTubeMovies(search?.value || '', filter?.value || 'all');
    const count = document.getElementById('popup-youtube-count');
    if (count) count.textContent = `${movies.length} phim · Năm hiển thị là năm phim ra mắt`;
    if (search && !search.dataset.wired) {
        search.dataset.wired = '1';
        search.addEventListener('input', renderPopupYouTubeMovies);
    }
    if (filter && !filter.dataset.wired) {
        filter.dataset.wired = '1';
        filter.addEventListener('change', renderPopupYouTubeMovies);
    }
    list.innerHTML = movies.map((movie, index) => `
        <div class="popup-movie-item">
            <img class="popup-movie-thumb" src="${escapeAttr(movie.thumb)}" width="40" height="56" alt="" loading="lazy" referrerpolicy="no-referrer">
            <div class="popup-movie-details">
                <div class="popup-movie-name">${escapeHtml(movie.name)}</div>
                <div class="popup-movie-sub">${movie.year} · ${escapeHtml(movie.region)} · ${escapeHtml(movie.audio)}</div>
                <div class="popup-movie-sub">${escapeHtml(movie.cast)}</div>
                <div class="popup-movie-sub">${escapeHtml(movie.channel)} · ${movie.durationMinutes} phút</div>
            </div>
            <div class="popup-movie-actions">
                <button type="button" class="float-btn" data-youtube-movie="${index}">Phát nổi</button>
                <a class="youtube-movie-link" href="${escapeAttr(movie.url)}" target="_blank" rel="noopener noreferrer">YouTube ↗</a>
            </div>
        </div>
    `).join('') || '<p class="popup-playback-hint">Không có phim khớp. Thử tên khác hoặc chọn Tất cả.</p>';
    list.querySelectorAll('[data-youtube-movie]').forEach(button => {
        button.addEventListener('click', async () => {
            button.disabled = true;
            button.textContent = 'Đang mở…';
            try {
                const result = await chrome.runtime.sendMessage({
                    type: 'FLOAT_VIDEO_REQUEST',
                    videoInfo: MovieService.buildYouTubeMovieFloatInfo(movies[Number(button.dataset.youtubeMovie)])
                });
                if (!result?.success) throw new Error(formatFloatError(result));
                button.textContent = 'Đang phát';
            } catch (error) {
                button.textContent = 'Thử lại';
                showFloatErrorHint(`${error.message} Có thể mở link YouTube bên cạnh.`);
            } finally {
                button.disabled = false;
            }
        });
    });
}

let popupMovieRequest = 0;
async function loadPopupMovies(keyword = '') {
    const request = ++popupMovieRequest;
    const list = document.getElementById('popup-movie-list');
    list.innerHTML = '<div class="loading"><div class="spinner"></div><span>Đang tải danh sách phim...</span></div>';
    const refresh = document.getElementById('popup-refresh-hot');
    if (refresh) refresh.disabled = true;
    document.getElementById('popup-hot-status').textContent = popupCategory === 'hot' && !keyword
        ? 'Đang lấy phim hot…' : 'Danh sách phim';

    try {
        let items = [];
        if (keyword) {
            items = await MovieService.search(keyword, popupMovieSource);
        } else if (popupCategory === 'hot') {
            const hot = await MovieService.getPopupHotMovies(8, popupMovieSource);
            items = hot.items;
            if (request === popupMovieRequest) {
                document.getElementById('popup-hot-status').textContent = hot.stale
                    ? (hot.items.length ? 'Nguồn phim đang lỗi · Danh sách đã lưu' : 'Chưa tải được phim · Bấm Làm mới để thử lại')
                    : 'Gợi ý từ phim mới, chiếu rạp và điểm đánh giá';
            }
        } else if (popupCategory === 'favorites') {
            items = await MovieService.getFavorites();
        } else {
            items = await MovieService.getLatest(popupMovieSource, popupCategory, 1);
        }

        if (request === popupMovieRequest) renderPopupMovies(items.slice(0, keyword || popupCategory === 'hot' ? 8 : 5));
    } catch (err) {
        if (request !== popupMovieRequest) return;
        console.error('Failed to load popup movies:', err);
        list.innerHTML = `<div class="empty" role="alert">Lỗi tải phim từ nguồn ${escapeHtml(popupMovieSource.toUpperCase())}. Hãy thử chọn nguồn khác.</div>`;
    } finally {
        if (request === popupMovieRequest && refresh) refresh.disabled = false;
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
                        <button class="float-btn ep-pick-btn" title="Chọn tập và bản phát">Chọn tập ▾</button>
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
            quickBtn.textContent = 'Đang mở…';
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
                pickBtn.textContent = 'Chọn tập ▾';
                return;
            }

            // Close other open episode containers
            list.querySelectorAll('.popup-episodes-container').forEach(c => c.classList.add('hidden'));
            list.querySelectorAll('.ep-pick-btn').forEach(b => b.textContent = 'Chọn tập ▾');

            pickBtn.textContent = 'Đang tải…';
            pickBtn.disabled = true;
            try {
                const detail = await MovieService.getDetail(slug, itemSource);
                renderPopupEpisodes(container, detail);
                container.classList.remove('hidden');
                pickBtn.textContent = 'Thu gọn ▲';
            } catch (err) {
                pickBtn.textContent = 'Thử lại';
                showFloatErrorHint('Không tải được danh sách tập. Kiểm tra mạng rồi thử lại.');
            } finally {
                pickBtn.disabled = false;
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
        document.getElementById('panel-web')
    ];
    const active = panels.find(p => p?.classList.contains('active')) || panels[0];
    if (!active) return;
    let hint = active.querySelector('.float-error-hint');
    if (!hint) {
        hint = document.createElement('div');
        hint.className = 'float-error-hint';
        hint.setAttribute('role', 'alert');
        const videoList = active.id === 'panel-web' ? document.getElementById('video-list') : null;
        if (videoList) videoList.after(hint);
        else active.prepend(hint);
    }
    hint.textContent = message;
    clearTimeout(hint._hideTimer);
    hint._hideTimer = setTimeout(() => hint.remove(), 6000);
}

function escapeHtml(text) {
    const div = document.createElement('div');
    div.textContent = text || '';
    return div.innerHTML;
}

function escapeAttr(text) {
    return (text || '').replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}
