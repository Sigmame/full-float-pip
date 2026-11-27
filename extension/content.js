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

  // Mirrors the float window on the tab's video, like Chrome's PiP placeholder: a grey overlay while the float opens,
  // "Playing in PiP" while it is open (the tab's video stays paused), and the float's position copied back on close.
  const floatSession = {
    host: null,
    state: null, // 'opening' | 'floating' | 'failed'

    start(video) {
      if (this.host) return;
      const wasPlaying = !video.paused && !video.ended;
      video.pause();
      const host = document.createElement('float-video-status');
      host.style.cssText = 'position:fixed;z-index:2147483647;display:flex;flex-direction:column;align-items:center;' +
        'justify-content:center;gap:12px;text-align:center;background:rgba(24,24,24,.6);backdrop-filter:grayscale(1);' +
        '-webkit-backdrop-filter:grayscale(1);color:#fff;font:600 15px/1.3 -apple-system,system-ui,sans-serif;' +
        'cursor:progress;transition:opacity .2s;';
      // Built node by node: YouTube enforces Trusted Types, which rejects innerHTML.
      const style = document.createElement('style');
      style.textContent = '.spinner{width:44px;height:44px;border:4px solid rgba(255,255,255,.25);' +
        'border-top-color:#fff;border-radius:50%;animation:spin .9s linear infinite}' +
        '@keyframes spin{to{transform:rotate(360deg)}}.detail{font-weight:400;font-size:12px;opacity:.8;max-width:80%}';
      const spinner = document.createElement('div');
      spinner.className = 'spinner';
      const text = document.createElement('div');
      text.textContent = 'Opening PiP…';
      const detail = document.createElement('div');
      detail.className = 'detail';
      host.attachShadow({ mode: 'closed' }).append(style, spinner, text, detail);
      host.addEventListener('click', () => this.returnHere());
      (document.fullscreenElement || document.documentElement).appendChild(host);

      Object.assign(this, { host, video, wasPlaying, state: 'opening', href: location.href, parts: { spinner, text, detail } });
      // Playing here while the float is open would play the video twice.
      this.onPlay = () => {
        video.pause();
        this.returnHere();
      };
      video.addEventListener('play', this.onPlay);
      // The window may still have opened, so a timeout doesn't resume the tab's video.
      this.timer = setTimeout(() => this.failed('No response from the FloatVideo app', false), 20000);
      const place = () => {
        if (this.host !== host) return;
        // Another page (SPA navigation) is no longer the floated video.
        if (location.href !== this.href) return this.end();
        const r = video.getBoundingClientRect();
        Object.assign(host.style, { left: r.left + 'px', top: r.top + 'px', width: r.width + 'px', height: r.height + 'px' });
        requestAnimationFrame(place);
      };
      place();
    },

    opened() {
      if (this.state !== 'opening') return;
      clearTimeout(this.timer);
      this.state = 'floating';
      this.parts.spinner.remove();
      this.parts.text.textContent = 'Playing in PiP';
      this.parts.detail.textContent = 'Click or press P to continue here';
      this.host.style.cursor = 'pointer';
    },

    // Closes the float; its position comes back as FLOAT_STATUS 'closed' with resume set.
    returnHere() {
      if (this.state !== 'floating') return;
      chrome.runtime.sendMessage({ type: 'RETURN_TO_TAB' }).then(r => {
        if (!r?.success) this.end();
      }).catch(() => this.end());
    },

    closed(currentTime, resume) {
      const { video } = this;
      if (!this.end()) return;
      if (typeof currentTime === 'number') video.currentTime = currentTime;
      if (resume) video.play().catch(() => { });
    },

    failed(error, resume = true) {
      if (this.state !== 'opening') return;
      const { video, wasPlaying } = this;
      clearTimeout(this.timer);
      this.state = 'failed';
      video.removeEventListener('play', this.onPlay);
      this.parts.spinner.remove();
      this.parts.text.textContent = "Couldn't open PiP";
      this.parts.detail.textContent = error || '';
      setTimeout(() => {
        this.end();
        if (resume && wasPlaying) video.play().catch(() => { });
      }, 2500);
    },

    // Removes the overlay and stops mirroring; false if nothing was shown.
    end() {
      const { host } = this;
      if (!host) return false;
      clearTimeout(this.timer);
      this.video.removeEventListener('play', this.onPlay);
      this.host = null;
      this.state = null;
      host.style.opacity = '0';
      setTimeout(() => host.remove(), 200);
      return true;
    },
  };

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

  document.addEventListener('keydown', (e) => {
    if (!e.isTrusted || e.code !== 'KeyP' || e.ctrlKey || e.metaKey || e.altKey || e.shiftKey || e.repeat) return;
    const target = e.composedPath()[0];
    if (['INPUT', 'TEXTAREA', 'SELECT'].includes(target.tagName) || target.isContentEditable) return;

    // P again brings the video back from the float; while it opens, P does nothing.
    if (floatSession.host) {
      e.preventDefault();
      e.stopPropagation();
      floatSession.returnHere();
      return;
    }
    const [video] = detector.scanForVideos();
    if (!video || !chrome.runtime?.id) return;

    e.preventDefault();
    e.stopPropagation();
    floatSession.start(detector.mainVideo);
    // Success and asynchronous failures arrive as FLOAT_STATUS.
    chrome.runtime.sendMessage({ type: 'FLOAT_HOTKEY', videoInfo: video }).then(r => {
      if (!r?.success) floatSession.failed(r?.error);
    }).catch(err => floatSession.failed(err.message));
  }, true);

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
        floatSession.start(detector.mainVideo);
        sendResponse({
          success: true,
          videoInfo: detector.detectedVideos[0],
        });
      } else {
        sendResponse({ success: false, error: 'Video not found' });
      }
      return true;
    }

    if (message.type === 'FLOAT_STATUS') {
      if (message.status === 'opened') floatSession.opened();
      else if (message.status === 'failed') floatSession.failed(message.error);
      else if (message.status === 'closed') floatSession.closed(message.currentTime, message.resume);
    }

    return false;
  });
})();
