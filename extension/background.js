// background.js — Service Worker: message hub + Native Messaging communication

const NATIVE_HOST_NAME = 'com.aspect.floatvideo';

function isYouTubeUrl(url) {
    try {
        const parsed = new URL(url);
        return parsed.protocol === 'https:' &&
            (parsed.hostname === 'youtube.com' || parsed.hostname.endsWith('.youtube.com'));
    } catch {
        return false;
    }
}

class FloatVideoManager {
    constructor() {
        this.nativePort = null;
        this.tabVideos = new Map(); // tabId -> videoInfo[]
        this.isConnecting = false;
        this.floatingInProgress = false;
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
        // ⭐ Restart the native process every time to ensure clean WKWebView state
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

        // Proportional fit into [320..960] × [180..540] preserving aspect ratio
        // Independent clamping would distort non-16:9 videos before the native
        // app locks the aspect ratio.
        const origW = videoInfo.width || 640;
        const origH = videoInfo.height || 360;
        const ratio = origW / origH;
        const downscale = Math.min(960 / origW, 540 / origH, 1);
        let w = Math.round(origW * downscale);
        let h = Math.round(origH * downscale);
        if (w < 320) { w = 320; h = Math.round(w / ratio); }
        if (h < 180) { h = 180; w = Math.round(h * ratio); }

        const message = {
            action: 'open',
            url: videoInfo.pageUrl,
            videoSrc: videoInfo.src || '',
            embedUrl: videoInfo.embedUrl || '',
            title: videoInfo.title || 'Float Video',
            site: videoInfo.site || 'generic',
            width: w,
            height: h,
            currentTime: videoInfo.currentTime || 0,
        };

        const isYouTube = videoInfo.site === 'youtube' && isYouTubeUrl(videoInfo.pageUrl);

        // Player settings captured from the tab (captions/translate, rate,
        // sticky yt-player-* localStorage) — mirrored into the float window.
        if (isYouTube && playerPrefs) {
            message.playerPrefs = playerPrefs;
        }

        // Get YouTube cookies and attach to the message
        if (isYouTube) {
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
            this.nativePort.postMessage(message);
            return { success: true };
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
        if (msg.type === 'error') {
            console.error('[FloatVideo] Native error:', msg.error);
        }
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
            if (sender.tab) {
                sendResponse({ success: false, error: 'Float requests are only accepted from the popup' });
                break;
            }
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
