// content.js — Injected into video pages to detect and extract <video> elements
(() => {
  'use strict';

  class VideoDetector {
    constructor() {
      this.detectedVideos = [];
      this.observer = null;
    }

    // Detect all <video> elements on the page
    scanForVideos() {
      const videos = document.querySelectorAll('video');
      this.detectedVideos = [];

      videos.forEach((video, index) => {
        const rect = video.getBoundingClientRect();
        // Filter out videos that are too small (usually ads or preview thumbnails)
        if (rect.width < 100 || rect.height < 60) return;

        const info = {
          index,
          src: this._extractSource(video),
          embedUrl: this._getEmbedUrl(),
          width: video.videoWidth || Math.round(rect.width),
          height: video.videoHeight || Math.round(rect.height),
          duration: video.duration || 0,
          currentTime: video.currentTime || 0,
          paused: video.paused,
          title: this._getVideoTitle(),
          pageUrl: window.location.href,
          site: this._detectSite(),
        };
        this.detectedVideos.push(info);
      });

      return this.detectedVideos;
    }

    // Extract video source URL (compatible with different sites)
    _extractSource(video) {
      if (video.src && !video.src.startsWith('blob:')) return video.src;
      const source = video.querySelector('source');
      if (source && source.src && !source.src.startsWith('blob:')) return source.src;
      if (video.currentSrc && !video.currentSrc.startsWith('blob:')) return video.currentSrc;
      // Blob URLs cannot be passed to external apps, return null
      return null;
    }

    // Get video title (using different strategies per site)
    _getVideoTitle() {
      const site = this._detectSite();
      const strategies = {
        youtube: () =>
          document.querySelector('h1.ytd-watch-metadata yt-formatted-string')?.textContent
          || document.querySelector('#title h1')?.textContent,
        tiktok: () => {
          const desc = document.querySelector('[data-e2e="browse-video-desc"]')
            || document.querySelector('[data-e2e="video-desc"]')
            || document.querySelector('h1[data-e2e="user-post-item-desc"]')
            || document.querySelector('span[data-e2e="search-card-video-caption"]')
            || document.querySelector('div[class*="DivTextContainer"]');
          const author = document.querySelector('[data-e2e="browse-user-avatar"]')?.nextElementSibling?.textContent
            || document.querySelector('[data-e2e="video-author-uniqueid"]')?.textContent
            || document.querySelector('h3[data-e2e="user-title"]')?.textContent;
          const text = desc?.textContent?.trim() || '';
          const user = author?.trim() || '';
          if (user && text) return `@${user}: ${text.slice(0, 60)}`;
          if (text) return text.slice(0, 70);
          return document.title || 'TikTok Video';
        },
        bilibili: () =>
          document.querySelector('.video-title')?.textContent
          || document.querySelector('h1[title]')?.textContent
          || document.querySelector('.tit')?.textContent,
        youku: () =>
          document.querySelector('.title')?.textContent,
        iqiyi: () =>
          document.querySelector('.title-txt')?.textContent,
        tencent: () =>
          document.querySelector('.player_title')?.textContent,
        twitch: () =>
          document.querySelector('h2[data-a-target="stream-title"]')?.textContent,
        default: () => document.title,
      };
      return (strategies[site] || strategies.default)()?.trim() || document.title || 'Unknown Video';
    }

    // Generate site-specific embed URL (clean player page without extra UI)
    _getEmbedUrl() {
      const site = this._detectSite();
      const url = window.location.href;

      switch (site) {
        case 'youtube': {
          // YouTube embed triggers Error 153 in WKWebView,
          // so we load the watch page directly + JS injection to isolate the video
          return null;
        }
        case 'tiktok': {
          const idMatch = url.match(/\/video\/(\d+)/) || url.match(/\/v\/(\d+)/);
          if (idMatch) {
            return `https://www.tiktok.com/player/v1/${idMatch[1]}`;
          }
          return null;
        }
        case 'bilibili': {
          // bilibili.com/video/BVxxxx → player.bilibili.com embed
          const bvMatch = url.match(/\/(BV[a-zA-Z0-9]+)/);
          if (bvMatch) {
            return `https://player.bilibili.com/player.html?bvid=${bvMatch[1]}&autoplay=1&high_quality=1&danmaku=0`;
          }
          const avMatch = url.match(/\/av(\d+)/);
          if (avMatch) {
            return `https://player.bilibili.com/player.html?aid=${avMatch[1]}&autoplay=1&high_quality=1&danmaku=0`;
          }
          return null;
        }
        case 'youku': {
          const idMatch = url.match(/id_([^.]+)/);
          if (idMatch) {
            return `https://player.youku.com/embed/${idMatch[1]}`;
          }
          return null;
        }
        case 'twitch': {
          // twitch.tv/CHANNEL → player embed
          const channelMatch = url.match(/twitch\.tv\/([^/?]+)/);
          if (channelMatch && !['directory', 'videos', 'settings'].includes(channelMatch[1])) {
            return `https://player.twitch.tv/?channel=${channelMatch[1]}&parent=localhost&autoplay=true`;
          }
          return null;
        }
        default:
          return null;
      }
    }

    // Detect current site
    _detectSite() {
      const host = window.location.hostname;
      if (host.includes('youtube.com')) return 'youtube';
      if (host.includes('tiktok.com')) return 'tiktok';
      if (host.includes('bilibili.com')) return 'bilibili';
      if (host.includes('youku.com')) return 'youku';
      if (host.includes('iqiyi.com')) return 'iqiyi';
      if (host.includes('netflix.com')) return 'netflix';
      if (host.includes('v.qq.com')) return 'tencent';
      if (host.includes('twitch.tv')) return 'twitch';
      if (host.includes('douyin.com')) return 'douyin';
      return 'generic';
    }

    // Use MutationObserver to watch for dynamically loaded videos
    startObserving() {
      if (this.observer) return;

      this.observer = new MutationObserver((mutations) => {
        let hasNewVideo = false;
        for (const mutation of mutations) {
          if (mutation.type === 'childList') {
            for (const node of mutation.addedNodes) {
              if (node.nodeName === 'VIDEO' ||
                (node.querySelector && node.querySelector('video'))) {
                hasNewVideo = true;
                break;
              }
            }
          }
          if (hasNewVideo) break;
        }
        if (hasNewVideo) {
          // Delay briefly to let the video initialize
          setTimeout(() => {
            this.scanForVideos();
            this._notifyBackground();
          }, 500);
        }
      });

      this.observer.observe(document.body, {
        childList: true,
        subtree: true,
      });
    }

    _notifyBackground() {
      chrome.runtime.sendMessage({
        type: 'VIDEOS_DETECTED',
        videos: this.detectedVideos,
      }).catch(() => { });
    }
  }

  // ========== Initialization ==========
  const detector = new VideoDetector();

  // Initial scan
  const doInitialScan = () => {
    detector.scanForVideos();
    detector._notifyBackground();
  };

  doInitialScan();
  detector.startObserving();

  // SPA deferred rendering compatibility: retry scans multiple times
  setTimeout(doInitialScan, 1500);
  setTimeout(doInitialScan, 4000);

  // SPA navigation detection: rescan on URL changes (YouTube/Bilibili etc. use history.pushState)
  let lastUrl = location.href;
  new MutationObserver(() => {
    if (location.href !== lastUrl) {
      lastUrl = location.href;
      setTimeout(doInitialScan, 800);
      setTimeout(doInitialScan, 2500);
    }
  }).observe(document, { subtree: true, childList: true });

  // Handle messages from popup/background
  chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (message.type === 'GET_VIDEOS') {
      const videos = detector.scanForVideos();
      sendResponse({ videos });
      return true;
    }

    if (message.type === 'FLOAT_VIDEO') {
      const { videoIndex } = message;
      const videoElements = document.querySelectorAll('video');
      // Find the corresponding visible video
      let visibleIndex = 0;
      let targetVideo = null;
      for (const video of videoElements) {
        const rect = video.getBoundingClientRect();
        if (rect.width < 100 || rect.height < 60) continue;
        if (visibleIndex === videoIndex) {
          targetVideo = video;
          break;
        }
        visibleIndex++;
      }

      if (targetVideo) {
        targetVideo.pause();
        sendResponse({
          success: true,
          videoInfo: detector.detectedVideos[videoIndex],
        });
      } else {
        sendResponse({ success: false, error: 'Video not found' });
      }
      return true;
    }

    return false;
  });
})();
