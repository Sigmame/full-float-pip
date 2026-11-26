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
                    // Pause the original video
                    await chrome.tabs.sendMessage(tab.id, { type: 'FLOAT_VIDEO' });

                    // Request background to launch native app
                    const result = await chrome.runtime.sendMessage({
                        type: 'FLOAT_VIDEO_REQUEST',
                        videoInfo: video,
                        tabId: tab.id,
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
