// background.js — Service Worker: message hub + Native Messaging communication

importScripts('movie-service.js');

const NATIVE_HOST_NAME = 'com.aspect.floatvideo';

class FloatVideoManager {
    constructor() {
        this.nativePort = null;
        this.tabVideos = new Map(); // tabId -> videoInfo[]
        this.isConnecting = false;
        this.floatingInProgress = false;
        this.lastStatus = {};
        this._pendingCommandResolve = null;
        this._pendingOpenResolve = null;
    }

    // Establish persistent connection with Native App
    connectNative() {
        if (this.nativePort || this.isConnecting) return true;
        this.isConnecting = true;

        try {
            this.nativePort = chrome.runtime.connectNative(NATIVE_HOST_NAME);

            this.nativePort.onMessage.addListener((msg) => {
                console.log('[FloatVideo] Native response:', msg);
                this._handleNativeMessage(msg);
            });

            this.nativePort.onDisconnect.addListener(() => {
                const err = chrome.runtime.lastError;
                console.warn('[FloatVideo] Native port disconnected:', err?.message || 'unknown');
                this.nativePort = null;
                this.isConnecting = false;
            });

            this.isConnecting = false;
            return true;
        } catch (e) {
            console.error('[FloatVideo] Failed to connect native app:', e);
            this.isConnecting = false;
            return false;
        }
    }

    // Send float video command to Native App
    async floatVideo(videoInfo, playerPrefs) {
        // Prevent duplicate requests from rapid double-clicks
        if (this.floatingInProgress) {
            return { success: false, error: 'Already opening a video' };
        }
        this.floatingInProgress = true;

        try {
            return await this._doFloatVideo(videoInfo, playerPrefs);
        } finally {
            this.floatingInProgress = false;
        }
    }

    async _doFloatVideo(videoInfo, playerPrefs) {
        // Note: Restart the native process every time to ensure clean WKWebView state
        // macOS 12+ deprecated WKProcessPool, making in-process Web Content Process isolation impossible
        // The only reliable method is to restart the entire native app process
        if (this.nativePort) {
            // Notify native app to close current window, then disconnect
            try { this.nativePort.postMessage({ action: 'close' }); } catch(e) {}
            this.nativePort.disconnect();
            this.nativePort = null;
            this.isConnecting = false;
            // Wait for the old process to fully exit
            await new Promise(r => setTimeout(r, 300));
        }

        if (!this.connectNative() || !this.nativePort) {
            return { success: false, error: 'Native app not connected. Please run install.sh first.' };
        }

        // Resolve short TikTok links (vt.tiktok.com)
        if (videoInfo.pageUrl && (videoInfo.pageUrl.includes('vt.tiktok.com') || videoInfo.pageUrl.includes('vm.tiktok.com'))) {
            try {
                const res = await fetch(videoInfo.pageUrl, { method: 'HEAD', redirect: 'follow' });
                if (res.url && res.url !== videoInfo.pageUrl) {
                    videoInfo.pageUrl = res.url;
                    const idMatch = res.url.match(/\/video\/(\d+)/);
                    if (idMatch && !videoInfo.embedUrl) {
                        videoInfo.embedUrl = `https://www.tiktok.com/player/v1/${idMatch[1]}`;
                    }
                }
            } catch (e) {
                console.warn('[FloatVideo] Failed to resolve short TikTok url:', e);
            }
        }

        // Proportional fit into viewport preserving aspect ratio
        const origW = videoInfo.width || (videoInfo.site === 'tiktok' ? 340 : 640);
        const origH = videoInfo.height || (videoInfo.site === 'tiktok' ? 604 : 360);
        const ratio = origW / origH;
        let w, h;

        if (videoInfo.site === 'tiktok' || ratio < 0.8) {
            // Vertical smartphone window (9:16) for TikTok / Reels / Shorts
            w = 340;
            const targetRatio = (ratio > 0.3 && ratio < 1.0) ? ratio : (9 / 16);
            h = Math.round(w / targetRatio);
            if (h > 640) h = 640;
            if (h < 520) h = 568;
        } else {
            const downscale = Math.min(960 / origW, 540 / origH, 1);
            w = Math.round(origW * downscale);
            h = Math.round(origH * downscale);
            if (w < 320) { w = 320; h = Math.round(w / ratio); }
            if (h < 180) { h = 180; w = Math.round(h * ratio); }
        }

        const message = {
            action: 'open',
            url: videoInfo.pageUrl || '',
            videoSrc: videoInfo.src || '',
            embedUrl: videoInfo.embedUrl || '',
            title: videoInfo.title || 'Float Video',
            site: videoInfo.site || 'generic',
            width: w,
            height: h,
            currentTime: videoInfo.currentTime || 0,
        };

        // Playlist context for native prev/next episode (pass through unchanged)
        if (videoInfo.movieContext && typeof videoInfo.movieContext === 'object') {
            message.movieContext = videoInfo.movieContext;
        }
        if (videoInfo.preferEmbed) {
            message.preferEmbed = true;
        }

        // Player settings captured from the tab (captions/translate, rate,
        // sticky yt-player-* localStorage) — mirrored into the float window.
        if (videoInfo.site === 'youtube' && playerPrefs) {
            message.playerPrefs = playerPrefs;
        }

        // Get YouTube cookies and attach to the message
        if (videoInfo.site === 'youtube') {
            try {
                const ytCookies = await chrome.cookies.getAll({ domain: '.youtube.com' });
                const googleCookies = await chrome.cookies.getAll({ domain: '.google.com' });
                const allCookies = [...ytCookies, ...googleCookies];
                message.cookies = allCookies.map(c => ({
                    name: c.name,
                    value: c.value,
                    domain: c.domain,
                    path: c.path,
                    secure: c.secure,
                    httpOnly: c.httpOnly,
                }));
                console.log(`[FloatVideo] Sending ${message.cookies.length} cookies`);
            } catch (e) {
                console.warn('[FloatVideo] Failed to get cookies:', e);
                message.cookies = [];
            }
        }

        try {
            const opened = await new Promise((resolve) => {
                const timer = setTimeout(() => {
                    if (this._pendingOpenResolve) {
                        this._pendingOpenResolve = null;
                        resolve({ success: false, error: 'Cửa sổ nổi không mở được (timeout). Thử lại hoặc chạy scripts/install.sh.' });
                    }
                }, 8000);

                this._pendingOpenResolve = (msg) => {
                    clearTimeout(timer);
                    if (msg?.type === 'error') {
                        resolve({ success: false, error: msg.error || 'Native error' });
                        return;
                    }
                    if (msg?.status === 'opened') {
                        resolve({ success: true, title: msg.title || message.title });
                        return;
                    }
                    // Keep waiting for opened / error.
                };

                try {
                    this.nativePort.postMessage(message);
                } catch (e) {
                    clearTimeout(timer);
                    this._pendingOpenResolve = null;
                    resolve({ success: false, error: e.message });
                }
            });
            return opened;
        } catch (e) {
            console.error('[FloatVideo] Send message failed:', e);
            return { success: false, error: e.message };
        }
    }

