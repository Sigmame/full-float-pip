// popup.js — Popup panel logic

document.addEventListener('DOMContentLoaded', async () => {
    const videoList = document.getElementById('video-list');

    // Get the current active tab
    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
    if (!tab || !tab.id) {
        videoList.innerHTML = '<div class="empty">⚠️ Cannot access current tab</div>';
        return;
    }

    // Check if URL allows content script injection
    if (!tab.url || tab.url.startsWith('chrome://') || tab.url.startsWith('chrome-extension://')) {
        videoList.innerHTML = '<div class="empty">🚫 Video detection not supported on this page<br><span style="font-size:10px;color:#666680;margin-top:4px;display:block;">This extension cannot be used on Chrome internal pages</span></div>';
        return;
    }

    // Request video info from content script
    try {
        const response = await chrome.tabs.sendMessage(tab.id, { type: 'GET_VIDEOS' });
        renderVideos(response?.videos || []);
    } catch (e) {
        // Content script may not be injected, try manual injection
        try {
            await chrome.scripting.executeScript({
                target: { tabId: tab.id },
                files: ['content.js'],
            });
            // Retry request
            setTimeout(async () => {
                try {
                    const response = await chrome.tabs.sendMessage(tab.id, { type: 'GET_VIDEOS' });
                    renderVideos(response?.videos || []);
                } catch {
                    videoList.innerHTML = '<div class="empty">🔍 No videos detected<br><span style="font-size:10px;color:#666680;margin-top:4px;display:block;">Please make sure a video is playing on the page</span></div>';
                }
            }, 800);
        } catch {
            videoList.innerHTML = '<div class="error">⚠️ Cannot inject detection script<br><span style="font-size:10px;margin-top:4px;display:block;">This page may not support extensions</span></div>';
        }
        return;
    }

    function renderVideos(videos) {
        if (!videos || videos.length === 0) {
            videoList.innerHTML = '<div class="empty">🔍 No videos detected<br><span style="font-size:10px;color:#666680;margin-top:4px;display:block;">Please make sure a video is playing on the page</span></div>';
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
          📌 Float
        </button>
      `;
            videoList.appendChild(card);
        });

        // Bind float button events
        document.querySelectorAll('.float-btn').forEach(btn => {
            btn.addEventListener('click', async (e) => {
                const button = e.currentTarget;
                const index = parseInt(button.dataset.index);
                const video = videos[index];

                // Disable button to prevent duplicate clicks
                button.disabled = true;
                button.textContent = '⏳ Connecting...';

                try {
                    // Capture the tab's player settings (caption track incl.
                    // auto-translate, playback rate, yt-player-* localStorage)
                    // so the floating window can reproduce them.
                    const playerPrefs = await capturePlayerPrefs(tab.id, video.site);

                    // Pause the original video
                    await chrome.tabs.sendMessage(tab.id, { type: 'FLOAT_VIDEO' });

                    // Request background to launch native app
                    const result = await chrome.runtime.sendMessage({
                        type: 'FLOAT_VIDEO_REQUEST',
                        videoInfo: video,
                        playerPrefs,
                    });

                    if (result?.success) {
                        button.textContent = '✅ Floating';
                    } else {
                        button.textContent = '❌ Failed';
                        button.title = result?.error || 'Unknown error';
                        setTimeout(() => {
                            button.disabled = false;
                            button.textContent = '📌 Float';
                        }, 2000);
                    }
                } catch (err) {
                    button.textContent = '❌ Error';
                    button.title = err.message;
                    setTimeout(() => {
                        button.disabled = false;
                        button.textContent = '📌 Float';
                    }, 2000);
                }
            });
        });
    }
});

// Captures YouTube player settings from the tab so the floating window can
// mirror them: audio track (dubbed videos), active caption track (incl.
// auto-translate target) or captions explicitly off, playback rate, and all
// yt-player-* localStorage (sticky captions/quality/volume).
// Runs in the page's MAIN world because the player API lives on the page's
// #movie_player element, out of reach of the isolated content-script world.
async function capturePlayerPrefs(tabId, site) {
    if (site !== 'youtube') return null;
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
