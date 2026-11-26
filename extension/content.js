// content.js — Injected into video pages to detect and extract <video> elements
(() => {
  'use strict';

  class VideoDetector {
    constructor() {
      this.detectedVideos = [];
      this.mainVideo = null;
      this.observer = null;
    }

    collectVideos(root) {
      const videos = [];
      for (const element of root.querySelectorAll('*')) {
        if (element.tagName === 'VIDEO') videos.push(element);
        if (element.shadowRoot) videos.push(...this.collectVideos(element.shadowRoot));
      }
      return videos;
    }

    scanForVideos() {
      const videos = this.collectVideos(document);
      this.detectedVideos = [];
      this.mainVideo = null;
      let mainPlaying = false;
      let mainArea = 0;
      let mainRect = null;

      videos.forEach((video) => {
        const rect = video.getBoundingClientRect();
        // Filter out videos that are too small (usually ads or preview thumbnails)
        if (rect.width < 100 || rect.height < 60 || video.readyState < 2) return;

        const playing = !video.paused && !video.ended;
        const visibleWidth = Math.min(rect.right, window.innerWidth) - Math.max(rect.left, 0);
        const visibleHeight = Math.min(rect.bottom, window.innerHeight) - Math.max(rect.top, 0);
        const area = Math.max(0, visibleWidth) * Math.max(0, visibleHeight);
        if (!area && !playing) return;

        if (mainPlaying && !playing) return;
        if (playing === mainPlaying && area <= mainArea) return;

        this.mainVideo = video;
        mainPlaying = playing;
        mainArea = area;
        mainRect = rect;
      });

      const video = this.mainVideo;
      if (video) {
        this.detectedVideos = [{
          src: this._extractSource(video),
          embedUrl: this._getEmbedUrl(),
          width: video.videoWidth || Math.round(mainRect.width),
          height: video.videoHeight || Math.round(mainRect.height),
          duration: video.duration || 0,
          currentTime: video.currentTime || 0,
          paused: video.paused,
          title: this._getVideoTitle(),
          pageUrl: window.location.href,
          site: this._detectSite(),
        }];
      }

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
      const matchesHost = domain => host === domain || host.endsWith('.' + domain);
      if (matchesHost('youtube.com')) return 'youtube';
      if (matchesHost('bilibili.com')) return 'bilibili';
      if (matchesHost('youku.com')) return 'youku';
      if (matchesHost('iqiyi.com')) return 'iqiyi';
      if (matchesHost('netflix.com')) return 'netflix';
      if (matchesHost('v.qq.com')) return 'tencent';
      if (matchesHost('twitch.tv')) return 'twitch';
      if (matchesHost('douyin.com')) return 'douyin';
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
      if (!detector.mainVideo?.isConnected) detector.scanForVideos();

      if (detector.mainVideo) {
        detector.mainVideo.pause();
        sendResponse({
          success: true,
          videoInfo: detector.detectedVideos[0],
        });
      } else {
        sendResponse({ success: false, error: 'Video not found' });
      }
      return true;
    }

    return false;
  });
})();
