// catalog.js — Controller for VibeWatch Cinema dashboard
// Netflix-style browse → decide → watch → continue (VN labels, dark cinema)

let currentSource = 'all';
let currentCategory = 'moi';
let currentGenre = '';
let currentCountry = '';
let currentAudioFilter = 'all';
let currentViewMode = 'view-poster'; // 'view-poster' or 'view-cinema'
let currentSearchKeyword = '';
let currentMovie = null;
let currentSpotlightMovie = null;

let heroSpotlights = [];
let heroSpotlightIndex = 0;
let heroRotationTimer = null;
let isHeroHovered = false;
let homeRailResizeObserver = null;
let favSlugSet = new Set();
let suggestActiveIdx = -1;
let activeDialog = null;
let dialogReturnFocus = null;

function setDialogOpen(dialog, open) {
    if (!dialog) return;
    if (open) {
        if (activeDialog === dialog) return;
        if (activeDialog && activeDialog !== dialog) setDialogOpen(activeDialog, false);
        dialogReturnFocus = document.activeElement;
        activeDialog = dialog;
        dialog.classList.remove('hidden');
        for (const child of document.querySelector('.app-container').children) {
            if (child !== dialog) child.inert = true;
        }
        (dialog.querySelector('[autofocus]') || dialog.querySelector('button, input'))?.focus();
    } else {
        dialog.classList.add('hidden');
        for (const child of document.querySelector('.app-container').children) child.inert = false;
        activeDialog = null;
        dialogReturnFocus?.focus();
        dialogReturnFocus = null;
    }
}

function setOptionalText(id, value) {
    const element = document.getElementById(id);
    if (!element) return;
    element.textContent = value || '';
    element.hidden = !value;
}


const PLAY_ICON_SVG = `<svg width="18" height="18" viewBox="0 0 24 24" fill="currentColor"><polygon points="6,4 20,12 6,20"/></svg>`;
const LIST_ICON_SVG = `<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"><path d="M12 5v14M5 12h14"/></svg>`;
const LIST_CHECK_SVG = `<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"><polyline points="20 6 9 17 4 12"/></svg>`;
const INFO_BTN_SVG = `<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><line x1="12" y1="16" x2="12" y2="12"/><line x1="12" y1="8" x2="12.01" y2="8"/></svg>`;

document.addEventListener('DOMContentLoaded', async () => {
    if (typeof MovieImages !== 'undefined') MovieImages.install(document);
    favSlugSet = await MovieService.getFavoriteSlugSet();
    initUI();
    loadContinueWatching();
    navigateView();
});

async function refreshFavSet() {
    favSlugSet = await MovieService.getFavoriteSlugSet();
}

function setListButtonState(btn, inList) {
    if (!btn) return;
    btn.classList.toggle('is-listed', !!inList);
    btn.setAttribute('aria-pressed', inList ? 'true' : 'false');
    if (btn.id === 'hero-fav-btn' || btn.id === 'modal-fav-btn') {
        btn.textContent = inList ? 'Trong danh sách' : '+ Danh sách';
        btn.title = inList ? 'Bỏ khỏi danh sách của tôi' : 'Thêm vào danh sách của tôi';
    } else {
        btn.innerHTML = inList ? LIST_CHECK_SVG : LIST_ICON_SVG;
        btn.title = inList ? 'Bỏ khỏi danh sách' : 'Thêm vào danh sách';
        const title = btn.closest('.movie-card')?.querySelector('.movie-title')?.textContent || 'phim';
        btn.setAttribute('aria-label', `${inList ? 'Bỏ' : 'Thêm'} ${title} ${inList ? 'khỏi' : 'vào'} danh sách`);
    }
}

// MARK: - Navigation View Router
function navigateView() {
    homeLoadSeq++;
    const homeView = document.getElementById('home-view');
    const gridView = document.getElementById('grid-view');
    const heroSpotlight = document.getElementById('hero-spotlight');

    if (currentSearchKeyword) {
        // Search View
        stopHeroRotation();
        homeView?.classList.add('hidden');
        gridView?.classList.remove('hidden');
        heroSpotlight?.classList.add('hidden');
        searchMovies(currentSearchKeyword);
    } else if (currentCategory === 'moi' && !currentGenre && !currentCountry && !isDubbedSource()) {
        // Home View with Multi-Sections
        homeView?.classList.remove('hidden');
        gridView?.classList.add('hidden');
        loadHomePage();
    } else {
        // Specific Category / Filter / Favorites View
        stopHeroRotation();
        homeView?.classList.add('hidden');
        gridView?.classList.remove('hidden');
        heroSpotlight?.classList.add('hidden');

        if (currentCategory === 'favorites') {
            loadFavorites();
        } else {
            loadMovies();
        }
    }
}

// MARK: - UI Initialization
// MARK: - Keyboard navigation between cards

/**
 * The card to move to for an arrow key, like a TV remote: left/right walk the row (a rail or
 * the grid in reading order), up/down jump to the nearest row above or below and land on the
 * card closest in horizontal position. Home/End go to the ends of the row.
 */
function pickNeighbourCard(current, key, cards) {
    const row = cards.filter(card => card.parentElement === current.parentElement);
    const index = row.indexOf(current);
    if (key === 'ArrowRight') return row[index + 1] || null;
    if (key === 'ArrowLeft') return row[index - 1] || null;
    if (key === 'Home') return row[0] !== current ? row[0] : null;
    if (key === 'End') return row[row.length - 1] !== current ? row[row.length - 1] : null;
    const rect = current.getBoundingClientRect();
    const centreX = rect.left + rect.width / 2;
    const centreY = rect.top + rect.height / 2;
    const direction = key === 'ArrowDown' ? 1 : -1;
    const others = cards.filter(card => card !== current).map(card => {
        const box = card.getBoundingClientRect();
        return { card, away: (box.top + box.height / 2 - centreY) * direction, offset: Math.abs(box.left + box.width / 2 - centreX) };
    }).filter(entry => entry.away > rect.height / 2);
    if (!others.length) return null;
    const nearest = Math.min(...others.map(entry => entry.away));
    // Cards in the same visual row differ by far less than half a card height.
    const sameRow = others.filter(entry => entry.away - nearest < rect.height / 2);
    sameRow.sort((a, b) => a.offset - b.offset);
    return sameRow[0].card;
}

/** One Tab stop per rail or grid; the arrow keys move within it. */
function ensureRovingTab(root) {
    if (!root) return;
    const groups = root.matches?.('.home-section-rail, #movie-grid') ? [root] : [...root.querySelectorAll('.home-section-rail, #movie-grid')];
    groups.forEach(group => {
        const cards = [...group.querySelectorAll(':scope > .movie-card')];
        if (!cards.length) return;
        const stop = cards.find(card => card.getAttribute('tabindex') === '0') || cards[0];
        cards.forEach(card => card.setAttribute('tabindex', card === stop ? '0' : '-1'));
    });
}

function installCardKeyboardNav() {
    const keys = ['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown', 'Home', 'End'];
    document.addEventListener('keydown', event => {
        if (!keys.includes(event.key) || event.altKey || event.ctrlKey || event.metaKey || event.shiftKey || activeDialog) return;
        const current = document.activeElement;
        if (!current || !current.classList?.contains('movie-card')) return;
        const cards = [...document.querySelectorAll('#home-view:not(.hidden) .movie-card, #grid-view:not(.hidden) .movie-card')];
        const next = pickNeighbourCard(current, event.key, cards);
        if (!next) return;
        event.preventDefault();
        next.focus({ preventScroll: true });
        next.scrollIntoView({ block: 'nearest', inline: 'nearest', behavior: 'smooth' });
    });
    // Whatever card the reader lands on (arrow, click or Tab) becomes its row's Tab stop.
    document.addEventListener('focusin', event => {
        const card = event.target;
        if (!card.classList?.contains('movie-card') || !card.parentElement) return;
        card.parentElement.querySelectorAll(':scope > .movie-card[tabindex="0"]').forEach(other => {
            if (other !== card) other.setAttribute('tabindex', '-1');
        });
        card.setAttribute('tabindex', '0');
    });
}

// MARK: - Hover preview (the card grows into a small preview, like a streaming home screen)

const PREVIEW_DWELL_MS = 450;
const PREVIEW_SWITCH_MS = 140;
const previewDetails = new Map();   // "source:slug" -> detail promise, so each title is fetched once

/** Where the preview goes: centred on the card, kept inside the window and below the header. */
function placePreview(card, view, height, headerHeight = 70) {
    const margin = 12;
    const width = Math.round(Math.min(Math.max(card.width * 1.35, 300), 360));
    const left = Math.round(Math.max(margin, Math.min(card.left + card.width / 2 - width / 2, view.width - width - margin)));
    const wanted = card.top - 24;
    const top = Math.round(Math.max(headerHeight, Math.min(wanted, view.height - height - margin)));
    return { left, top, width };
}

function previewDetail(slug, source) {
    const key = `${source}:${slug}`;
    if (!previewDetails.has(key)) {
        previewDetails.set(key, MovieService.getDetail(slug, source).catch(() => null));
        if (previewDetails.size > 60) previewDetails.delete(previewDetails.keys().next().value);
    }
    return previewDetails.get(key);
}

function installHoverPreview() {
    const canHover = () => window.matchMedia('(hover: hover) and (pointer: fine)').matches && window.innerWidth >= 900;
    let panel = null, current = null, timer = null, leaveTimer = null, token = 0;

    const build = () => {
        panel = document.createElement('div');
        panel.id = 'hover-preview';
        panel.className = 'hover-preview';
        // A pointer-only extra: everything it does is also on the card itself, so it stays out of the tab order.
        panel.setAttribute('aria-hidden', 'true');
        panel.innerHTML = `
            <div class="hp-media"><img class="hp-img" alt="" referrerpolicy="no-referrer"><div class="card-badges-top hp-badges"></div><span class="hp-ep" hidden></span></div>
            <div class="hp-body">
                <div class="hp-actions">
                    <button type="button" class="hp-btn hp-play" tabindex="-1">${PLAY_ICON_SVG}</button>
                    <button type="button" class="hp-btn hp-list" tabindex="-1"></button>
                    <button type="button" class="hp-btn hp-info" tabindex="-1">${INFO_BTN_SVG}</button>
                </div>
                <div class="hp-title"></div>
                <div class="hp-origin"></div>
                <div class="hp-meta"></div>
                <div class="hp-genres"></div>
                <p class="hp-desc"></p>
            </div>`;
        document.body.appendChild(panel);
        panel.addEventListener('mouseenter', () => clearTimeout(leaveTimer));
        panel.addEventListener('mouseleave', () => scheduleHide());
        panel.addEventListener('click', event => {
            if (!current) return;
            const card = current;
            const press = selector => card.querySelector(selector)?.click();
            if (event.target.closest('.hp-play')) { hide(); press('.card-quick-float'); }
            else if (event.target.closest('.hp-list')) { press('.card-mylist-btn'); syncList(card); }
            else { hide(); press('.card-info-btn'); }
        });
        window.addEventListener('scroll', hide, { passive: true, capture: true });
        window.addEventListener('blur', hide);
        document.addEventListener('keydown', hide);
    };

    const syncList = card => {
        const listed = card.querySelector('.card-mylist-btn')?.classList.contains('is-listed');
        const button = panel.querySelector('.hp-list');
        button.innerHTML = listed ? LIST_CHECK_SVG : LIST_ICON_SVG;
        button.classList.toggle('is-listed', !!listed);
        button.setAttribute('title', listed ? 'Bỏ khỏi danh sách' : 'Thêm vào danh sách');
    };

    const fill = (card) => {
        const text = selector => card.querySelector(selector)?.textContent.trim() || '';
        const image = card.querySelector('img.movie-poster');
        panel.querySelector('.hp-img').src = image ? (image.currentSrc || image.src) : '';
        panel.querySelector('.hp-badges').innerHTML = card.querySelector('.card-badges-top')?.innerHTML || '';
        const episode = text('.card-ep-badge');
        const episodeEl = panel.querySelector('.hp-ep');
        episodeEl.hidden = !episode;
        episodeEl.textContent = episode;
        panel.querySelector('.hp-title').textContent = text('.movie-title');
        panel.querySelector('.hp-origin').textContent = text('.movie-origin');
        const meta = [];
        const rating = text('.card-badge-rating');
        if (rating) meta.push(`<span class="hp-rating">★ ${escapeHtml(rating)}</span>`);
        const year = text('.movie-footer span');
        if (year) meta.push(`<span>${escapeHtml(year.replace(/^Năm\s*/, ''))}</span>`);
        const quality = text('.card-hd');
        if (quality) meta.push(`<span class="hp-quality">${escapeHtml(quality)}</span>`);
        panel.querySelector('.hp-meta').innerHTML = meta.join('');
        panel.querySelector('.hp-genres').textContent = '';
        panel.querySelector('.hp-desc').textContent = '';
        panel.querySelector('.hp-desc').classList.add('hp-loading');
        panel.querySelector('.hp-play').setAttribute('title', 'Phát nổi');
        panel.querySelector('.hp-info').setAttribute('title', 'Chi tiết phim');
        syncList(card);
    };

    const place = card => {
        const rect = card.getBoundingClientRect();
        const spot = placePreview(rect, { width: window.innerWidth, height: window.innerHeight }, panel.offsetHeight || 340,
            document.querySelector('.navbar')?.getBoundingClientRect().bottom || 70);
        panel.style.width = `${spot.width}px`;
        panel.style.left = `${spot.left}px`;
        panel.style.top = `${spot.top}px`;
        const height = panel.offsetHeight;
        const again = placePreview(rect, { width: window.innerWidth, height: window.innerHeight }, height,
            document.querySelector('.navbar')?.getBoundingClientRect().bottom || 70);
        panel.style.top = `${again.top}px`;
        panel.style.transformOrigin = `${Math.round(rect.left + rect.width / 2 - again.left)}px ${Math.round(rect.top + rect.height / 2 - again.top)}px`;
    };

    const show = async card => {
        if (!canHover() || activeDialog || !card.isConnected) return;
        if (!panel) build();
        current = card;
        const mine = ++token;
        fill(card);
        panel.classList.remove('is-open');
        place(card);
        requestAnimationFrame(() => { if (mine === token) panel.classList.add('is-open'); });

        const detail = await previewDetail(card.dataset.slug, card.dataset.source || currentSource);
        if (mine !== token || !detail) { if (mine === token) panel.querySelector('.hp-desc').classList.remove('hp-loading'); return; }
        const description = (detail.description || '').slice(0, 220);
        panel.querySelector('.hp-desc').textContent = description + (detail.description && detail.description.length > 220 ? '…' : '');
        panel.querySelector('.hp-desc').classList.remove('hp-loading');
        panel.querySelector('.hp-genres').textContent = (detail.genres || []).slice(0, 3).join(' • ');
        if (detail.time) panel.querySelector('.hp-meta').insertAdjacentHTML('beforeend', `<span>${escapeHtml(detail.time)}</span>`);
        if (detail.thumb) MovieImages.apply(panel.querySelector('.hp-img'), detail, 'wide');
        place(card);
    };

    function hide() {
        clearTimeout(timer);
        clearTimeout(leaveTimer);
        token++;
        current = null;
        panel?.classList.remove('is-open');
    }
    const scheduleHide = () => { clearTimeout(leaveTimer); leaveTimer = setTimeout(hide, 120); };

    document.addEventListener('mouseover', event => {
        const card = event.target.closest?.('.movie-card');
        if (!card || card === current) { if (current && event.target.closest?.('.movie-card') === current) clearTimeout(leaveTimer); return; }
        if (card.closest('#hover-preview')) return;
        clearTimeout(timer);
        clearTimeout(leaveTimer);
        timer = setTimeout(() => show(card), panel?.classList.contains('is-open') ? PREVIEW_SWITCH_MS : PREVIEW_DWELL_MS);
    });
    document.addEventListener('mouseout', event => {
        const card = event.target.closest?.('.movie-card');
        if (!card) return;
        const to = event.relatedTarget;
        if (to && (card.contains(to) || to.closest?.('#hover-preview'))) return;
        clearTimeout(timer);
        if (card === current) scheduleHide();
    });
}