    // Close floating window
    closeFloat() {
        if (this.nativePort) {
            try {
                this.nativePort.postMessage({ action: 'close' });
            } catch (e) {
                console.warn('[FloatVideo] Close message failed:', e);
            }
        }
    }

    _handleNativeMessage(msg) {
        if (msg?.type === 'PROGRESS') {
            this._saveProgress(msg);
            return;
        }
        if (msg.type === 'error') {
            console.error('[FloatVideo] Native error:', msg.error);
        }
        if (msg && typeof msg === 'object') {
            this.lastStatus = { ...this.lastStatus, ...msg };
            this._broadcastNativeStatus(this.lastStatus);
        }
        if (this._pendingOpenResolve && (msg?.status === 'opened' || msg?.type === 'error')) {
            const resolve = this._pendingOpenResolve;
            this._pendingOpenResolve = null;
            resolve(msg);
        }
        if (this._pendingCommandResolve) {
            const resolve = this._pendingCommandResolve;
            this._pendingCommandResolve = null;
            resolve({ success: msg.type !== 'error', ...msg });
        }
    }

    _broadcastNativeStatus(status) {
        try {
            chrome.runtime.sendMessage({
                type: 'NATIVE_STATUS_BROADCAST',
                ...status
            }).catch(() => {});
        } catch (_) {
            // No open extension pages listening — fine.
        }
    }

