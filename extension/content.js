// content.js — Injected into video pages to detect and extract <video> elements
(() => {
  'use strict';
  if (!globalThis.VibeSiteAccess?.allowsPage(window.location.href)) return;
  if (globalThis.__vibeFloatDetectorLoaded) return;
  globalThis.__vibeFloatDetectorLoaded = true;

  class VideoDetector {
    constructor() {
      this.detectedVideos = [];
      this.observer = null;
      this.scanTimer = null;
      this.lastSignature = '';
    }

    // Detect all <video> elements on the page
    scanForVideos() {
      const videos = document.querySelectorAll('video');
      this.detectedVideos = [];

      videos.forEach((video) => {
        const rect = video.getBoundingClientRect();
        // Filter out videos that are too small (usually ads or preview thumbnails)
        if (rect.width < 100 || rect.height < 60) return;

        const info = {
          index: this.detectedVideos.length,
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
        let shouldScan = location.href !== lastUrl;
        if (shouldScan) lastUrl = location.href;
        for (const mutation of mutations) {
          if (mutation.type === 'childList') {
            for (const node of [...mutation.addedNodes, ...mutation.removedNodes]) {
              if (node.nodeName === 'VIDEO' ||
                (node.querySelector && node.querySelector('video'))) {
                shouldScan = true;
                break;
              }
            }
          }
          if (shouldScan) break;
        }
        if (shouldScan) this.scheduleScan();
      });

      this.observer.observe(document.body, {
        childList: true,
        subtree: true,
      });
      document.addEventListener('loadedmetadata', () => this.scheduleScan(), true);
    }

    scheduleScan(delay = 500) {
      clearTimeout(this.scanTimer);
      this.scanTimer = setTimeout(() => {
        this.scanForVideos();
        this._notifyBackground();
      }, delay);
    }

    _notifyBackground() {
      const signature = JSON.stringify(this.detectedVideos.map(({ index, pageUrl, src }) => [index, pageUrl, src]));
      if (signature === this.lastSignature) return;
      this.lastSignature = signature;
      chrome.runtime.sendMessage({
        type: 'VIDEOS_DETECTED',
        videos: this.detectedVideos,
      }).catch(() => { });
    }
  }

  // ========== Initialization ==========
  const detector = new VideoDetector();
  let lastUrl = location.href;

  // Initial scan
  const doInitialScan = () => {
    detector.scanForVideos();
    detector._notifyBackground();
  };

  doInitialScan();
  detector.startObserving();

  // SPA deferred rendering compatibility: retry scans multiple times
  setTimeout(doInitialScan, 1500);

  // Handle messages from popup/background
  chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (message.type === 'GET_VIDEOS') {
      const videos = detector.scanForVideos();
      sendResponse({ videos });
      return true;
    }

    if (message.type === 'FLOAT_VIDEO') {
      const { videoIndex } = message;
      detector.scanForVideos();
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

      if (targetVideo && detector.detectedVideos[videoIndex]) {
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

    if (message.type === 'FLOAT_PAUSE') {
      const videoElements = document.querySelectorAll('video');
      for (const video of videoElements) {
        try { video.pause(); } catch(e) {}
      }
      sendResponse({ success: true });
      return true;
    }

    return false;
  });
})();