function initUI() {
    installCardKeyboardNav();
    installHoverPreview();
    const mobileMenuBtn = document.getElementById('mobile-menu-btn');
    const closeMobileMenu = () => {
        document.body.classList.remove('mobile-menu-open');
        mobileMenuBtn?.setAttribute('aria-expanded', 'false');
    };
    mobileMenuBtn?.addEventListener('click', () => {
        const open = document.body.classList.toggle('mobile-menu-open');
        mobileMenuBtn.setAttribute('aria-expanded', String(open));
    });
    document.getElementById('mobile-categories')?.addEventListener('click', (event) => {
        if (event.target.closest('button[data-cat]')) closeMobileMenu();
    });
    window.matchMedia('(min-width: 901px)').addEventListener('change', closeMobileMenu);

    const searchInput = document.getElementById('search-input');
    const searchClear = document.getElementById('search-clear');
    const searchDropdown = document.getElementById('search-suggestions');
    let debounceTimer = null;
    let suggestTimer = null;

    // Search Input with Instant Live Autocomplete Suggestions
    searchInput?.addEventListener('input', (e) => {
        const val = e.target.value.trim();
        suggestActiveIdx = -1;
        if (val) {
            searchClear?.classList.remove('hidden');
        } else {
            searchClear?.classList.add('hidden');
            showRecentSearchesDropdown();
        }

        // Live autocomplete suggest
        clearTimeout(suggestTimer);
        if (val.length >= 2) {
            suggestTimer = setTimeout(async () => {
                const suggestions = await MovieService.quickSuggest(val, currentSource, 6);
                renderSearchSuggestions(suggestions, val);
            }, 220);
        } else if (val.length === 0) {
            showRecentSearchesDropdown();
        } else {
            searchDropdown?.classList.add('hidden');
        }

        // Debounced full search if user pauses
        clearTimeout(debounceTimer);
        debounceTimer = setTimeout(() => {
            if (val) {
                currentSearchKeyword = val;
                navigateView();
            }
        }, 600);
    });

    searchInput?.addEventListener('focus', () => {
        const val = searchInput.value.trim();
        if (!val) showRecentSearchesDropdown();
    });

    searchInput?.addEventListener('keydown', (e) => {
        const dropdown = searchDropdown;
        const items = dropdown ? Array.from(dropdown.querySelectorAll('.suggestion-item, .recent-search-item')) : [];
        const isOpen = dropdown && !dropdown.classList.contains('hidden') && items.length;

        if (e.key === 'ArrowDown' && isOpen) {
            e.preventDefault();
            suggestActiveIdx = Math.min(suggestActiveIdx + 1, items.length - 1);
            updateSuggestActive(items);
            return;
        }
        if (e.key === 'ArrowUp' && isOpen) {
            e.preventDefault();
            suggestActiveIdx = Math.max(suggestActiveIdx - 1, 0);
            updateSuggestActive(items);
            return;
        }
        if (e.key === 'Enter') {
            e.preventDefault();
            if (isOpen && suggestActiveIdx >= 0 && items[suggestActiveIdx]) {
                items[suggestActiveIdx].click();
                return;
            }
            dropdown?.classList.add('hidden');
            const val = searchInput.value.trim();
            if (val) {
                MovieService.addRecentSearch(val);
                currentSearchKeyword = val;
                navigateView();
            }
        } else if (e.key === 'Escape') {
            dropdown?.classList.add('hidden');
            suggestActiveIdx = -1;
        }
    });

    // Close suggestions dropdown when clicking outside
    document.addEventListener('click', (e) => {
        if (!e.target.closest('.search-box')) {
            searchDropdown?.classList.add('hidden');
            suggestActiveIdx = -1;
        }
    });

    searchClear?.addEventListener('click', () => {
        if (searchInput) searchInput.value = '';
        searchClear.classList.add('hidden');
        searchDropdown?.classList.add('hidden');
        currentSearchKeyword = '';
        suggestActiveIdx = -1;
        navigateView();
        searchInput?.focus();
    });

    // Source Selector
    const sourceSelect = document.getElementById('source-select');
    sourceSelect?.addEventListener('change', (e) => {
        currentSource = e.target.value;
        navigateView();
    });

    // Ghost Mode Toggle — sync real native state
    const ghostBtn = document.getElementById('btn-toggle-ghost');
    const ghostStatus = document.getElementById('ghost-status-text');
    let isGhost = false;

    const syncGhostUI = (on) => {
        isGhost = !!on;
        if (ghostStatus) ghostStatus.textContent = isGhost ? 'Bật' : 'Tắt';
        ghostBtn?.classList.toggle('active', isGhost);
        ghostBtn?.setAttribute('aria-pressed', isGhost ? 'true' : 'false');
    };

    NativeStatus.init({
        onResult: (res) => { if (typeof res.isGhost === 'boolean') syncGhostUI(res.isGhost); }
    })?.check();

    chrome.runtime.onMessage.addListener((msg) => {
        if (msg?.type === 'NATIVE_STATUS_BROADCAST') {
            if (typeof msg.isGhost === 'boolean') syncGhostUI(msg.isGhost);
        }
    });

    if (ghostBtn) {
        ghostBtn.addEventListener('click', async () => {
            ghostBtn.disabled = true;
            try {
                const res = await chrome.runtime.sendMessage({
                    type: 'NATIVE_COMMAND',
                    action: 'toggleGhost'
                });
                if (res?.success && typeof res.isGhost === 'boolean') {
                    syncGhostUI(res.isGhost);
                } else if (res?.success) {
                    syncGhostUI(!isGhost);
                } else {
                    showToast(formatFloatError(res));
                    return;
                }
                showToast(isGhost ? 'Xuyên chuột đang bật: bấm xuyên phim để gõ code' : 'Xuyên chuột đang tắt: phim nhận chuột lại');
            } catch (err) {
                showToast(err?.message || 'Không đổi được chế độ xuyên chuột. Thử lại.');
            } finally {
                ghostBtn.disabled = false;
            }
        });
    }

    // Direct URL Stream Modal
    const openDirectBtn = document.getElementById('btn-open-direct-url');
    const directModal = document.getElementById('direct-stream-modal');
    const directCloseBtn = document.getElementById('direct-modal-close-btn');
    const directSubmitBtn = document.getElementById('btn-submit-direct-float');
    const directUrlInput = document.getElementById('direct-url-input');
    const directTitleInput = document.getElementById('direct-title-input');
    const directPasteBtn = document.getElementById('btn-direct-paste');
    const directError = document.getElementById('direct-url-error');
    const directStatus = document.getElementById('direct-submit-status');
    const setDirectError = (message) => {
        directError.textContent = message;
        directError.hidden = !message;
        directUrlInput?.setAttribute('aria-invalid', message ? 'true' : 'false');
    };
    directUrlInput?.addEventListener('input', () => {
        setDirectError('');
        directStatus.textContent = '';
    });

    if (openDirectBtn && directModal) {
        openDirectBtn.addEventListener('click', () => {
            setDialogOpen(directModal, true);
            directUrlInput?.focus();
        });
        directCloseBtn?.addEventListener('click', () => setDialogOpen(directModal, false));
        directModal.addEventListener('click', (e) => {
            if (e.target === directModal) setDialogOpen(directModal, false);
        });

        directPasteBtn?.addEventListener('click', async () => {
            try {
                const text = await navigator.clipboard.readText();
                if (text && directUrlInput) {
                    directUrlInput.value = text.trim();
                    if (!directTitleInput?.value?.trim()) {
                        if (text.includes('youtube.com') || text.includes('youtu.be')) {
                            directTitleInput.value = 'YouTube Video';
                        } else {
                            const fname = text.split('/').pop().split('?')[0];
                            if (fname) directTitleInput.value = decodeURIComponent(fname);
                        }
                    }
                    directUrlInput.focus();
                }
            } catch {
                directUrlInput?.focus();
            }
        });

        const submitDirectStream = async () => {
            if (directSubmitBtn.disabled) return;
            const url = directUrlInput?.value?.trim();
            const title = directTitleInput?.value?.trim() || 'Video từ link';
            if (!url) {
                setDirectError('Nhập link phim từ nguồn được hỗ trợ để tiếp tục.');
                directUrlInput?.focus();
                return;
            }
            try {
                const parsed = new URL(url);
                if (!['http:', 'https:'].includes(parsed.protocol)) throw new Error('protocol');
            } catch {
                setDirectError('Dùng link HTTPS từ nguồn phim được hỗ trợ.');
                directUrlInput?.focus();
                return;
            }
            setDirectError('');
            directSubmitBtn.disabled = true;
            directSubmitBtn.querySelector('span').textContent = 'Đang mở…';
            directStatus.textContent = 'Đang gửi link đến ứng dụng nổi…';
            const isM3u8 = url.includes('.m3u8') || url.includes('.mp4');
            const isYt = url.includes('youtube.com') || url.includes('youtu.be');
            const videoInfo = isYt
                ? MovieService.buildYouTubeLiveFloatInfo({ streamUrl: url, name: title }, title)
                : {
                    src: isM3u8 ? url : '',
                    embedUrl: !isM3u8 ? url : '',
                    title,
                    site: 'movie',
                    width: 640,
                    height: 360,
                    currentTime: 0
                };
            try {
                const result = await chrome.runtime.sendMessage({ type: 'FLOAT_VIDEO_REQUEST', videoInfo });
                if (!result?.success) throw new Error(formatFloatError(result));
                directStatus.textContent = 'Đã mở cửa sổ nổi.';
                setDialogOpen(directModal, false);
                showToast(`Đang phát nổi "${title}"`);
            } catch (error) {
                directStatus.textContent = error?.message || 'Không mở được video. Kiểm tra kết nối App rồi thử lại.';
            } finally {
                directSubmitBtn.disabled = false;
                directSubmitBtn.querySelector('span').textContent = 'Phát nổi trên màn hình';
            }
        };

        directSubmitBtn?.addEventListener('click', submitDirectStream);
        directUrlInput?.addEventListener('keydown', (e) => {
            if (e.key === 'Enter') {
                e.preventDefault();
                submitDirectStream();
            }
        });
        directTitleInput?.addEventListener('keydown', (e) => {
            if (e.key === 'Enter') {
                e.preventDefault();
                submitDirectStream();
            }
        });
    }

    // Category Buttons & Filter Sync
    const genreSelect = document.getElementById('genre-select');
    const countrySelect = document.getElementById('country-select');
    const clearFiltersBtn = document.getElementById('btn-clear-filters');

    const syncFilterState = () => {
        const isCustom = (currentCategory !== 'moi' || !!currentGenre || !!currentCountry);
        clearFiltersBtn?.classList.toggle('hidden', !isCustom);
        genreSelect?.classList.toggle('active', !!currentGenre);
        countrySelect?.classList.toggle('active', !!currentCountry);
    };

    clearFiltersBtn?.addEventListener('click', () => {
        currentCategory = 'moi';
        currentGenre = '';
        currentCountry = '';
        if (genreSelect) genreSelect.value = '';
        if (countrySelect) countrySelect.value = '';
        document.querySelectorAll('.cat-btn').forEach(b => b.classList.toggle('active', b.dataset.cat === 'moi'));
        syncFilterState();
        navigateView();
    });

    document.querySelectorAll('.cat-btn').forEach(btn => {
        btn.addEventListener('click', (e) => {
            document.querySelectorAll('.cat-btn').forEach(b => b.classList.remove('active'));
            e.currentTarget.classList.add('active');
            currentCategory = e.currentTarget.dataset.cat || 'moi';
            currentGenre = '';
            currentCountry = '';
            if (genreSelect) genreSelect.value = '';
            if (countrySelect) countrySelect.value = '';

            currentSearchKeyword = '';
            if (searchInput) searchInput.value = '';
            searchClear?.classList.add('hidden');
            searchDropdown?.classList.add('hidden');

            syncFilterState();
            navigateView();
        });
    });

    // Genre Selector
    genreSelect?.addEventListener('change', (e) => {
        currentGenre = e.target.value;
        currentCountry = '';
        if (countrySelect) countrySelect.value = '';

        if (currentGenre) {
            document.querySelectorAll('.cat-btn').forEach(b => b.classList.remove('active'));
            syncFilterState();
            navigateView();
        } else {
            syncFilterState();
        }
    });

    // Country Selector
    countrySelect?.addEventListener('change', (e) => {
        currentCountry = e.target.value;
        currentGenre = '';
        if (genreSelect) genreSelect.value = '';

        if (currentCountry) {
            document.querySelectorAll('.cat-btn').forEach(b => b.classList.remove('active'));
            syncFilterState();
            navigateView();
        } else {
            syncFilterState();
        }
    });

    // Audio Sub-pills
    document.querySelectorAll('.audio-pill').forEach(pill => {
        pill.addEventListener('click', (e) => {
            document.querySelectorAll('.audio-pill').forEach(p => {
                p.classList.remove('active');
                p.setAttribute('aria-pressed', 'false');
            });
            e.currentTarget.classList.add('active');
            e.currentTarget.setAttribute('aria-pressed', 'true');
            currentAudioFilter = e.currentTarget.dataset.filter || 'all';

            if (currentCategory === 'favorites') {
                loadFavorites();
            } else if (currentSearchKeyword) {
                searchMovies(currentSearchKeyword);
            } else {
                loadMovies();
            }
        });
    });

    // View Mode Switcher (Poster vs Cinema 16:9)
    const viewGridBtn = document.getElementById('view-grid-btn');
    const viewCinemaBtn = document.getElementById('view-cinema-btn');

    viewGridBtn?.addEventListener('click', () => applyViewMode('view-poster'));
    viewCinemaBtn?.addEventListener('click', () => applyViewMode('view-cinema'));
    try {
        const saved = localStorage.getItem(VIEW_MODE_STORAGE_KEY);
        if (saved === 'view-cinema' || saved === 'view-poster') applyViewMode(saved, { persist: false });
    } catch {}

    // Feed controls: scrolling loads more; the button is the retry path when a
    // page failed or the reader wants to jump past a slow one.
    document.getElementById('feed-retry-btn')?.addEventListener('click', () => {
        if (feed?.done) feed.done = false;
        loadMoreMovies();
    });

    // The header sits over the billboard while the page is at the top and turns
    // solid once it is not, the way the reference catalogue behaves.
    const navbar = document.querySelector('.navbar');
    if (navbar) {
        let lastScrollY = window.scrollY;
        const syncNavbar = () => {
            const y = window.scrollY;
            navbar.classList.toggle('navbar-scrolled', y > 12);
            // On phones the two-row header hides while reading and returns on scroll up.
            const menuOpen = document.getElementById('mobile-menu-btn')?.getAttribute('aria-expanded') === 'true';
            const searching = navbar.contains(document.activeElement) && document.activeElement?.tagName === 'INPUT';
            if (window.innerWidth > 900 || menuOpen || searching || y < 160) navbar.classList.remove('navbar-hidden');
            else if (y - lastScrollY > 8) navbar.classList.add('navbar-hidden');
            else if (lastScrollY - y > 8) navbar.classList.remove('navbar-hidden');
            lastScrollY = y;
        };
        window.addEventListener('scroll', syncNavbar, { passive: true });
        syncNavbar();
    }

    // Modal Close
    document.getElementById('modal-close-btn')?.addEventListener('click', closeModal);
    document.getElementById('movie-modal')?.addEventListener('click', (e) => {
        if (e.target.id === 'movie-modal') closeModal();
    });

    // Shortcuts Modal
    const shortcutsModal = document.getElementById('shortcuts-modal');
    const toggleShortcuts = () => setDialogOpen(shortcutsModal, shortcutsModal.classList.contains('hidden'));
    document.getElementById('btn-shortcuts')?.addEventListener('click', toggleShortcuts);
    document.getElementById('shortcuts-modal-close-btn')?.addEventListener('click', () => {
        setDialogOpen(shortcutsModal, false);
    });
    shortcutsModal?.addEventListener('click', (e) => {
        if (e.target.id === 'shortcuts-modal') setDialogOpen(shortcutsModal, false);
    });

    document.addEventListener('keydown', (e) => {
        const isInput = ['INPUT', 'TEXTAREA', 'SELECT'].includes(document.activeElement?.tagName);
        if (e.key === 'Escape') {
            if (activeDialog) setDialogOpen(activeDialog, false);
            closeMobileMenu();
        }
        if (e.key === 'Tab' && activeDialog) {
            const focusable = [...activeDialog.querySelectorAll('button:not(:disabled), input:not(:disabled), select:not(:disabled), [tabindex="0"]')]
                .filter(element => !element.hidden && element.getClientRects().length);
            if (focusable.length) {
                const first = focusable[0], last = focusable.at(-1);
                if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
                else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
            }
        }
        if (!isInput && e.key === '?') {
            e.preventDefault();
            toggleShortcuts();
        }
        if (!isInput && (e.key === 'v' || e.key === 'V')) {
            if (e.shiftKey) {
                e.preventDefault();
                const next = window.aiDubbing ? window.aiDubbing.toggle() : false;
                syncAIDubState(next);
                return;
            }
            const gridBtn = document.getElementById('view-grid-btn');
            const cinemaBtn = document.getElementById('view-cinema-btn');
            if (gridBtn && cinemaBtn) {
                if (gridBtn.classList.contains('active')) cinemaBtn.click();
                else gridBtn.click();
            }
        }
        if (e.key === '/' && document.activeElement !== searchInput) {
            e.preventDefault();
            searchInput?.focus();
        }
    });

    // AI Dubbing controls wiring
    const aidubBtn = document.getElementById('btn-toggle-aidub');
    const aidubStatusText = document.getElementById('aidub-status-text');
    const heroAidubBtn = document.getElementById('hero-aidub-btn');
    const syncAIDubState = (enabled) => {
        if (aidubBtn) {
            aidubBtn.classList.toggle('active', !!enabled);
            aidubBtn.setAttribute('aria-pressed', enabled ? 'true' : 'false');
        }
        if (aidubStatusText) {
            aidubStatusText.textContent = enabled ? 'Bật' : 'Tắt';
        }
        if (heroAidubBtn) {
            heroAidubBtn.classList.toggle('active', !!enabled);
        }
    };

    aidubBtn?.addEventListener('click', () => {
        const next = window.aiDubbing ? window.aiDubbing.toggle() : false;
        syncAIDubState(next);
    });

    heroAidubBtn?.addEventListener('click', () => {
        const next = window.aiDubbing ? window.aiDubbing.toggle() : false;
        syncAIDubState(next);
    });

    window.addEventListener('aidub-state-change', (e) => {
        syncAIDubState(e.detail?.enabled);
    });

    if (window.aiDubbing) {
        syncAIDubState(window.aiDubbing.enabled);
    }

    // Clear continue watching
    document.getElementById('clear-continue-btn')?.addEventListener('click', async () => {
        if (confirm('Bạn có chắc muốn xóa lịch sử xem gần đây?')) {
            if (typeof chrome !== 'undefined' && chrome.storage?.local) {
                await chrome.storage.local.set({ vibe_continue_watching: [] });
            } else {
                localStorage.removeItem('vibe_continue_watching');
            }
            loadContinueWatching();
        }
    });
}