    _saveProgress(msg) {
        try {
            if (typeof MovieService !== 'undefined' && MovieService.applyProgressUpdate) {
                MovieService.applyProgressUpdate(msg).catch((e) => {
                    console.warn('[FloatVideo] Progress save failed:', e);
                });
                return;
            }
        } catch (e) {
            console.warn('[FloatVideo] Progress helper unavailable:', e);
        }
        // Fallback if MovieService failed to load in SW
        chrome.storage.local.get(['vibe_continue_watching'], (res) => {
            const list = res.vibe_continue_watching || [];
            const prev = list.find(it => it.slug === msg.slug) || {};
            const entry = {
                slug: msg.slug,
                name: msg.name || prev.name || '',
                origin_name: prev.origin_name || '',
                poster: msg.poster || prev.poster || '',
                source: msg.source || prev.source || 'kkphim',
                epName: msg.epName || prev.epName || '',
                epSlug: msg.epSlug || prev.epSlug || '',
                linkM3u8: msg.linkM3u8 || prev.linkM3u8 || '',
                linkEmbed: msg.linkEmbed || prev.linkEmbed || '',
                currentTime: Number(msg.currentTime) || 0,
                duration: Number(msg.duration) || Number(prev.duration) || 0,
                serverIdx: msg.serverIdx != null ? Number(msg.serverIdx) || 0 : (prev.serverIdx ?? 0),
                epIdx: msg.epIdx != null ? Number(msg.epIdx) || 0 : (prev.epIdx ?? 0),
                updatedAt: Date.now()
            };
            const next = [entry, ...list.filter(it => it.slug !== msg.slug)].slice(0, 10);
            chrome.storage.local.set({ vibe_continue_watching: next });
        });
    }

    async sendCommand(action, value) {
        if (!this.nativePort) {
            this.connectNative();
        }
        if (!this.nativePort) {
            return { success: false, error: 'Native app not connected' };
        }
        return new Promise((resolve) => {
            const timer = setTimeout(() => {
                if (this._pendingCommandResolve) {
                    this._pendingCommandResolve = null;
                    resolve({ success: true, ...this.lastStatus, timedOut: true });
                }
            }, 1200);
            this._pendingCommandResolve = (result) => {
                clearTimeout(timer);
                resolve(result);
            };
            try {
                this.nativePort.postMessage({ action, value });
            } catch (e) {
                clearTimeout(timer);
                this._pendingCommandResolve = null;
                resolve({ success: false, error: e.message });
            }
        });
    }
}

// Singleton
const manager = new FloatVideoManager();

// Listen for messages from Content Script and Popup
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    switch (message.type) {
        case 'VIDEOS_DETECTED': {
            if (sender.tab) {
                manager.tabVideos.set(sender.tab.id, message.videos);
                const count = message.videos.length;
                chrome.action.setBadgeText({
                    text: count > 0 ? String(count) : '',
                    tabId: sender.tab.id,
                });
                chrome.action.setBadgeBackgroundColor({
                    color: '#48484a',
                    tabId: sender.tab.id,
                });
                if (chrome.action.setBadgeTextColor) {
                    chrome.action.setBadgeTextColor({
                        color: '#ffffff',
                        tabId: sender.tab.id,
                    });
                }
            }
            sendResponse({ ok: true });
            break;
        }

        case 'FLOAT_VIDEO_REQUEST': {
            (async () => {
                const result = await manager.floatVideo(message.videoInfo, message.playerPrefs || null);
                sendResponse(result);
            })();
            break;
        }

        case 'GET_TAB_VIDEOS': {
            const videos = manager.tabVideos.get(message.tabId) || [];
            sendResponse({ videos });
            break;
        }

        case 'CLOSE_FLOAT': {
            manager.closeFloat();
            sendResponse({ success: true });
            break;
        }

        case 'NATIVE_COMMAND': {
            (async () => {
                const result = await manager.sendCommand(message.action, message.value);
                sendResponse(result);
            })();
            break;
        }

        case 'GET_NATIVE_STATUS': {
            (async () => {
                if (!manager.nativePort) manager.connectNative();
                if (manager.nativePort) {
                    const result = await manager.sendCommand('getStatus');
                    // Prefer native answer; fall back to preferred ON when absent.
                    if (typeof result?.isGhost !== 'boolean') {
                        result.isGhost = manager.lastStatus?.isGhost ?? true;
                    }
                    sendResponse(result);
                } else {
                    sendResponse({
                        success: false,
                        ...manager.lastStatus,
                        isGhost: typeof manager.lastStatus?.isGhost === 'boolean'
                            ? manager.lastStatus.isGhost
                            : true
                    });
                }
            })();
            break;
        }

        default:
            sendResponse({ error: 'Unknown message type' });
    }
    return true; // Keep the message channel open
});

// Clean up when tab is closed
chrome.tabs.onRemoved.addListener((tabId) => {
    manager.tabVideos.delete(tabId);
});

// Reset when tab is updated
chrome.tabs.onUpdated.addListener((tabId, changeInfo) => {
    if (changeInfo.status === 'loading') {
        manager.tabVideos.delete(tabId);
        chrome.action.setBadgeText({ text: '', tabId });
    }
});
