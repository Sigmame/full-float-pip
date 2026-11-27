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

// Captures YouTube player settings from the tab so the floating window can
// mirror them: audio track (dubbed videos), active caption track (incl.
// auto-translate target) or captions explicitly off, playback rate, and all
// yt-player-* localStorage (sticky captions/quality/volume).
// Runs in the page's MAIN world because the player API lives on the page's
// #movie_player element, out of reach of the isolated content-script world.
async function capturePlayerPrefs(tabId) {
    try {
        const [res] = await chrome.scripting.executeScript({
            target: { tabId },
            world: 'MAIN',
            func: () => {
                const out = {
                    localStorage: {}, captionTrack: null, captionsOff: false,
                    audioTrack: null, playbackRate: 1,
                };
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
                    // During an ad the player reports the AD's tracks; capturing
                    // then would mirror the wrong state (e.g. "captions off").
                    const inAd = !!(p && p.classList &&
                        (p.classList.contains('ad-showing') || p.classList.contains('ad-interrupting')));
                    if (p && !inAd && typeof p.getOption === 'function') {
                        const t = p.getOption('captions', 'track');
                        if (t && t.languageCode) {
                            out.captionTrack = { languageCode: t.languageCode };
                            if (t.kind) out.captionTrack.kind = t.kind;
                            if (t.vss_id) out.captionTrack.vssId = t.vss_id;
                            if (t.translationLanguage && t.translationLanguage.languageCode) {
                                out.captionTrack.translationLanguage = {
                                    languageCode: t.translationLanguage.languageCode,
                                };
                            }
                        } else {
                            // Explicit "off": otherwise the floating window keeps
                            // whatever captions YouTube auto-enables there.
                            out.captionsOff = true;
                        }
                    }
                    if (p && !inAd && typeof p.getAudioTrack === 'function' &&
                        typeof p.getAvailableAudioTracks === 'function') {
                        const cur = p.getAudioTrack();
                        const info = cur && typeof cur.getLanguageInfo === 'function'
                            ? cur.getLanguageInfo() : null;
                        // Only dubbed (multi-track) videos have a choice to mirror;
                        // the float window's different language would otherwise
                        // make YouTube pick another (often auto-dubbed) track.
                        if ((p.getAvailableAudioTracks() || []).length > 1 && info && info.id) {
                            out.audioTrack = { id: info.id };
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
        return null; // non-fatal: float without prefs
    }
}

class FloatVideoManager {
    constructor() {
        this.nativePort = null;
        this.tabVideos = new Map(); // tabId -> videoInfo[]
        this.isConnecting = false;
        this.floatingInProgress = false;
        this.pendingTabId = null; // tab waiting for FLOAT_STATUS
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
                this._sendFloatStatus('failed', err?.message || 'The FloatVideo app quit');
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
    async floatVideo(videoInfo, tabId) {
        // Prevent duplicate requests from rapid double-clicks
        if (this.floatingInProgress) {
            return { success: false, error: 'Already opening a video' };
        }
        this.floatingInProgress = true;

        try {
            const result = await this._doFloatVideo(videoInfo, tabId);
            if (!result.success) this._sendFloatStatus('failed', result.error);
            return result;
        } finally {
            this.floatingInProgress = false;
        }
    }

    async _doFloatVideo(videoInfo, tabId) {
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
        this.pendingTabId = tabId;

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

        const tab = await chrome.tabs.get(tabId).catch(() => null);
        const isYouTube = videoInfo.site === 'youtube' && isYouTubeUrl(tab?.url) && isYouTubeUrl(videoInfo.pageUrl);
        const playerPrefs = isYouTube ? await capturePlayerPrefs(tabId) : null;

        // Player settings captured from the tab (captions/translate, rate,
        // sticky yt-player-* localStorage) — mirrored into the float window.
        if (playerPrefs) {
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
            this._sendFloatStatus('failed', msg.error);
        } else if (msg.type === 'status' && msg.status === 'opened') {
            this._sendFloatStatus('opened');
        }
    }

    // Tells the tab that asked for the float whether the window opened, so it can drop its loading overlay.
    _sendFloatStatus(status, error) {
        const tabId = this.pendingTabId;
        if (tabId == null) return;
        this.pendingTabId = null;
        chrome.tabs.sendMessage(tabId, { type: 'FLOAT_STATUS', status, error }).catch(() => { });
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
                const result = await manager.floatVideo(message.videoInfo, message.tabId);
                sendResponse(result);
            })();
            break;
        }

        case 'FLOAT_HOTKEY': {
            if (!sender.tab) {
                sendResponse({ success: false, error: 'Hotkey requests are only accepted from a tab' });
                break;
            }
            (async () => {
                const result = await manager.floatVideo(message.videoInfo, sender.tab.id);
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