// MARK: - Autocomplete Live Search Suggestions
function updateSuggestActive(items) {
    items.forEach((el, i) => el.classList.toggle('is-active', i === suggestActiveIdx));
    if (suggestActiveIdx >= 0 && items[suggestActiveIdx]) {
        items[suggestActiveIdx].scrollIntoView({ block: 'nearest' });
    }
}

async function showRecentSearchesDropdown() {
    const dropdown = document.getElementById('search-suggestions');
    if (!dropdown) return;
    const recent = await MovieService.getRecentSearches();
    if (!recent.length) {
        dropdown.classList.add('hidden');
        return;
    }
    suggestActiveIdx = -1;
    dropdown.innerHTML = `
        <div class="recent-searches-header">
            <span>Tìm gần đây</span>
            <button type="button" class="text-btn" id="clear-recent-searches">Xóa</button>
        </div>
        ${recent.map(q => `
            <div class="recent-search-item" data-query="${escapeAttr(q)}">
                <span class="recent-search-label">${escapeHtml(q)}</span>
            </div>
        `).join('')}
    `;
    dropdown.classList.remove('hidden');
    dropdown.querySelector('#clear-recent-searches')?.addEventListener('click', async (e) => {
        e.stopPropagation();
        await MovieService.clearRecentSearches();
        dropdown.classList.add('hidden');
    });
    dropdown.querySelectorAll('.recent-search-item').forEach(el => {
        el.addEventListener('click', () => {
            const q = el.dataset.query || '';
            const input = document.getElementById('search-input');
            if (input) input.value = q;
            document.getElementById('search-clear')?.classList.remove('hidden');
            dropdown.classList.add('hidden');
            MovieService.addRecentSearch(q);
            currentSearchKeyword = q;
            navigateView();
        });
    });
}

function renderSearchSuggestions(items, query) {
    const dropdown = document.getElementById('search-suggestions');
    if (!dropdown) return;
    suggestActiveIdx = -1;

    if (!items || items.length === 0) {
        dropdown.innerHTML = `<div class="suggestion-empty">Không tìm thấy phim khớp với "${escapeHtml(query)}"</div>`;
        dropdown.classList.remove('hidden');
        return;
    }

    dropdown.innerHTML = items.map(item => {
        const badges = [];
        if (item.isChieuRap) badges.push('<span class="suggestion-badge badge-rap">RẠP</span>');
        if (item.hasThuyetMinh) badges.push('<span class="suggestion-badge badge-tm">TM</span>');
        if (item.hasLongTieng) badges.push('<span class="suggestion-badge badge-lt">LT</span>');
        if (item.episode_current) badges.push(`<span class="suggestion-badge badge-ep">${escapeHtml(item.episode_current)}</span>`);
        const inList = favSlugSet.has(item.slug);

        return `
            <div class="suggestion-item" data-slug="${escapeAttr(item.slug)}" data-source="${escapeAttr(item.source || currentSource)}" role="option">
                <img class="suggestion-thumb" loading="lazy" ${MovieImages.attr(item, 'poster')} width="40" height="56" alt="">
                <div class="suggestion-info">
                    <div class="suggestion-title">${escapeHtml(item.name)}${inList ? ' · Đã lưu' : ''}</div>
                    <div class="suggestion-sub">${item.year ? item.year + ' · ' : ''}${escapeHtml(item.origin_name || '')}</div>
                    <div class="suggestion-badges">${badges.join('')}</div>
                </div>
            </div>
        `;
    }).join('');

    dropdown.classList.remove('hidden');

    dropdown.querySelectorAll('.suggestion-item').forEach(el => {
        el.addEventListener('click', () => {
            dropdown.classList.add('hidden');
            const slug = el.dataset.slug;
            const source = el.dataset.source;
            const q = document.getElementById('search-input')?.value?.trim();
            if (q) MovieService.addRecentSearch(q);
            openMovieDetail(slug, source);
        });
    });
}

