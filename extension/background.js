// background.js — Service Worker: message hub + Native Messaging communication

importScripts('movie-service.js');

const NATIVE_HOST_NAME = 'com.aspect.floatvideo';

// Only these YouTube cookies travel to the native float window. They are what an
// authenticated watch page needs; everything else (analytics, consent, and the
// whole .google.com jar we used to copy) stays in the browser. The native side
// re-checks this list, so widening it here alone is not enough.
const YOUTUBE_SESSION_COOKIE_NAMES = new Set([
    'SID', 'HSID', 'SSID', 'APISID', 'SAPISID', 'SIDCC', 'LOGIN_INFO',
    '__Secure-1PSID', '__Secure-3PSID',
    '__Secure-1PAPISID', '__Secure-3PAPISID',
    '__Secure-1PSIDTS', '__Secure-3PSIDTS',
    '__Secure-1PSIDCC', '__Secure-3PSIDCC',
]);

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

        // Proportional fit into viewport preserving aspect ratio
        const origW = videoInfo.width || 640;
        const origH = videoInfo.height || 360;
        const ratio = origW / origH;
        let w, h;

        if (ratio < 0.8) {
            // Vertical smartphone window (9:16) for Reels / Shorts
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
            title: videoInfo.title || 'VibeFloat',
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
        if (videoInfo.focusSession) {
            message.focusSession = true;
        }
        if (videoInfo.aiDubEnabled) {
            message.aiDubEnabled = true;
        }

        // Player settings captured from the tab (captions/translate, rate,
        // sticky yt-player-* localStorage) — mirrored into the float window.
        if (videoInfo.site === 'youtube' && playerPrefs) {
            message.playerPrefs = playerPrefs;
        }

        // Mirror only the YouTube session cookies the float window needs. This
        // used to also copy the entire .google.com jar and to forward domain /
        // path, which let the payload declare where its cookies landed. The
        // native side cannot honour httpOnly (HTTPCookiePropertyKey has no such
        // key), so the narrower the set, the smaller the blast radius. Never
        // widen this without re-reading docs/security-review.md.
        if (videoInfo.site === 'youtube') {
            try {
                const ytCookies = await chrome.cookies.getAll({ domain: '.youtube.com' });
                message.cookies = ytCookies
                    .filter(c => YOUTUBE_SESSION_COOKIE_NAMES.has(c.name))
                    .map(c => ({
                        name: c.name,
                        value: c.value,
                        secure: c.secure,
                    }));
                console.log(`[FloatVideo] Sending ${message.cookies.length} session cookies`);
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
                if (message.videoInfo && message.videoInfo.aiDubEnabled === undefined) {
                    try {
                        const stored = await chrome.storage.local.get('vibe_ai_dubbing_enabled');
                        message.videoInfo.aiDubEnabled = stored.vibe_ai_dubbing_enabled != null
                            ? Boolean(stored.vibe_ai_dubbing_enabled)
                            : true;
                    } catch (e) {
                        message.videoInfo.aiDubEnabled = true;
                    }
                }
                const result = await manager.floatVideo(message.videoInfo, message.playerPrefs || null);
                if (result && result.success) {
                    const targetTabId = sender?.tab?.id || message.tabId;
                    if (targetTabId) {
                        chrome.tabs.sendMessage(targetTabId, { type: 'FLOAT_PAUSE' }).catch(() => {});
                    }
                }
                sendResponse(result);
            })();
            return true;
        }

        case 'SPEAK_AI_DUB': {
            (async () => {
                if (!manager.nativePort) manager.connectNative();
                if (manager.nativePort) {
                    manager.nativePort.postMessage({
                        action: 'speakAIDub',
                        text: message.text,
                        duration: message.duration || 0,
                        gender: message.gender || 'female'
                    });
                    sendResponse({ success: true });
                } else {
                    sendResponse({ success: false, error: 'Native app not connected' });
                }
            })();
            return true;
        }

        case 'STOP_AI_DUB': {
            if (manager.nativePort) {
                manager.nativePort.postMessage({ action: 'stopAIDub' });
            }
            sendResponse({ success: true });
            break;
        }

        case 'PREFETCH_AI_DUB': {
            if (!manager.nativePort) manager.connectNative();
            if (manager.nativePort && message.text) {
                manager.nativePort.postMessage({
                    action: 'prefetchAIDub',
                    text: message.text
                });
            }
            sendResponse({ success: true });
            break;
        }

        case 'PREFETCH_BATCH_AI_DUB': {
            if (!manager.nativePort) manager.connectNative();
            if (manager.nativePort && Array.isArray(message.texts) && message.texts.length > 0) {
                manager.nativePort.postMessage({
                    action: 'prefetchBatchAIDub',
                    texts: message.texts
                });
            }
            sendResponse({ success: true });
            break;
        }

        case 'SET_AI_DUB_VOICE': {
            if (manager.nativePort) {
                manager.nativePort.postMessage({
                    action: 'setDubVoice',
                    voice: message.voice || message.gender
                });
            }
            sendResponse({ success: true });
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

// One keystroke from Chrome to float the currently playing video. activeTab grants
// access only to the tab on which the user invoked the command.
chrome.commands.onCommand.addListener(async (command, tab) => {
    if (command !== 'float-current-video' || !tab?.id || !/^https?:/.test(tab.url || '')) return;
    try {
        let response;
        try {
            response = await chrome.tabs.sendMessage(tab.id, { type: 'GET_VIDEOS' });
        } catch {
            await chrome.scripting.executeScript({ target: { tabId: tab.id }, files: ['content.js'] });
            response = await chrome.tabs.sendMessage(tab.id, { type: 'GET_VIDEOS' });
        }
        const videos = response?.videos || [];
        const video = videos.find(v => !v.paused) || videos[0];
        if (!video) throw new Error('No visible video');
        const result = await manager.floatVideo(video, null);
        if (!result?.success) throw new Error(result?.error || 'Unable to open player');
        await chrome.tabs.sendMessage(tab.id, { type: 'FLOAT_VIDEO', videoIndex: video.index }).catch(() => {});
        await chrome.tabs.sendMessage(tab.id, { type: 'FLOAT_PAUSE' }).catch(() => {});
        await chrome.action.setTitle({ tabId: tab.id, title: 'VibeFloat · Đang phát nổi' });
    } catch (error) {
        console.warn('[FloatVideo] Shortcut failed:', error);
        await chrome.action.setBadgeBackgroundColor({ tabId: tab.id, color: '#d92d50' });
        await chrome.action.setBadgeText({ tabId: tab.id, text: '!' });
        await chrome.action.setTitle({ tabId: tab.id, title: `VibeFloat · ${error.message}` });
    }
});