// MARK: - Home Page with Multi-Sections
function renderHomeUnavailable(container, message) {
    container.innerHTML = `<div class="feed-empty" role="status"><p>${escapeHtml(message)}</p><button type="button" class="state-retry-btn">Thử tải lại</button></div>`;
    container.querySelector('.state-retry-btn')?.addEventListener('click', loadHomePage);
}

// Draws the category rails. Returns false when there is nothing to show.
function renderHomeSections(container, homeData) {
    if (!homeData.sections?.length) {
        renderHomeUnavailable(container, 'Chưa có phim để hiển thị. Hãy thử nguồn khác hoặc tải lại.');
        return false;
    }

    // Render each category rail
    container.innerHTML = homeData.sections.map((sec, secIdx) => {
        const railClass = sec.isTop10 ? 'home-section-rail top10-rail' : 'home-section-rail';
        return `
            <section class="home-section" data-sec-id="${escapeAttr(sec.id)}">
                <div class="home-section-header">
                    <div class="home-section-title-wrap">
                        <div>
                            <h3 class="home-section-title">${escapeHtml(sec.title)}</h3>
                            <span class="home-section-subtitle">${escapeHtml(sec.subtitle || '')}</span>
                        </div>
                    </div>
                    <button class="view-all-btn" data-cat="${escapeAttr(sec.categoryKey)}" data-genre="${escapeAttr(sec.genreSlug || '')}">Xem tất cả →</button>
                </div>

                <div class="home-section-rail-wrap">
                    <button class="rail-nav-btn rail-prev" data-target="rail-${secIdx}" type="button" aria-label="Cuộn trái mục ${escapeAttr(sec.title)}">‹</button>
                    <div id="rail-${secIdx}" class="${railClass}" role="region" aria-label="${escapeAttr(sec.title)}">
                        ${renderMovieCardsHtml(sec.items, { isTop10: !!sec.isTop10, isRail: true })}
                    </div>
                    <button class="rail-nav-btn rail-next" data-target="rail-${secIdx}" type="button" aria-label="Cuộn phải mục ${escapeAttr(sec.title)}">›</button>
                </div>
            </section>
        `;
    }).join('');

    // Keep rail controls in sync with the visible position.
    const syncRailControls = (rail) => {
        const wrap = rail.closest('.home-section-rail-wrap');
        const maxScroll = rail.scrollWidth - rail.clientWidth;
        wrap.querySelector('.rail-prev').disabled = rail.scrollLeft < 8;
        wrap.querySelector('.rail-next').disabled = maxScroll < 8 || rail.scrollLeft >= maxScroll - 8;
    };
    homeRailResizeObserver?.disconnect();
    homeRailResizeObserver = new ResizeObserver(entries => {
        entries.forEach(({ target }) => syncRailControls(target));
    });
    container.querySelectorAll('.home-section-rail').forEach(rail => {
        rail.addEventListener('scroll', () => syncRailControls(rail), { passive: true });
        homeRailResizeObserver.observe(rail);
        syncRailControls(rail);
    });

    // Bind Rail scroll buttons
    container.querySelectorAll('.rail-nav-btn').forEach(btn => {
        btn.addEventListener('click', (e) => {
            e.stopPropagation();
            const targetId = btn.dataset.target;
            const rail = document.getElementById(targetId);
            if (rail) {
                const scrollAmount = rail.clientWidth * 0.75;
                const direction = btn.classList.contains('rail-prev') ? -scrollAmount : scrollAmount;
                rail.scrollBy({ left: direction, behavior: 'smooth' });
            }
        });
    });

    // Bind "Xem tất cả" buttons
    container.querySelectorAll('.view-all-btn').forEach(btn => {
        btn.addEventListener('click', () => {
            const targetCat = btn.dataset.cat;
            const genreSlug = btn.dataset.genre;
            if (genreSlug) {
                const gSelect = document.getElementById('genre-select');
                if (gSelect) gSelect.value = genreSlug;
                currentGenre = genreSlug;
                currentCategory = 'moi';
                document.querySelectorAll('.cat-btn').forEach(b => b.classList.remove('active'));
                navigateView();
                window.scrollTo({ top: 0, behavior: 'smooth' });
                return;
            }
            if (targetCat) {
                document.querySelectorAll('.cat-btn').forEach(b => {
                    b.classList.toggle('active', b.dataset.cat === targetCat);
                });
                currentCategory = targetCat;
                currentGenre = '';
                navigateView();
                window.scrollTo({ top: 0, behavior: 'smooth' });
            }
        });
    });

    // Bind Card Clicks
    bindCardClicks(container);
    ensureRovingTab(container);
    return true;
}

let homeLoadSeq = 0;
const HOME_SKELETON_HTML = `
        <p class="home-loading" role="status">Đang tải kho phim…</p>
        <div class="home-section-skeleton"></div>
        <div class="home-section-skeleton"></div>
        <div class="home-section-skeleton"></div>
    `;

function applyHomeHero(homeData) {
    const spots = (homeData.spotlights && homeData.spotlights.length)
        ? homeData.spotlights
        : (homeData.spotlight ? [homeData.spotlight] : []);
    if (spots.length) {
        startHeroRotation(spots);
    } else {
        stopHeroRotation();
        document.getElementById('hero-spotlight')?.classList.add('hidden');
    }
    return spots;
}

async function loadHomePage() {
    const seq = ++homeLoadSeq;
    const container = document.getElementById('home-sections-container');
    if (!container) return;
    const source = currentSource;

    // Last good result: shown at once, then refreshed in the background.
    let cached = null;
    try { cached = await MovieService.getCachedHome(source); } catch {}
    if (seq !== homeLoadSeq) return;

    let shownSignature = null;
    if (cached) {
        await refreshFavSet();
        if (seq !== homeLoadSeq) return;
        applyHomeHero(cached);
        if (renderHomeSections(container, cached)) shownSignature = MovieService.homeSignature(cached);
        else cached = null;
    }
    if (!cached) {
        document.getElementById('hero-spotlight')?.classList.add('hidden');
        container.innerHTML = HOME_SKELETON_HTML;
    }

    try {
        await refreshFavSet();
        if (seq !== homeLoadSeq) return;
        let earlyHeroSlug = null;
        const homeData = await MovieService.getHomeSections(source, {
            // Without a cache, show the billboard as soon as it is ready instead of waiting for every row.
            onSpotlights: early => {
                if (cached || seq !== homeLoadSeq || !early.length) return;
                startHeroRotation(early);
                earlyHeroSlug = early[0].slug;
            }
        });
        if (seq !== homeLoadSeq) return;

        if (cached) {
            // Same titles as the cached page: leave it alone. The reader may be mid-scroll on a
            // changed page: keep what they see; the new data is cached for the next visit.
            // A partial outage returns fewer rows without failing: keep the fuller cached page.
            if (MovieService.homeRowCount(homeData) < MovieService.homeRowCount(cached)) return;
            if (MovieService.homeSignature(homeData) === shownSignature || window.scrollY > 300) return;
            applyHomeHero(homeData);
        } else {
            applyHomeHeroUnlessEarly(homeData, earlyHeroSlug);
        }
        renderHomeSections(container, homeData);
    } catch (e) {
        if (cached) return; // The cached page is still useful when the refresh fails.
        console.error('Failed to load home sections:', e);
        renderHomeUnavailable(container, 'Không tải được kho phim. Kiểm tra kết nối rồi thử lại.');
    }
    // The home sections just loaded; check they took their skeletons away.
    auditTransientNodes(container, 'loading the home sections', true);
}

function applyHomeHeroUnlessEarly(homeData, earlyHeroSlug) {
    const spots = (homeData.spotlights && homeData.spotlights.length)
        ? homeData.spotlights
        : (homeData.spotlight ? [homeData.spotlight] : []);
    if (!spots.length) return applyHomeHero(homeData);
    if (!earlyHeroSlug || earlyHeroSlug !== spots[0].slug) startHeroRotation(spots);
    return spots;
}

// MARK: - Render Movie Cards HTML
function renderMovieCardsHtml(items, opts = {}) {
    if (!items || items.length === 0) {
        return '<div style="color: var(--text-muted); font-size: 13px; padding: 24px;">Không có phim trong mục này.</div>';
    }

    return items.map(item => {
        const badges = [];
        if (item.isChieuRap) {
            badges.push('<span class="card-badge badge-rap">RẠP</span>');
        }
        if (item.hasThuyetMinh) {
            badges.push('<span class="card-badge badge-tm">TM</span>');
        }
        if (item.hasLongTieng) {
            badges.push('<span class="card-badge badge-lt">LT</span>');
        }
        if (item.hasVietsub && !item.hasThuyetMinh && !item.hasLongTieng) {
            badges.push('<span class="card-badge badge-vs">VIETSUB</span>');
        }

        const ratingBadge = item.rating ? `<span class="card-badge-rating">${escapeHtml(item.rating)}</span>` : '';
        const epBadge = item.episode_current ? `<span class="card-ep-badge">${escapeHtml(item.episode_current)}</span>` : '';
        const rank = item.rank || opts.rank;
        const rankHtml = (opts.isTop10 && rank)
            ? `<span class="card-rank" aria-hidden="true">${escapeHtml(rank)}</span>`
            : '';
        const inList = favSlugSet.has(item.slug);
        const imageKind = opts.isRail || currentViewMode === 'view-cinema' ? 'wide' : 'poster';
        const cardClass = `movie-card${opts.isRail ? ' movie-card-rail' : ''}${opts.isTop10 ? ' movie-card-top10' : ''}`;

        return `
            <div class="${cardClass}" data-slug="${escapeAttr(item.slug)}" data-source="${escapeAttr(item.source || currentSource)}" role="group" aria-label="${escapeAttr(item.name)}" tabindex="-1">
                <div class="movie-poster-wrap">
                    ${rankHtml}
                    <img class="movie-poster" loading="lazy" ${MovieImages.attr(item, imageKind)} alt="" width="320" height="180">
                    <div class="card-badges-top">${badges.join('')}</div>
                    ${ratingBadge}
                    ${epBadge}
                    <div class="card-hover-actions">
                        <button type="button" class="card-action-btn card-quick-float" data-slug="${escapeAttr(item.slug)}" data-source="${escapeAttr(item.source || currentSource)}" title="Phát nổi — Tập sau tự động / Bỏ qua GT trong PiP" aria-label="Phát nổi ${escapeAttr(item.name)}">
                            ${PLAY_ICON_SVG}<span>Phát nổi</span>
                        </button>
                        <button type="button" class="card-action-btn card-mylist-btn ${inList ? 'is-listed' : ''}" data-slug="${escapeAttr(item.slug)}" data-source="${escapeAttr(item.source || currentSource)}" title="${inList ? 'Bỏ khỏi danh sách' : 'Thêm vào danh sách'}" aria-label="${inList ? 'Bỏ' : 'Thêm'} ${escapeAttr(item.name)} ${inList ? 'khỏi' : 'vào'} danh sách" aria-pressed="${inList ? 'true' : 'false'}">
                            ${inList ? LIST_CHECK_SVG : LIST_ICON_SVG}
                        </button>
                        <button type="button" class="card-action-btn card-info-btn" data-slug="${escapeAttr(item.slug)}" data-source="${escapeAttr(item.source || currentSource)}" title="Chi tiết phim" aria-label="Xem chi tiết ${escapeAttr(item.name)}">
                            ${INFO_BTN_SVG}
                        </button>
                    </div>
                </div>
                <div class="movie-info">
                    <div class="movie-title" title="${escapeAttr(item.name)}">${escapeHtml(item.name)}</div>
                    ${item.quality ? `<div class="card-meta-row"><span class="card-hd">${escapeHtml(item.quality)}</span></div>` : ''}
                    <div class="movie-origin">${escapeHtml(item.origin_name || item.year || '')}</div>
                    <div class="movie-footer">
                        ${item.year ? `<span>Năm ${escapeHtml(item.year)}</span>` : ''}
                        <button type="button" class="card-quick-float card-quick-float-text" data-slug="${escapeAttr(item.slug)}" data-source="${escapeAttr(item.source || currentSource)}" title="Phát nổi">Phát nổi</button>
                    </div>
                </div>
            </div>
        `;
    }).join('');
}

function bindCardClicks(container) {
    container.querySelectorAll('.card-info-btn').forEach(btn => {
        btn.addEventListener('click', (e) => {
            e.stopPropagation();
            const slug = btn.dataset.slug;
            const source = btn.dataset.source || currentSource;
            openMovieDetail(slug, source);
        });
    });
    container.querySelectorAll('.card-quick-float').forEach(btn => {
        btn.addEventListener('click', async (e) => {
            e.stopPropagation();
            const slug = btn.dataset.slug;
            const source = btn.dataset.source || currentSource;
            const labelEl = btn.querySelector('span');
            const original = labelEl ? labelEl.textContent : btn.textContent;
            if (labelEl) labelEl.textContent = 'Đang mở…';
            else btn.textContent = 'Đang mở…';
            btn.disabled = true;
            try {
                const ok = await quickFloatMovie(slug, source);
                const done = ok ? 'Đang phát' : 'Thử lại';
                if (labelEl) labelEl.textContent = done;
                else btn.textContent = done;
                if (ok) showToast('Đã phát nổi — Tập sau tự động / Bỏ qua GT sẵn trong PiP');
            } catch (err) {
                if (labelEl) labelEl.textContent = 'Thử lại';
                else btn.textContent = 'Thử lại';
                showToast(err?.message || 'Không mở được phim. Kiểm tra kết nối rồi thử lại.');
            } finally {
                btn.disabled = false;
                setTimeout(() => {
                    if (labelEl) {
                        if (labelEl.textContent !== 'Đang phát') labelEl.textContent = 'Phát nổi';
                    } else if (btn.textContent !== 'Đang phát') {
                        btn.textContent = original;
                    }
                }, 1600);
            }
        });
    });

    container.querySelectorAll('.card-mylist-btn').forEach(btn => {
        btn.addEventListener('click', async (e) => {
            e.stopPropagation();
            const slug = btn.dataset.slug;
            const source = btn.dataset.source || currentSource;
            // Prefer item data from card context via detail lite from favorites or open card attrs
            const card = btn.closest('.movie-card');
            const title = card?.querySelector('.movie-title')?.textContent || slug;
            const poster = card?.querySelector('.movie-poster')?.src || '';
            const movieStub = {
                slug,
                name: title,
                poster,
                thumb: poster,
                source,
                hasThuyetMinh: !!card?.querySelector('.badge-tm'),
                hasLongTieng: !!card?.querySelector('.badge-lt'),
                isChieuRap: !!card?.querySelector('.badge-rap')
            };
            const isFav = await MovieService.toggleFavorite(movieStub);
            await refreshFavSet();
            setListButtonState(btn, isFav);
            // Sync other cards with same slug
            container.querySelectorAll(`.card-mylist-btn[data-slug="${CSS.escape(slug)}"]`).forEach(b => setListButtonState(b, isFav));
            if (currentSpotlightMovie?.slug === slug) {
                setListButtonState(document.getElementById('hero-fav-btn'), isFav);
            }
            showToast(isFav ? `Đã thêm vào Danh sách của tôi` : `Đã bỏ khỏi Danh sách`);
        });
    });

    container.querySelectorAll('.movie-card').forEach(card => {
        card.addEventListener('click', () => {
            const slug = card.dataset.slug;
            const source = card.dataset.source || currentSource;
            openMovieDetail(slug, source);
        });
        card.addEventListener('keydown', (event) => {
            if (event.target !== card || !['Enter', ' '].includes(event.key)) return;
            event.preventDefault();
            openMovieDetail(card.dataset.slug, card.dataset.source || currentSource);
        });
    });
}

async function quickFloatMovie(slug, source) {
    const detail = await MovieService.getDetail(slug, source);
    if (!detail?.episodes?.length) {
        openMovieDetail(slug, source);
        return false;
    }
    const servers = detail.episodes.filter(s => s.items?.length);
    if (!servers.length) {
        openMovieDetail(slug, source);
        return false;
    }

    const continueList = await MovieService.getContinueWatching();
    const cont = continueList.find(c => c.slug === slug);

    let server = servers[0];
    let ep = server.items[0];
    let serverIdx = MovieService.preferVietnameseServerIndex(servers);
    let epIdx = 0;
    server = servers[serverIdx] || servers[0];
    ep = server.items[0];

    if (cont) {
        if (cont.serverIdx != null && servers[cont.serverIdx]?.items?.[cont.epIdx ?? 0]) {
            // Keep saved server unless dead
            serverIdx = Number(cont.serverIdx) || 0;
            epIdx = Number(cont.epIdx) || 0;
            server = servers[serverIdx];
            ep = server.items[epIdx];
        } else if (cont.epName || cont.epSlug) {
            let best = null;
            for (let si = 0; si < servers.length; si++) {
                const matchIdx = servers[si].items.findIndex(item =>
                    (cont.epName && item.name === cont.epName) ||
                    (cont.epSlug && item.slug === cont.epSlug)
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
    }

    // YouTube live channels → youtube embed path (avoid watch-page bot wall)
    if ((detail.source === 'livetv' || slug?.startsWith('livetv-')) && (ep.pageUrl?.includes('youtube') || ep.linkEmbed?.includes('youtube.com/embed'))) {
        const pageUrl = ep.pageUrl || (ep.linkEmbed ? ep.linkEmbed.replace('/embed/', '/watch?v=').replace(/\?autoplay=1/, '') : '');
        if (pageUrl) {
            const videoInfo = MovieService.buildYouTubeLiveFloatInfo({
                youtubeId: MovieService.extractYouTubeId(pageUrl),
                streamUrl: pageUrl,
                name: detail.name
            }, detail.name);
            const res = await chrome.runtime.sendMessage({
                type: 'FLOAT_VIDEO_REQUEST',
                videoInfo
            });
            if (res?.success) {
                showToast('Đang phát nổi Lofi / Live YouTube');
                return true;
            }
            showToast(formatFloatError(res));
            return false;
        }
    }

    const floated = await floatEpisode(ep, detail, server, {
        currentTime: Number(cont?.currentTime) || 0,
        duration: Number(cont?.duration) || 0,
        serverIdx,
        epIdx
    });
    return !!floated;
}

// MARK: - Cinema Hero Spotlight Slideshow
function stopHeroRotation() {
    if (heroRotationTimer) {
        clearInterval(heroRotationTimer);
        heroRotationTimer = null;
    }
    heroSpotlights = [];
    heroSpotlightIndex = 0;
}

function startHeroRotation(spots) {
    stopHeroRotation();
    heroSpotlights = spots.filter(Boolean);
    heroSpotlightIndex = 0;
    if (!heroSpotlights.length) return;
    renderHeroSpotlight(heroSpotlights[0]);
    renderHeroDots();
    setupHeroSlideControls();

    if (heroSpotlights.length > 1) {
        startHeroAutoPlay();
    }
}

function startHeroAutoPlay() {
    if (heroRotationTimer) {
        clearInterval(heroRotationTimer);
    }
    heroRotationTimer = setInterval(() => {
        if (isHeroHovered) return;
        nextHeroSlide();
    }, 6000);
}

function nextHeroSlide() {
    if (heroSpotlights.length < 2) return;
    heroSpotlightIndex = (heroSpotlightIndex + 1) % heroSpotlights.length;
    renderHeroSpotlight(heroSpotlights[heroSpotlightIndex], { soft: true });
    updateHeroDots();
}

function prevHeroSlide() {
    if (heroSpotlights.length < 2) return;
    heroSpotlightIndex = (heroSpotlightIndex - 1 + heroSpotlights.length) % heroSpotlights.length;
    renderHeroSpotlight(heroSpotlights[heroSpotlightIndex], { soft: true });
    updateHeroDots();
}

function setupHeroSlideControls() {
    const heroSection = document.getElementById('hero-spotlight');
    if (!heroSection || heroSection.dataset.controlsAttached) return;
    heroSection.dataset.controlsAttached = 'true';

    heroSection.addEventListener('mouseenter', () => {
        isHeroHovered = true;
    });
    heroSection.addEventListener('mouseleave', () => {
        isHeroHovered = false;
    });

    const prevBtn = document.getElementById('hero-prev-btn');
    const nextBtn = document.getElementById('hero-next-btn');

    if (prevBtn) {
        prevBtn.onclick = (e) => {
            e.stopPropagation();
            prevHeroSlide();
            startHeroAutoPlay();
        };
    }
    if (nextBtn) {
        nextBtn.onclick = (e) => {
            e.stopPropagation();
            nextHeroSlide();
            startHeroAutoPlay();
        };
    }

    // Keyboard navigation when mouse is in hero area
    heroSection.addEventListener('keydown', (e) => {
        if (e.key === 'ArrowLeft') {
            e.preventDefault();
            prevHeroSlide();
            startHeroAutoPlay();
        } else if (e.key === 'ArrowRight') {
            e.preventDefault();
            nextHeroSlide();
            startHeroAutoPlay();
        }
    });
}

function renderHeroDots() {
    const dots = document.getElementById('hero-dots');
    if (!dots) return;
    if (heroSpotlights.length < 2) {
        dots.hidden = true;
        dots.innerHTML = '';
        return;
    }
    dots.hidden = false;
    dots.innerHTML = heroSpotlights.map((_, i) =>
        `<button type="button" class="hero-dot ${i === heroSpotlightIndex ? 'active' : ''}" data-idx="${i}" aria-label="Phim nổi bật ${i + 1}: ${escapeAttr(heroSpotlights[i].name)}" aria-pressed="${i === heroSpotlightIndex}"></button>`
    ).join('');
    dots.querySelectorAll('.hero-dot').forEach(btn => {
        btn.addEventListener('click', (e) => {
            e.stopPropagation();
            const idx = Number(btn.dataset.idx) || 0;
            if (idx === heroSpotlightIndex) return;
            heroSpotlightIndex = idx;
            renderHeroSpotlight(heroSpotlights[idx], { soft: true });
            updateHeroDots();
            startHeroAutoPlay();
        });
    });
}

function updateHeroDots() {
    const dots = document.getElementById('hero-dots');
    if (!dots) return;
    dots.querySelectorAll('.hero-dot').forEach((btn, i) => {
        const isActive = i === heroSpotlightIndex;
        btn.classList.toggle('active', isActive);
        btn.setAttribute('aria-pressed', isActive ? 'true' : 'false');
    });
}

function renderHeroSpotlight(spot, opts = {}) {
    const heroSection = document.getElementById('hero-spotlight');
    if (!heroSection || !spot) return;

    currentSpotlightMovie = spot;
    heroSection.classList.remove('hidden');

    const content = heroSection.querySelector('.hero-content');
    if (opts.soft && content) {
        content.classList.add('hero-fade');
        requestAnimationFrame(() => {
            setTimeout(() => content.classList.remove('hero-fade'), 260);
        });
    }

    const backdropEl = document.getElementById('hero-backdrop');
    if (backdropEl) {
        if (opts.soft) {
            backdropEl.style.opacity = '0.35';
            setTimeout(() => {
                MovieImages.apply(backdropEl, { poster: spot.thumb, thumb: spot.poster }, 'hero');
                backdropEl.style.opacity = '1';
            }, 120);
        } else {
            MovieImages.apply(backdropEl, { poster: spot.thumb, thumb: spot.poster }, 'hero');
            backdropEl.style.opacity = '1';
        }
    }

    document.getElementById('hero-title').textContent = spot.name;
    document.getElementById('hero-origin').textContent = [spot.origin_name, spot.year].filter(Boolean).join(' · ');
    document.getElementById('hero-desc').textContent = spot.description || 'Chưa có mô tả cho phim này.';

    const ratingEl = document.getElementById('hero-rating');
    if (ratingEl) {
        ratingEl.textContent = spot.rating || '';
        ratingEl.hidden = !spot.rating;
    }

    const matchEl = document.getElementById('hero-match');
    if (matchEl) {
        matchEl.hidden = true;
    }

    const audioBadgeEl = document.getElementById('hero-audio-badge');
    if (audioBadgeEl) {
        if (spot.hasThuyetMinh && spot.hasLongTieng) audioBadgeEl.textContent = 'TM + LT';
        else if (spot.hasThuyetMinh) audioBadgeEl.textContent = 'Thuyết Minh';
        else if (spot.hasLongTieng) audioBadgeEl.textContent = 'Lồng Tiếng';
        else audioBadgeEl.hidden = true;
        if (spot.hasThuyetMinh || spot.hasLongTieng) audioBadgeEl.hidden = false;
    }

    const heroAidubBtn = document.getElementById('hero-aidub-btn');
    if (heroAidubBtn) {
        heroAidubBtn.classList.toggle('active', !!window.aiDubbing?.enabled);
    }

    const floatBtn = document.getElementById('hero-float-btn');
    const detailBtn = document.getElementById('hero-detail-btn');
    const favBtn = document.getElementById('hero-fav-btn');

    setListButtonState(favBtn, favSlugSet.has(spot.slug));

    floatBtn.onclick = () => {
        quickFloatMovie(spot.slug, spot.source || 'kkphim');
    };

    detailBtn.onclick = () => {
        openMovieDetail(spot.slug, spot.source || 'kkphim');
    };

    favBtn.onclick = async () => {
        const isFav = await MovieService.toggleFavorite(spot);
        await refreshFavSet();
        setListButtonState(favBtn, isFav);
        showToast(isFav ? `Đã thêm "${spot.name}" vào Danh sách của tôi` : `Đã bỏ khỏi Danh sách`);
    };
}

// MARK: - Continue Watching
async function loadContinueWatching() {
    const continueSection = document.getElementById('continue-section');
    const rail = document.getElementById('continue-rail');
    if (!continueSection || !rail) return;

    const items = await MovieService.getContinueWatching();
    if (!items || items.length === 0) {
        continueSection.classList.add('hidden');
        return;
    }

    continueSection.classList.remove('hidden');
    rail.innerHTML = items.map((item, idx) => {
        const pct = MovieService.progressPercent(item);
        const progressHtml = pct > 0
            ? `<div class="continue-progress"><div class="continue-progress-bar" style="width:${pct}%"></div></div>`
            : '';
        return `
        <div class="continue-card" data-idx="${idx}" role="button" tabindex="0" aria-label="Phát tiếp ${escapeAttr(item.name)}, ${escapeAttr(item.epName || 'Tập 1')}" title="Phát nổi tiếp — ${escapeAttr(item.name)}">
            <div class="continue-thumb-wrap">
                <img class="continue-thumb" loading="lazy" ${MovieImages.attr(item, 'wide')} width="280" height="158" alt="">
                <button type="button" class="continue-play-overlay" title="Phát tiếp" aria-label="Phát tiếp ${escapeAttr(item.name)}">
                    <svg width="24" height="24" viewBox="0 0 24 24" fill="currentColor"><polygon points="5 3 19 12 5 21 5 3"/></svg>
                </button>
                <button type="button" class="continue-delete-btn" data-slug="${escapeAttr(item.slug)}" title="Xóa khỏi danh sách xem tiếp" aria-label="Xóa">&times;</button>
                ${progressHtml}
            </div>
            <div class="continue-info">
                <span class="continue-title" title="${escapeAttr(item.name)}">${escapeHtml(item.name)}</span>
                <div class="continue-ep-row">
                    <span class="continue-ep">${escapeHtml(item.epName || 'Tập 1')}</span>
                    ${pct > 0 ? `<span class="continue-pct">${pct}%</span>` : ''}
                </div>
            </div>
        </div>
    `;
    }).join('');

    rail.querySelectorAll('.continue-card').forEach(card => {
        const handleCardAction = async () => {
            const idx = parseInt(card.dataset.idx);
            const item = items[idx];
            try {
                const ok = await floatContinueItem(item);
                if (ok) {
                    showToast(`Đang phát tiếp "${item.name} — ${item.epName || ''}"`);
                }
            } catch (err) {
                showToast('Không phát tiếp được phim. Kiểm tra kết nối rồi thử lại.');
            }
        };

        card.addEventListener('click', (e) => {
            if (e.target.closest('.continue-delete-btn')) return;
            handleCardAction();
        });
        card.addEventListener('keydown', (e) => {
            if (e.target !== card || !['Enter', ' '].includes(e.key)) return;
            e.preventDefault();
            handleCardAction();
        });
    });

    rail.querySelectorAll('.continue-delete-btn').forEach(btn => {
        btn.addEventListener('click', async (e) => {
            e.stopPropagation();
            const slug = btn.dataset.slug;
            if (slug) {
                await MovieService.removeContinueWatching(slug);
                await loadContinueWatching();
            }
        });
    });
}

/** Resume continue-watching card with seek + playlist context. */
async function floatContinueItem(item) {
    if (!item) return false;
    let detail = null;
    try {
        detail = await MovieService.getDetail(item.slug, item.source || 'kkphim');
    } catch (e) {
        console.warn('[catalog] detail fetch for continue failed:', e);
    }

    let ep = {
        name: item.epName || 'Tập 1',
        slug: item.epSlug || '',
        linkM3u8: item.linkM3u8 || '',
        linkEmbed: item.linkEmbed || ''
    };
    let server = null;
    let serverIdx = Number(item.serverIdx) || 0;
    let epIdx = Number(item.epIdx) || 0;

    if (detail?.episodes?.length) {
        const servers = detail.episodes.filter(s => s.items?.length);
        // Keep saved serverIdx unless that server is dead
        if (item.serverIdx != null && servers[serverIdx]?.items?.[epIdx]) {
            server = servers[serverIdx];
            ep = server.items[epIdx] || ep;
            return await floatEpisode(ep, detail, server, {
                currentTime: Number(item.currentTime) || 0,
                duration: Number(item.duration) || 0,
                serverIdx,
                epIdx
            });
        }
        const found = MovieService.findEpisodeIndices(detail, ep);
        if (found.servers.length) {
            serverIdx = found.serverIdx;
            epIdx = found.epIdx;
            server = found.servers[serverIdx];
            ep = server.items[epIdx] || ep;
            return await floatEpisode(ep, detail, server, {
                currentTime: Number(item.currentTime) || 0,
                duration: Number(item.duration) || 0,
                serverIdx,
                epIdx
            });
        }
    }

    // Fallback: float saved links without full playlist
    const title = `${item.name} — ${item.epName || 'Tập 1'}`;
    const resumeAt = Number(item.currentTime) || 0;
    const res = await chrome.runtime.sendMessage({
        type: 'FLOAT_VIDEO_REQUEST',
        videoInfo: {
            src: item.linkM3u8 || '',
            embedUrl: item.linkEmbed || '',
            title,
            site: 'movie',
            width: 640,
            height: 360,
            currentTime: resumeAt,
            aiDubEnabled: window.aiDubbing ? window.aiDubbing.enabled : false
        }
    });
    if (res?.success) return true;
    showToast(formatFloatError(res));
    return false;
}

// MARK: - Feed (cuộn để tải thêm)
//
// The grid is a feed, not a page: every list view loads page 1 and then keeps
// appending for as long as the reader scrolls, up to the 98 pages KKPhim has of
// the dubbed catalogue. `feed` describes the list currently on screen, so a
// response for a view the user has already left is recognised (the object
// identity changed) and dropped instead of appended to the wrong list.
const FEED_PAGE_CAP = 60;
const VIEW_MODE_STORAGE_KEY = 'vibe_catalog_view_mode';

// Poster and Cinema differ only in layout and artwork, so switching keeps the loaded list and scroll position.
function applyViewMode(mode, { persist = true } = {}) {
    const movieGrid = document.getElementById('movie-grid');
    const isCinema = mode === 'view-cinema';
    // Row heights differ between layouts; keep the first visible card where it was on screen.
    let anchor = null;
    if (persist && movieGrid && typeof window !== 'undefined') {
        const visible = [...movieGrid.querySelectorAll('.movie-card')].find(c =>
            typeof c.getBoundingClientRect === 'function' && c.getBoundingClientRect().bottom > 120);
        if (visible) anchor = { card: visible, top: visible.getBoundingClientRect().top };
    }
    currentViewMode = isCinema ? 'view-cinema' : 'view-poster';
    movieGrid?.classList.toggle('view-cinema', isCinema);
    movieGrid?.classList.toggle('view-poster', !isCinema);
    [['view-grid-btn', !isCinema], ['view-cinema-btn', isCinema]].forEach(([id, on]) => {
        const btn = document.getElementById(id);
        btn?.classList.toggle('active', on);
        btn?.setAttribute('aria-pressed', on ? 'true' : 'false');
    });
    if (persist) { try { localStorage.setItem(VIEW_MODE_STORAGE_KEY, currentViewMode); } catch {} }
    if (!movieGrid || !feed?.items) return;
    const kind = isCinema ? 'wide' : 'poster';
    movieGrid.querySelectorAll('.movie-card').forEach(card => {
        const item = feed.items.get(`${card.dataset.source}:${card.dataset.slug}`);
        const img = card.querySelector('img.movie-poster');
        if (item && img) MovieImages.apply(img, item, kind);
    });
    if (anchor) {
        const shift = anchor.card.getBoundingClientRect().top - anchor.top;
        if (shift) window.scrollBy(0, shift);
    }
}

let feed = null;
let feedObserver = null;
let feedScrollBound = false;

const CATEGORY_TITLES = {
    'moi': 'Phim mới cập nhật',
    'chieurap': 'Chiếu rạp',
    'thuyetminh': 'Thuyết minh',
    'longtieng': 'Lồng tiếng',
    'bo': 'Phim bộ',
    'le': 'Phim lẻ',
    'hoathinh': 'Anime',
    'tvshows': 'TV Shows',
    'livetv': 'Truyền hình & luồng trực tiếp',
    'favorites': 'Danh sách của tôi'
};

function isDubbedSource() {
    return currentSource === 'thuyetminh' || currentSource === 'longtieng';
}

function sourceLabel(id = currentSource) {
    return MovieService.SOURCES.find(s => s.id === id)?.name || String(id).toUpperCase();
}

function filterLabel(list, slug, fallback) {
    const hit = (list || []).find(entry => entry.id === slug);
    return hit ? hit.name : (fallback || slug);
}

function feedKeyFor() {
    if (currentSearchKeyword) return `search|${currentSearchKeyword}|${currentSource}|${currentAudioFilter}`;
    if (currentCategory === 'favorites') return 'favorites';
    return `list|${currentSource}|${currentCategory}|${currentGenre}|${currentCountry}|${currentAudioFilter}`;
}

function newFeed() {
    feed = {
        key: feedKeyFor(),
        mode: currentSearchKeyword ? 'search' : (currentCategory === 'favorites' ? 'favorites' : 'list'),
        page: 0,
        loading: false,
        done: false,
        emptyStreak: 0,
        seen: new Set(),
        items: new Map(),
        count: 0
    };
    return feed;
}

function audioFiltered(items) {
    if (currentAudioFilter === 'thuyetminh') return items.filter(it => it.hasThuyetMinh);
    if (currentAudioFilter === 'longtieng') return items.filter(it => it.hasLongTieng);
    if (currentAudioFilter === 'chieurap') return items.filter(it => it.isChieuRap);
    return items;
}

/** One page of whatever list is on screen. */
async function fetchFeedPage(target) {
    const next = target.page + 1;
    if (target.mode === 'search') {
        // The search endpoint answers a single page; there is nothing to append.
        if (next > 1) return [];
        return MovieService.search(currentSearchKeyword, currentSource, currentAudioFilter);
    }
    if (target.mode === 'favorites') {
        if (next > 1) return [];
        return audioFiltered(await MovieService.getFavorites());
    }
    if (currentGenre) return audioFiltered(await MovieService.getByGenre(currentGenre, next));
    if (currentCountry) return audioFiltered(await MovieService.getByCountry(currentCountry, next));
    return audioFiltered(await MovieService.getLatest(currentSource, currentCategory, next));
}

function setFeedFooter(state) {
    const footer = document.getElementById('feed-footer');
    const status = document.getElementById('feed-status');
    const end = document.getElementById('feed-end');
    const retry = document.getElementById('feed-retry-btn');
    const sentinel = document.getElementById('feed-sentinel');
    if (!footer) return;
    footer.dataset.state = state;
    footer.classList.toggle('hidden', state === 'hidden');
    if (status) status.classList.toggle('hidden', state !== 'loading');
    if (end) end.classList.toggle('hidden', state !== 'end');
    if (retry) retry.classList.toggle('hidden', state !== 'error');
    if (sentinel) sentinel.classList.toggle('hidden', state !== 'idle' && state !== 'loading');
}

/**
 * The grid opens with a dozen `.skeleton-card` placeholders. They are a
 * *loading* cover, so the first page that actually brings cards has to take
 * them away — appending next to them leaves a dozen empty boxes sitting above
 * the list for the rest of the session (that is what "loading cover" looked
 * like on screen: twelve blank poster boxes followed by the real cards).
 */
function clearLoadingCovers(grid) {
    if (!grid || typeof grid.querySelectorAll !== 'function') return 0;
    const covers = grid.querySelectorAll('.skeleton-card');
    let removed = 0;
    Array.from(covers || []).forEach(node => {
        if (!node) return;
        if (typeof node.remove === 'function') node.remove();
        else if (node.parentNode && typeof node.parentNode.removeChild === 'function') node.parentNode.removeChild(node);
        removed += 1;
    });
    return removed;
}

/** One line in the grid's own place, for a list that has nothing to show. */
function showGridMessage(grid, message) {
    if (!grid) return;
    grid.innerHTML = `<div class="feed-empty">${escapeHtml(message)}</div>`;
}

/** Why a list came back with nothing — the filter is the usual answer. */
function feedEmptyMessage() {
    if (currentSearchKeyword) return `Không tìm thấy phim nào cho “${currentSearchKeyword}”.`;
    if (currentAudioFilter === 'thuyetminh') return 'Nguồn này không có phim thuyết minh trong danh sách đang chọn.';
    if (currentAudioFilter === 'longtieng') return 'Nguồn này không có phim lồng tiếng trong danh sách đang chọn.';
    if (currentAudioFilter === 'chieurap') return 'Nguồn này không có phim chiếu rạp trong danh sách đang chọn.';
    return 'Danh sách này hiện không có phim.';
}

/**
 * The transient pieces of the feed are meant to live only while a load is in
 * flight: the loading covers, the "loading more" status, its sentinel. A load
 * that has already brought data has to take them away, because a survivor
 * reads as real content — that is exactly what the loading-cover bug looked
 * like on screen (blank poster boxes sitting above the real cards).
 *
 * `settled` says the load finished or brought data, so the covers must be gone;
 * while a feed is genuinely still empty they are allowed to stay.
 *
 * Both roots that load transients into themselves are checked: the movie grid
 * (covers) and the home sections container (skeletons).
 */
function isOnScreen(node) {
    if (!node || node.removed) return false;
    // A placeholder inside a hidden view is not on screen, so it is not a
    // leftover. The fake DOM in the tests has no ancestors: `closest` is null.
    return !node.closest || !node.closest('.hidden');
}

function leftoverTransientNodes(root, settled) {
    const leftovers = [];
    if (settled && root && typeof root.querySelectorAll === 'function') {
        [
            ['.skeleton-card', 'loading cover'],
            ['.home-section-skeleton', 'home section skeleton']
        ].forEach(([selector, what]) => {
            const nodes = Array.from(root.querySelectorAll(selector) || []).filter(isOnScreen);
            if (nodes.length) leftovers.push({ selector, what, count: nodes.length });
        });
    }
    const footer = document.getElementById('feed-footer');
    const state = footer ? (footer.dataset.state || 'idle') : 'idle';
    const status = document.getElementById('feed-status');
    if (state !== 'loading' && isOnScreen(status) && !status.classList.contains('hidden')) {
        leftovers.push({ selector: '#feed-status', what: 'loading status', count: 1 });
    }
    const sentinel = document.getElementById('feed-sentinel');
    if ((state === 'end' || state === 'error') && isOnScreen(sentinel)
        && !sentinel.classList.contains('hidden')) {
        leftovers.push({ selector: '#feed-sentinel', what: 'feed sentinel', count: 1 });
    }
    return leftovers;
}

/**
 * After a load, name whatever transient node it left behind, so a leftover is
 * visible in the console instead of only on screen where it looks like content.
 * Returns the issues it found so a caller (or a test) can act on them.
 */
function auditTransientNodes(grid, context, settled) {
    const leftovers = leftoverTransientNodes(grid, settled);
    leftovers.forEach(issue => {
        console.warn(`[catalog] leftover ${issue.what} after ${context}: `
            + `${issue.count} node(s) still in the DOM (${issue.selector}) — `
            + 'a finished load should have removed or hidden them.');
    });
    renderAuditBanner(context, leftovers);
    return leftovers;
}

/**
 * The audit is a debugging tool, so its banner stays off by default and is
 * switched on from outside: `?audit=1` in the URL, `localStorage['catalog-audit']
 * = '1'`, or `window.CATALOG_AUDIT_DEBUG = true` from the console.
 */
function auditDebugEnabled() {
    try {
        if (window.CATALOG_AUDIT_DEBUG) return true;
        if (/[?&]audit=1(?:&|$)/.test(location.search || '')) return true;
        if (location.search && location.search.includes('audit=0')) return false;
        if (typeof localStorage !== 'undefined' && localStorage.getItem('catalog-audit') === '1') return true;
    } catch (err) {
        // Debug helpers must never break a page they are meant to inspect.
    }
    return false;
}

let auditBannerTimer = null;

/** Show the audit's findings in a small panel, when the debug flag is on. */
function renderAuditBanner(context, leftovers) {
    const banner = document.getElementById('catalog-audit');
    if (!banner) return;
    if (!auditDebugEnabled() || !leftovers.length) {
        banner.classList.add('hidden');
        banner.innerHTML = '';
        return;
    }
    const rows = leftovers.map(issue =>
        `<li>${escapeHtml(issue.what)} ×${issue.count} <code>${escapeHtml(issue.selector)}</code></li>`
    ).join('');
    banner.innerHTML = `
        <div class="catalog-audit-head">
            <strong>Node tạm còn sót sau khi tải</strong>
            <button type="button" class="catalog-audit-close" aria-label="Đóng">&times;</button>
        </div>
        <p class="catalog-audit-ctx">${escapeHtml(context)}</p>
        <ul>${rows}</ul>
    `;
    banner.classList.remove('hidden');
    banner.querySelector('.catalog-audit-close')?.addEventListener('click', () => {
        banner.classList.add('hidden');
        banner.innerHTML = '';
    });
    if (auditBannerTimer) clearTimeout(auditBannerTimer);
    auditBannerTimer = setTimeout(() => {
        banner.classList.add('hidden');
        banner.innerHTML = '';
    }, 8000);
}

/**
 * Append one page, skipping what is already on screen. Only the new cards get
 * listeners: re-binding the whole grid would double-fire every card click and
 * replace images that are still loading.
 */
function appendToGrid(grid, items, target) {
    if (!grid) return 0;
    const fresh = [];
    (items || []).forEach(item => {
        if (!item || !item.slug) return;
        const key = `${item.source || currentSource}:${item.slug}`;
        if (target.seen.has(key)) return;
        target.seen.add(key);
        target.items?.set(key, item);
        fresh.push(item);
    });
    if (!fresh.length) return 0;
    clearLoadingCovers(grid);

    const stage = document.createElement('div');
    stage.innerHTML = renderMovieCardsHtml(fresh);
    bindCardClicks(stage);
    const fragment = document.createDocumentFragment();
    while (stage.firstChild) fragment.appendChild(stage.firstChild);
    grid.appendChild(fragment);
    ensureRovingTab(grid);
    target.count += fresh.length;
    return fresh.length;
}

function installFeedObserver() {
    const sentinel = document.getElementById('feed-sentinel');
    feedObserver?.disconnect();
    feedObserver = null;
    if (sentinel && typeof IntersectionObserver === 'function') {
        feedObserver = new IntersectionObserver(entries => {
            if (entries.some(entry => entry.isIntersecting)) loadMoreMovies();
        }, { rootMargin: '700px 0px 0px 0px' });
        feedObserver.observe(sentinel);
        return;
    }
    if (!feedScrollBound) {
        feedScrollBound = true;
        window.addEventListener('scroll', () => {
            const footer = document.getElementById('feed-footer');
            if (!footer || footer.classList.contains('hidden')) return;
            if (footer.getBoundingClientRect().top < window.innerHeight + 600) loadMoreMovies();
        }, { passive: true });
    }
}

/** Load the next page of the list on screen. Safe to call often. */
async function loadMoreMovies() {
    const target = feed;
    if (!target || target.loading || target.done) return;
    if (target.key !== feedKeyFor()) return;
    if (target.page >= FEED_PAGE_CAP) {
        target.done = true;
        setFeedFooter('end');
        return;
    }

    target.loading = true;
    setFeedFooter('loading');
    try {
        const items = await fetchFeedPage(target);
        if (feed !== target) return; // the view changed while this was in flight
        const added = appendToGrid(document.getElementById('movie-grid'), items, target);
        if (target.page === 0 && target.mode === 'list' && items.length) {
            target.cachedSignature = MovieService.feedSignature?.(items);
            MovieService.saveFeedPage?.(target.key, items);
        }
        target.page += 1;
        target.emptyStreak = (items.length && !added) ? target.emptyStreak + 1 : 0;
        const countEl = document.getElementById('result-count');
        if (countEl) countEl.textContent = target.count ? `${target.count} phim` : '';
        // Out of titles: the source returned nothing, or a whole page was
        // filtered out by the audio pill twice in a row.
        if (!items.length || target.emptyStreak >= 2) {
            target.done = true;
            // Nothing ever arrived: the placeholders would otherwise stay on
            // screen as twelve empty boxes for a list that has no cards at all.
            if (!target.count) showGridMessage(document.getElementById('movie-grid'), feedEmptyMessage());
            setFeedFooter('end');
        } else {
            setFeedFooter('idle');
        }
    } catch (err) {
        console.error('[catalog] feed page failed:', err);
        if (feed !== target) return;
        if (!target.count) {
            showGridMessage(document.getElementById('movie-grid'),
                `Không tải được dữ liệu từ nguồn ${String(currentSource).toUpperCase()}. Hãy chọn nguồn khác hoặc thử lại.`);
        }
        setFeedFooter('error');
    } finally {
        target.loading = false;
        // The load just touched the DOM; check it cleaned up after itself.
        if (feed === target) {
            auditTransientNodes(document.getElementById('movie-grid'),
                `loading page ${target.page}`, target.count > 0 || target.done);
        }
    }
}

function applyListHeading() {
    const title = document.getElementById('section-title');
    const count = document.getElementById('result-count');
    if (count) count.textContent = '';
    if (!title) return;
    if (currentSearchKeyword) title.textContent = `Kết quả cho “${currentSearchKeyword}”`;
    else if (currentGenre) title.textContent = `Thể loại ${filterLabel(MovieService.GENRES, currentGenre)}`;
    else if (currentCountry) title.textContent = `Quốc gia ${filterLabel(MovieService.COUNTRIES, currentCountry)}`;
    else if (isDubbedSource()) title.textContent = sourceLabel();
    else title.textContent = CATEGORY_TITLES[currentCategory] || 'Danh sách phim';
}

/** Load the first page of the current list and start the scroll feed. */
async function loadFeedView() {
    const grid = document.getElementById('movie-grid');
    if (!grid) return;
    applyListHeading();
    newFeed();
    grid.innerHTML = Array(12).fill('<div class="skeleton-card"></div>').join('');
    setFeedFooter('loading');
    installFeedObserver();
    try {
        await refreshFavSet();
    } catch (err) {
        console.warn('[catalog] favourites unavailable:', err);
    }
    const target = feed;
    let cached = null;
    if (target.mode === 'list') {
        try { cached = await MovieService.getCachedFeed?.(target.key); } catch {}
    }
    if (cached && feed === target) {
        // Last good first page, shown at once; the scroll feed continues from page 2.
        appendToGrid(document.getElementById('movie-grid'), cached.items, target);
        target.page = 1;
        target.cachedCount = cached.items.length;
        target.cachedSignature = MovieService.feedSignature(cached.items);
        const countEl = document.getElementById('result-count');
        if (countEl) countEl.textContent = target.count ? `${target.count} phim` : '';
        setFeedFooter('idle');
        refreshFeedFirstPage(target);
        return;
    }
    await loadMoreMovies();
}

/** Re-fetch page 1 behind a cached view; redraw only when that is safe and something changed. */
async function refreshFeedFirstPage(target) {
    try {
        const items = await fetchFeedPage({ mode: target.mode, page: 0 });
        if (feed !== target || !items.length) return;
        // A fraction of a page is an outage, not news: keep what is on screen.
        if (items.length * 2 < target.cachedCount) return;
        MovieService.saveFeedPage?.(target.key, items);
        if (MovieService.feedSignature(items) === target.cachedSignature) return;
        // The reader already scrolled or loaded more: redrawing would move the page under them.
        if (target.page !== 1 || target.loading || window.scrollY > 300) return;
        const grid = document.getElementById('movie-grid');
        if (!grid) return;
        grid.innerHTML = '';
        target.seen.clear();
        target.items?.clear();
        target.count = 0;
        appendToGrid(grid, items, target);
        target.cachedSignature = MovieService.feedSignature(items);
        target.cachedCount = items.length;
        const countEl = document.getElementById('result-count');
        if (countEl) countEl.textContent = target.count ? `${target.count} phim` : '';
    } catch (err) {
        console.warn('[catalog] background refresh failed:', err);
    }
}

// MARK: - Load Category Movies (Grid View)
async function loadMovies() {
    await loadFeedView();
}

// MARK: - Search Movies
async function searchMovies(keyword = currentSearchKeyword) {
    if (keyword) {
        currentSearchKeyword = keyword;
        MovieService.addRecentSearch(keyword);
    }
    await loadFeedView();
}

// MARK: - Favorites
async function loadFavorites() {
    await loadFeedView();
}

// MARK: - Open Movie Detail Modal
/** "Phim tương tự": other titles from the movie's first genre, shown under the episodes. */
async function loadSimilarMovies(detail) {
    const section = document.getElementById('modal-similar');
    const grid = document.getElementById('modal-similar-grid');
    if (!section || !grid) return;
    section.hidden = true;
    const genre = detail.genreSlugs?.[0];
    if (!genre) return;
    let items = [];
    try { items = await MovieService.getByGenre(genre, 1); } catch { return; }
    // The reader may have moved on to another title while this loaded.
    if (currentMovie?.slug !== detail.slug) return;
    const similar = items.filter(item => item?.slug && item.slug !== detail.slug).slice(0, 8);
    if (!similar.length) return;
    grid.innerHTML = similar.map(item => `
        <button type="button" class="similar-card" data-slug="${escapeAttr(item.slug)}" data-source="${escapeAttr(item.source || currentSource)}" aria-label="${escapeAttr(item.name)}">
            <img loading="lazy" ${MovieImages.attr(item, 'wide')} alt="" width="320" height="180">
            <span class="similar-title">${escapeHtml(item.name)}</span>
            <span class="similar-meta">${escapeHtml([item.year, item.quality].filter(Boolean).join(' · '))}</span>
        </button>`).join('');
    grid.querySelectorAll('.similar-card').forEach(card => {
        card.addEventListener('click', () => openMovieDetail(card.dataset.slug, card.dataset.source));
    });
    section.hidden = false;
}

async function openMovieDetail(slug, source = currentSource) {
    const modal = document.getElementById('movie-modal');
    setDialogOpen(modal, true);

    // Loading state in modal
    document.getElementById('modal-title').textContent = 'Đang tải thông tin phim…';
    document.getElementById('modal-origin').textContent = '';
    document.getElementById('modal-desc').textContent = '';
    document.getElementById('server-tabs').innerHTML = '';
    document.getElementById('modal-similar')?.setAttribute('hidden', '');
    document.getElementById('episodes-grid').innerHTML = '<span class="state-message">Đang tải danh sách tập phim…</span>';

    try {
        const detail = await MovieService.getDetail(slug, source);
        currentMovie = detail;

        document.getElementById('modal-title').textContent = detail.name;
        document.getElementById('modal-origin').textContent = `${detail.origin_name || ''} ${detail.year ? '· ' + detail.year : ''}`;
        const modalBackdrop = document.getElementById('modal-backdrop-img');
        MovieImages.apply(modalBackdrop, { poster: detail.thumb, thumb: detail.poster }, 'hero');
        setOptionalText('modal-year', detail.year);
        setOptionalText('modal-quality', detail.quality);
        setOptionalText('modal-current-ep', detail.episode_current);
        setOptionalText('modal-rating', detail.rating);
        setOptionalText('modal-source-badge', detail.source || source);
        setOptionalText('modal-time', detail.time);
        setOptionalText('modal-genres', detail.genres?.join(', '));
        setOptionalText('modal-countries', detail.countries?.join(', '));
        setOptionalText('modal-cast', (detail.casts || '').split(',').slice(0, 6).join(',').trim());
        setOptionalText('modal-director', detail.director);
        ['cast', 'director', 'genres', 'countries'].forEach(name => {
            const row = document.getElementById(`modal-${name}-row`);
            if (row) row.hidden = !document.getElementById(`modal-${name}`)?.textContent.trim();
        });

        document.getElementById('modal-desc').textContent = detail.description || 'Chưa có tóm tắt cho bộ phim này.';

        // Favorite button
        const favBtn = document.getElementById('modal-fav-btn');
        if (favBtn) {
            setListButtonState(favBtn, favSlugSet.has(detail.slug));
            favBtn.onclick = async () => {
                const isFav = await MovieService.toggleFavorite(detail);
                await refreshFavSet();
                setListButtonState(favBtn, isFav);
                if (currentSpotlightMovie?.slug === detail.slug) {
                    setListButtonState(document.getElementById('hero-fav-btn'), isFav);
                }
                showToast(isFav ? `Đã thêm "${detail.name}" vào Danh sách của tôi` : `Đã bỏ khỏi Danh sách`);
            };
        }

        const continueList = await MovieService.getContinueWatching();
        const continueEntry = continueList.find(c => c.slug === detail.slug);

        // Continue watching banner in detail modal
        const epSection = modal.querySelector('.episodes-section');
        let contBanner = epSection?.querySelector('.modal-continue-banner');
        if (contBanner) contBanner.remove();

        if (continueEntry) {
            contBanner = document.createElement('div');
            contBanner.className = 'modal-continue-banner';
            const pct = MovieService.progressPercent(continueEntry);
            contBanner.innerHTML = `
                <div>
                    <div class="modal-continue-title">Đang xem dở: ${escapeHtml(continueEntry.epName || 'Tập 1')}</div>
                    <div class="modal-continue-sub">${pct > 0 ? `Tiến độ: ${pct}%` : 'Bấm để tiếp tục xem ngay'}</div>
                </div>
                <button class="modal-continue-btn" type="button">
                    <svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor"><polygon points="5 3 19 12 5 21 5 3"/></svg>
                    <span>Tiếp tục xem</span>
                </button>
            `;
            contBanner.querySelector('.modal-continue-btn')?.addEventListener('click', async () => {
                await floatContinueItem(continueEntry);
            });
            const epHeader = epSection?.querySelector('.episodes-header');
            if (epHeader) epHeader.after(contBanner);
            else epSection?.prepend(contBanner);
        }

        renderEpisodes(detail.episodes, continueEntry);

        // The big button does what the reader most likely wants: resume, or start.
        const playBtn = document.getElementById('modal-play-btn');
        const playLabel = document.getElementById('modal-play-label');
        if (playBtn) {
            playLabel.textContent = continueEntry ? `Tiếp tục: ${continueEntry.epName || 'Tập 1'}` : 'Phát nổi';
            playBtn.disabled = !detail.episodes?.some(server => server.items?.length);
            playBtn.onclick = async () => {
                playBtn.disabled = true;
                try {
                    if (continueEntry) await floatContinueItem(continueEntry);
                    else await quickFloatMovie(detail.slug, detail.source || source);
                } finally {
                    playBtn.disabled = false;
                }
            };
        }
        loadSimilarMovies(detail);
        if (!modal.contains(document.activeElement)) {
            modal.querySelector('.server-tab-btn, .ep-btn, #modal-close-btn')?.focus();
        }
    } catch (err) {
        console.error('Failed to get detail:', err);
        currentMovie = null;
        document.getElementById('modal-similar')?.setAttribute('hidden', '');
        document.getElementById('modal-title').textContent = 'Không tải được phim';
        document.getElementById('modal-desc').textContent = 'Kiểm tra kết nối mạng rồi thử lại.';
        document.getElementById('server-tabs').innerHTML = '';
        document.getElementById('episodes-grid').innerHTML = '<button type="button" class="state-retry-btn">Thử tải lại</button>';
        document.querySelector('#episodes-grid .state-retry-btn')?.addEventListener('click', () => openMovieDetail(slug, source));
    }
}

// MARK: - Render Episodes with Multi-Server Switcher & Chunking
function renderEpisodes(episodes, continueEntry = null) {
    const tabsContainer = document.getElementById('server-tabs');
    const grid = document.getElementById('episodes-grid');

    if (!episodes || episodes.length === 0 || !episodes.some(s => s.items?.length)) {
        tabsContainer.innerHTML = '';
        grid.innerHTML = '<span style="color: var(--text-muted); padding: 12px;">Chưa có tập phim nào trên server này.</span>';
        return;
    }

    const validServers = episodes.filter(s => s.items && s.items.length > 0);
    let activeServerIdx = MovieService.preferVietnameseServerIndex(validServers);
    let activeChunk = 0;

    function renderServer(sIdx) {
        const server = validServers[sIdx];
        if (!server) return;

        // Render Tabs
        tabsContainer.innerHTML = validServers.map((s, idx) => {
            let extraClass = '';
            if (s.serverType === 'thuyetminh') {
                extraClass = 'server-tab-tm';
            } else if (s.serverType === 'longtieng') {
                extraClass = 'server-tab-lt';
            }

            return `
                <button class="server-tab-btn ${extraClass} ${idx === sIdx ? 'active' : ''}" data-idx="${idx}">
                    ${escapeHtml(s.serverName)} (${s.items.length} tập)
                </button>
            `;
        }).join('');

        // Bind Tab Clicks
        tabsContainer.querySelectorAll('.server-tab-btn').forEach(btn => {
            btn.addEventListener('click', (e) => {
                const newIdx = parseInt(e.currentTarget.dataset.idx);
                activeServerIdx = newIdx;
                activeChunk = 0;
                renderServer(newIdx);
                tabsContainer.querySelector(`[data-idx="${newIdx}"]`)?.focus();
            });
        });

        // Check if episode chunking is needed (series > 25 episodes)
        const totalEps = server.items.length;
        const chunkSize = 25;
        let chunkTabsHtml = '';

        if (totalEps > chunkSize) {
            if (continueEntry) {
                const watchedIdx = server.items.findIndex(it => (it.slug && it.slug === continueEntry.epSlug) || it.name === continueEntry.epName);
                if (watchedIdx >= 0) {
                    activeChunk = Math.floor(watchedIdx / chunkSize);
                }
            }

            const numChunks = Math.ceil(totalEps / chunkSize);
            const chunkBtns = [];
            for (let c = 0; c < numChunks; c++) {
                const start = c * chunkSize + 1;
                const end = Math.min((c + 1) * chunkSize, totalEps);
                chunkBtns.push(`
                    <button class="ep-chunk-btn ${c === activeChunk ? 'active' : ''}" data-chunk="${c}" type="button">
                        Tập ${start} - ${end}
                    </button>
                `);
            }
            chunkTabsHtml = `<div class="ep-chunk-tabs">${chunkBtns.join('')}</div>`;
        }

        const startIndex = totalEps > chunkSize ? activeChunk * chunkSize : 0;
        const endIndex = totalEps > chunkSize ? Math.min((activeChunk + 1) * chunkSize, totalEps) : totalEps;
        const visibleItems = server.items.slice(startIndex, endIndex);

        const epsHtml = visibleItems.map((ep, localIdx) => {
            const actualIdx = startIndex + localIdx;
            const isWatching = continueEntry && (
                (ep.slug && continueEntry.epSlug === ep.slug) ||
                (ep.name && continueEntry.epName === ep.name)
            );
            return `
                <button class="ep-btn ${isWatching ? 'ep-watching' : ''}" data-index="${actualIdx}" title="${isWatching ? 'Tập đang xem dở — Bấm để phát nổi' : 'Bấm để phát nổi trên Terminal/Cursor'}">
                    ${escapeHtml(ep.name)}${isWatching ? ' • Đang xem' : ''}
                </button>
            `;
        }).join('');

        grid.innerHTML = chunkTabsHtml + `<div class="episodes-buttons-wrap" style="display:flex; flex-wrap:wrap; gap:6px;">${epsHtml}</div>`;

        // Bind Chunk Clicks
        grid.querySelectorAll('.ep-chunk-btn').forEach(btn => {
            btn.addEventListener('click', (e) => {
                activeChunk = parseInt(e.currentTarget.dataset.chunk);
                renderServer(sIdx);
                grid.querySelector(`[data-chunk="${activeChunk}"]`)?.focus();
            });
        });

        // Bind Episode Clicks
        grid.querySelectorAll('.ep-btn').forEach(btn => {
            btn.addEventListener('click', (e) => {
                const idx = parseInt(e.currentTarget.dataset.index);
                const ep = server.items[idx];
                floatEpisode(ep, currentMovie, server, {
                    currentTime: 0,
                    duration: 0,
                    serverIdx: sIdx,
                    epIdx: idx
                });
            });
        });
    }

    renderServer(activeServerIdx);
}

// MARK: - Float Video Request
async function floatEpisode(ep, movie, server, opts = {}) {
    const indices = MovieService.findEpisodeIndices(movie, ep, server);
    const serverIdx = opts.serverIdx != null ? opts.serverIdx : indices.serverIdx;
    const epIdx = opts.epIdx != null ? opts.epIdx : indices.epIdx;
    const resumeAt = opts.currentTime != null ? Number(opts.currentTime) || 0 : 0;

    const srvTag = server?.serverType === 'thuyetminh' ? ' [Thuyết Minh]' : (server?.serverType === 'longtieng' ? ' [Lồng Tiếng]' : '');
    const title = `${movie ? movie.name : 'Movie'}${srvTag} — ${ep.name}`;

    const videoSrc = ep.linkM3u8 || '';
    const embedUrl = ep.linkEmbed || '';
    const movieContext = MovieService.buildMovieContext(movie, serverIdx, epIdx);

    try {
        const res = await chrome.runtime.sendMessage({
            type: 'FLOAT_VIDEO_REQUEST',
            videoInfo: {
                src: videoSrc,
                embedUrl: embedUrl,
                title: title,
                site: 'movie',
                width: 640,
                height: 360,
                currentTime: resumeAt,
                movieContext,
                aiDubEnabled: window.aiDubbing ? window.aiDubbing.enabled : false
            }
        });

        if (res?.success) {
            showToast(`Đang phát nổi "${title}"`);
            if (movie) {
                await MovieService.saveContinueWatching(movie, ep, {
                    currentTime: resumeAt,
                    duration: Number(opts.duration) || 0,
                    serverIdx,
                    epIdx
                });
                loadContinueWatching();
            }
            return true;
        } else {
            showToast(formatFloatError(res));
            return false;
        }
    } catch (err) {
        console.error('Float request failed:', err);
        showToast(err?.message || 'Không mở được video. Thử lại.');
        return false;
    }
}

function formatFloatError(res) {
    const err = (res && res.error) ? String(res.error) : 'Native app not responding';
    if (/not connected|install\.sh/i.test(err)) {
        return `${err}\nChạy scripts/install.sh rồi tải lại extension.`;
    }
    if (/Already opening/i.test(err)) {
        return 'Đang mở cửa sổ khác — đợi giây lát rồi thử lại.';
    }
    if (/timeout/i.test(err)) {
        return `${err}\nTải lại extension hoặc chạy lại install.sh.`;
    }
    return 'Lỗi khởi chạy cửa sổ nổi: ' + err;
}

// MARK: - Toast Notification
function showToast(message) {
    const existing = document.querySelector('.vibe-toast');
    if (existing) existing.remove();

    const toast = document.createElement('div');
    toast.className = 'vibe-toast';
    toast.setAttribute('role', 'status');
    toast.setAttribute('aria-live', 'polite');
    toast.innerHTML = `<span>${escapeHtml(message)}</span>`;
    document.body.appendChild(toast);

    setTimeout(() => {
        toast.style.opacity = '0';
        toast.style.transform = 'translateY(10px)';
        toast.style.transition = 'opacity 0.3s ease, transform 0.3s ease';
        setTimeout(() => toast.remove(), 350);
    }, 3500);
}

function closeModal() {
    if (activeDialog?.id === 'movie-modal') setDialogOpen(activeDialog, false);
    currentMovie = null;
}

function escapeHtml(str) {
    return String(str || '')
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;');
}

function escapeAttr(str) {
    return String(str || '')
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;');
}
