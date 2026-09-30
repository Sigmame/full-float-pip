/**
 * VibeFloat AI Dubbing Engine (Lồng tiếng AI từ phụ đề thời gian thực)
 * Features:
 *  - Real-time Subtitle Cue Tracking (HTML5 TextTracks + DOM Caption Observers)
 *  - Microsoft Edge Neural TTS integration via Native Messaging
 *  - Dynamic Rate Scaling (1.0x to 1.45x based on characters per second)
 *  - Intelligent Audio Ducking (Dips video background volume to 28% during speech, restores smoothly)
 *  - High-Fidelity Vietnamese Speech Validation (Filters out ads, English blurbs, URLs)
 *  - Conflict Resolution & Pre-buffering Queue (No overlap, no lag)
 *  - Global API for dubbing controls
 */

(function (root, factory) {
    if (typeof define === 'function' && define.amd) {
        define([], factory);
    } else if (typeof module === 'object' && module.exports) {
        module.exports = factory();
    } else {
        if (typeof location !== 'undefined' && /^https?:$/.test(location.protocol) &&
            !root.VibeSiteAccess?.allowsPage(location.href)) return;
        root.AIDubbingEngine = factory();
        root.aiDubbing = new root.AIDubbingEngine();
    }
}(typeof self !== 'undefined' ? self : this, function () {
    'use strict';

    // Ignore the legacy default-ON preference; enabling now requires a fresh choice.
    const STORAGE_KEY = 'vibe_ai_dubbing_enabled_v2';
    const VOICE_PREF_KEY = 'vibe_ai_dubbing_voice_gender'; // 'female' | 'male'
    const RATE_PREF_KEY = 'vibe_ai_dubbing_base_rate';

    const VI_DIACRITICS = /[àáảãạăắằẳẵặâấầẩẫậèéẻẽẹêếềểễệìíỉĩịòóỏõọôốồổỗộơớờởỡợùúủũụưứừửữựỳýỷỹỵđ]/i;
    const VI_WORDS = /\b(anh|em|toi|ta|minh|ong|ba|co|chu|bac|khong|la|mot|hai|ba|nguoi|nay|trong|da|duoc|cho|voi|cua|gi|sao|the|nhung|phai|biet|di|ve|o|ra|len|xuong|lai|ma|thi|neu|vi|nen|hay|dung|chua|se|dang|cung|de|roi|ca|den|dau|muon|thay|noi|nghe|lam|ay|day|gio|luc|viec|chuyen|nha|tien|troi|song|chet)\b/i;
    const EN_STOP = /\b(the|and|of|to|in|is|you|that|it|he|was|for|on|are|as|with|his|they|at|be|this|from|have|or|by|one|had|not|but|what|all|were|when|we|there|can|an|your|which|their|if|do|will|each|about|how|up|out|them|then|she|many|some|so|these|would|other|into|has|more|her|like|him|see|time|could|no|make|than|first|been|its|who|now|people|my|over|did|down|only|way|find|use|may|water|long|little|very|after|words|just|where|most|get|through|back|much|go|good|new|write|our|me|too|any|day|same|right|look|think|also|around|another|came|come|work|three|must|because|does|part|even|place|well|such|here|take|why|help|put|away|again|off|went|old|great|tell|say|small|every|found|still|between|name|should|home|big|give|air|line|set|own|under|read|last|never|us|left|end|while|might|next|sound|below|saw|something|thought|both|few|those|always|show|large|often|together|asked|house|world|going|want|school|until|quiet|isolation|drifts|rhythms|college|secrets|shifting|circle|classmates|bleed|nights|subtle|academia|entangled|lives|kindle|rate|book)\b/ig;
    const AD_KEYWORDS = /kindle|rate this book|goodreads|amazon|shopee|lazada|tiki|want to read|chapter|edition|subscription|price|review|rating|sign in|subscribe|subtitles by|kkphim|ophim|nguonc|phimmoi|phimapi|resume|loading|tiếp tục xem|bạn đang xem dở/i;

    function isLikelyVietnameseDialogue(t) {
        if (!t || t.length < 2 || t.length > 240) return false;
        if (/[\$€£¥]|\b\d+\.\d{2}\b|\*{3,}|https?:\/\/|\.com\b|\.net\b|www\./i.test(t)) return false;
        if (AD_KEYWORDS.test(t)) return false;
        const enMatches = t.match(EN_STOP);
        if (enMatches && enMatches.length >= 2) {
            const words = t.split(/\s+/).filter(Boolean);
            if (words.length > 0 && (enMatches.length / words.length) >= 0.20) return false;
        }
        return VI_DIACRITICS.test(t) || VI_WORDS.test(t);
    }

    class AIDubbingEngine {
        constructor() {
            this.enabled = false; // Speech requires an explicit opt-in.
            this.voiceGender = 'female'; // 'female' | 'male'
            this.baseRate = 1.20;
            this.minRate = 1.0;
            this.maxRate = 1.6;
            this.duckingRatio = 0.28;
            this.duckingRestoreDelay = 220;

            this.targetVideo = null;
            this.preDuckVolume = 1.0;
            this.isDucked = false;
            this.duckTimer = null;

            this.lastSpokenText = '';
            this.lastSpokenTime = 0;
            this.recentHistory = [];
            this.hasActiveTextTracks = false;
            this.lastTextTrackTime = 0;
            this.domDebounceTimer = null;

            this.timelineCues = [];
            this.ingestedUrls = new Set();
            this.translationCache = new Map();
            this.lastPrefetchPollTime = 0;
            this.lastTimelineSpokenTime = 0;
            this.playbackGeneration = 0;

            this.observer = null;
            this.boundCueListener = this.onCueChange.bind(this);
            this.boundVideoPlay = this.onVideoPlay.bind(this);
            this.boundVideoPause = this.onVideoPause.bind(this);
            this.boundVideoSeeking = this.onVideoSeeking.bind(this);

            this.init();
        }

        async init() {
            try {
                if (typeof chrome !== 'undefined' && chrome.storage && chrome.storage.local) {
                    const data = await chrome.storage.local.get([STORAGE_KEY, VOICE_PREF_KEY, RATE_PREF_KEY]);
                    if (data[STORAGE_KEY] != null) this.enabled = Boolean(data[STORAGE_KEY]);
                    if (data[VOICE_PREF_KEY]) this.voiceGender = data[VOICE_PREF_KEY];
                    if (data[RATE_PREF_KEY]) this.baseRate = Number(data[RATE_PREF_KEY]) || 1.20;
                } else if (typeof localStorage !== 'undefined') {
                    const saved = localStorage.getItem(STORAGE_KEY);
                    if (saved != null) this.enabled = saved === 'true';
                    const savedGender = localStorage.getItem(VOICE_PREF_KEY);
                    if (savedGender) this.voiceGender = savedGender;
                    const savedRate = localStorage.getItem(RATE_PREF_KEY);
                    if (savedRate) this.baseRate = Number(savedRate) || 1.20;
                }
            } catch (e) {}

            // Install network interceptor for .vtt, .srt, and timedtext subtitle streams
            this.installNetworkInterceptors();

            // Periodic timeline sync loop (75ms) and chunk prefetch loop (1200ms)
            if (typeof window !== 'undefined') {
                setInterval(() => this.checkTimeline(), 75);
                setInterval(() => {
                    this.pollChunkAhead();
                    this.scanDomTracks();
                }, 1200);
            }

            if (typeof window !== 'undefined') {
                // Cross-frame relay: listen for cues from embedded iframes & main-world interceptor
                window.addEventListener('message', (e) => {
                    if (!e.data) return;
                    if (e.data.type === '__floatAIDubRelay') {
                        if (e.source === window) return;
                        if (e.data.action === 'stop') {
                            this.stopSpeech();
                        } else if (e.data.action === 'prefetch' && e.data.text) {
                            this.prefetch(e.data.text);
                        } else if (e.data.action === 'speak' && e.data.text) {
                            this.speak(e.data.text, { duration: e.data.duration || 0 });
                        }
                    } else if (e.data.type === '__floatVibeSubtitleData') {
                        if (e.source !== window) return;
                        if (this.isSubtitleUrl(e.data.url) && typeof e.data.content === 'string' && e.data.content.length <= 2 * 1024 * 1024) {
                            this.ingestSubtitleContent(e.data.content, e.data.url || '');
                        }
                    }
                });

                // Listen for extension commands & messages
                if (typeof chrome !== 'undefined' && chrome.runtime && chrome.runtime.onMessage) {
                    chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
                        if (msg.type === 'TOGGLE_AI_DUB') {
                            const next = this.toggle(msg.enabled);
                            sendResponse({ success: true, enabled: next });
                        } else if (msg.type === 'SET_AI_DUB_VOICE') {
                            this.setVoiceGender(msg.gender);
                            sendResponse({ success: true, gender: this.voiceGender });
                        } else if (msg.type === 'GET_AI_DUB_STATUS') {
                            sendResponse({ enabled: this.enabled, gender: this.voiceGender });
                        } else if (msg.type === 'FLOAT_PAUSE') {
                            this.stopSpeech();
                            this.restoreVolume();
                            if (this.targetVideo) {
                                try { this.targetVideo.pause(); } catch(e) {}
                            }
                            sendResponse({ success: true });
                        }
                    });
                }

                // Global bridge functions
                window.__floatToggleAIDub = (explicit) => this.toggle(explicit);
                window.__floatIsAIDubEnabled = () => this.enabled;
                window.__floatSetAIDubVoice = (gender) => this.setVoiceGender(gender);
                window.__floatAIDubText = (text, duration) => this.speak(text, { duration });
                window.__floatAIDubPrefetch = (text) => this.prefetch(text);
            }

            // Periodic video scan for SPA navigation (YouTube, Netflix, etc.)
            this.scanForVideoElement();
            if (typeof window !== 'undefined') {
                setInterval(() => this.scanForVideoElement(), 1500);
                window.addEventListener('yt-navigate-finish', () => {
                    this.timelineCues = [];
                    this.ingestedUrls.clear();
                    this.scanForVideoElement();
                });
                window.addEventListener('popstate', () => this.scanForVideoElement());
            }
        }

        setVoiceGender(gender) {
            this.voiceGender = gender === 'male' ? 'male' : 'female';
            try {
                if (typeof chrome !== 'undefined' && chrome.storage && chrome.storage.local) {
                    chrome.storage.local.set({ [VOICE_PREF_KEY]: this.voiceGender });
                } else if (typeof localStorage !== 'undefined') {
                    localStorage.setItem(VOICE_PREF_KEY, this.voiceGender);
                }
            } catch (e) {}
            this.dispatchStateChangeEvent();
        }

        toggle(explicitState) {
            this.enabled = explicitState !== undefined ? Boolean(explicitState) : !this.enabled;

            try {
                if (typeof chrome !== 'undefined' && chrome.storage && chrome.storage.local) {
                    chrome.storage.local.set({ [STORAGE_KEY]: this.enabled });
                } else if (typeof localStorage !== 'undefined') {
                    localStorage.setItem(STORAGE_KEY, String(this.enabled));
                }
            } catch (e) {}

            if (!this.enabled) {
                this.playbackGeneration++;
                this.stopSpeech();
                this.restoreVolume();
            } else {
                this.scanForVideoElement();
                this.observeSubtitleDOM();
            }

            this.showStatusToast(this.enabled);
            this.dispatchStateChangeEvent();
            return this.enabled;
        }

        dispatchStateChangeEvent() {
            if (typeof window !== 'undefined') {
                window.dispatchEvent(new CustomEvent('aidub-state-change', {
                    detail: { enabled: this.enabled, gender: this.voiceGender }
                }));
            }
        }

        showStatusToast(enabled) {
            if (typeof document === 'undefined') return;
            let toast = document.getElementById('aidub-toast');
            if (!toast) {
                toast = document.createElement('div');
                toast.id = 'aidub-toast';
                toast.style.cssText = `
                    position: fixed;
                    bottom: 24px;
                    right: 24px;
                    background: rgba(20, 20, 20, 0.94);
                    border: 1px solid rgba(255, 69, 97, 0.45);
                    box-shadow: 0 8px 24px rgba(0, 0, 0, 0.85);
                    backdrop-filter: blur(12px);
                    -webkit-backdrop-filter: blur(12px);
                    color: #fff;
                    font-size: 13px;
                    font-weight: 600;
                    padding: 10px 16px;
                    border-radius: 8px;
                    display: flex;
                    align-items: center;
                    gap: 10px;
                    z-index: 2147483647;
                    transition: opacity 0.25s ease, transform 0.25s ease;
                    pointer-events: none;
                    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
                `;
                document.body.appendChild(toast);
            }

            const voiceLabel = this.voiceGender === 'male' ? 'Nam Minh (Nam)' : 'Hoài My (Nữ)';
            const stateText = enabled ? `Đang bật — ${voiceLabel}` : 'Đã tắt';
            const iconSvg = enabled
                ? '<svg width="16" height="16" viewBox="0 0 24 24" fill="#ff4757"><path d="M12 2a3 3 0 0 0-3 3v7a3 3 0 0 0 6 0V5a3 3 0 0 0-3-3Zm5 10a5 5 0 0 1-10 0H5a7 7 0 0 0 6 6.92V21H9v2h6v-2h-2v-2.08A7 7 0 0 0 19 12h-2Z"/></svg>'
                : '<svg width="16" height="16" viewBox="0 0 24 24" fill="#999"><path d="m19 11-1.3-.2a6.9 6.9 0 0 1-2.2 4.1l1.4 1.4A8.9 8.9 0 0 0 19 11ZM4.3 3 3 4.3l4.3 4.3V12a5 5 0 0 0 7.7 4.2l1.7 1.7A6.9 6.9 0 0 1 12 19a7 7 0 0 1-7-7H3a9 9 0 0 0 8 8.9V23h2v-2.1a9 9 0 0 0 4.3-1.4l2.4 2.4 1.3-1.3L4.3 3ZM12 4a3 3 0 0 1 3 3v4.6l2 2V7a5 5 0 0 0-7.7-4.2l1.6 1.6A2.9 2.9 0 0 1 12 4Z"/></svg>';

            toast.innerHTML = `${iconSvg} <span>Lồng tiếng Edge AI: ${stateText}</span>`;
            toast.style.opacity = '1';
            toast.style.transform = 'translateY(0)';

            clearTimeout(this.toastTimer);
            this.toastTimer = setTimeout(() => {
                toast.style.opacity = '0';
                toast.style.transform = 'translateY(8px)';
            }, 2500);
        }

        scanForVideoElement() {
            if (typeof document === 'undefined') return;
            const videos = Array.from(document.querySelectorAll('video'));
            const mainVideo = videos.find(v => {
                const rect = v.getBoundingClientRect();
                return rect.width > 200 && rect.height > 120;
            }) || videos[0];

            if (mainVideo && mainVideo !== this.targetVideo) {
                this.attachVideo(mainVideo);
            }
        }

        attachVideo(video) {
            if (!video || this.targetVideo === video) return;
            this.detachVideo();
            this.targetVideo = video;

            this.boundVideoPlaying = () => {
                this.extractTextTrackCues(video);
                this.scanDomTracks();
                this.pollChunkAhead(video);
            };
            this.boundVideoSeeked = () => this.pollChunkAhead(video);
            let lastPoll = 0;
            this.boundVideoTimeUpdate = () => {
                this.checkTimeline(video);
                const now = Date.now();
                if (now - lastPoll >= 1200) {
                    lastPoll = now;
                    this.pollChunkAhead(video);
                }
            };

            video.addEventListener('play', this.boundVideoPlay);
            video.addEventListener('playing', this.boundVideoPlaying);
            video.addEventListener('pause', this.boundVideoPause);
            video.addEventListener('seeking', this.boundVideoSeeking);
            video.addEventListener('seeked', this.boundVideoSeeked);
            video.addEventListener('timeupdate', this.boundVideoTimeUpdate);

            this.hookTextTracks(video);
            this.extractTextTrackCues(video);
            this.scanDomTracks();
            this.pollChunkAhead(video);
            this.observeSubtitleDOM();
        }

        detachVideo() {
            if (!this.targetVideo) return;
            this.playbackGeneration++;
            this.stopSpeech();
            this.restoreVolume();
            this.targetVideo.removeEventListener('play', this.boundVideoPlay);
            if (this.boundVideoPlaying) this.targetVideo.removeEventListener('playing', this.boundVideoPlaying);
            this.targetVideo.removeEventListener('pause', this.boundVideoPause);
            this.targetVideo.removeEventListener('seeking', this.boundVideoSeeking);
            if (this.boundVideoSeeked) this.targetVideo.removeEventListener('seeked', this.boundVideoSeeked);
            if (this.boundVideoTimeUpdate) this.targetVideo.removeEventListener('timeupdate', this.boundVideoTimeUpdate);
            if (this.boundTrackAdded) this.targetVideo.textTracks?.removeEventListener('addtrack', this.boundTrackAdded);
            if (this.boundTrackChanged) this.targetVideo.textTracks?.removeEventListener('change', this.boundTrackChanged);
            for (const track of Array.from(this.targetVideo.textTracks || [])) track.removeEventListener('cuechange', this.boundCueListener);
            this.targetVideo = null;
            this.timelineCues = [];
            this.ingestedUrls.clear();
            if (this.observer) {
                this.observer.disconnect();
                this.observer = null;
            }
        }

        installNetworkInterceptors() {
            if (typeof window === 'undefined' || window.__vibeSubInterceptorsInstalled) return;
            window.__vibeSubInterceptorsInstalled = true;

            const self = this;
            if (typeof window.fetch === 'function') {
                const origFetch = window.fetch;
                window.fetch = function(...args) {
                    const promise = origFetch.apply(this, args);
                    try {
                        const url = typeof args[0] === 'string' ? args[0] : (args[0]?.url || '');
                        if (self.isSubtitleUrl(url) && !self.ingestedUrls.has(url)) {
                            promise.then(res => {
                                try {
                                    res.clone().text().then(txt => {
                                        if (txt && txt.length > 20) {
                                            self.ingestedUrls.add(url);
                                            self.ingestSubtitleContent(txt, url);
                                        }
                                    }).catch(() => {});
                                } catch (e) {}
                            }).catch(() => {});
                        }
                    } catch (e) {}
                    return promise;
                };
            }

            if (typeof window.XMLHttpRequest === 'function') {
                const origOpen = XMLHttpRequest.prototype.open;
                const origSend = XMLHttpRequest.prototype.send;
                XMLHttpRequest.prototype.open = function(method, url, ...rest) {
                    this.__vibeSubUrl = url;
                    return origOpen.apply(this, [method, url, ...rest]);
                };
                XMLHttpRequest.prototype.send = function(...args) {
                    if (this.__vibeSubUrl && self.isSubtitleUrl(this.__vibeSubUrl) && !self.ingestedUrls.has(this.__vibeSubUrl)) {
                        this.addEventListener('load', () => {
                            try {
                                if (this.responseText && this.responseText.length > 20) {
                                    self.ingestedUrls.add(this.__vibeSubUrl);
                                    self.ingestSubtitleContent(this.responseText, this.__vibeSubUrl);
                                }
                            } catch (e) {}
                        });
                    }
                    return origSend.apply(this, args);
                };
            }
        }

        isSubtitleUrl(url) {
            if (!url || typeof url !== 'string') return false;
            if (/\.(m3u8|ts|m4s|mp4|webm|mp3|aac|png|jpg|jpeg|gif|webp|woff2?)(\?|$)/i.test(url)) return false;
            return /\.(vtt|srt|ass)(\?|$)|timedtext|subtitle|caption|\/sub\//i.test(url);
        }

        parseTimestamp(s) {
            if (!s) return 0;
            const parts = s.trim().replace(',', '.').split(':');
            if (parts.length === 3) {
                return (parseFloat(parts[0]) || 0) * 3600 + (parseFloat(parts[1]) || 0) * 60 + (parseFloat(parts[2]) || 0);
            } else if (parts.length === 2) {
                return (parseFloat(parts[0]) || 0) * 60 + (parseFloat(parts[1]) || 0);
            }
            return parseFloat(s) || 0;
        }

        parseVTTorSRT(text) {
            const cues = [];
            const blocks = text.replace(/\r\n/g, '\n').replace(/\r/g, '\n').split(/\n\n+/);
            const timeRegex = /((?:\d{1,2}:)?\d{2}:\d{2}[\.,]\d{3})\s*-->\s*((?:\d{1,2}:)?\d{2}:\d{2}[\.,]\d{3})/;
            for (const b of blocks) {
                const lines = b.trim().split('\n');
                let timeIdx = -1;
                for (let j = 0; j < lines.length; j++) {
                    if (timeRegex.test(lines[j])) {
                        timeIdx = j;
                        break;
                    }
                }
                if (timeIdx !== -1) {
                    const m = lines[timeIdx].match(timeRegex);
                    const start = this.parseTimestamp(m[1]);
                    const end = this.parseTimestamp(m[2]);
                    const rawText = lines.slice(timeIdx + 1).join(' ');
                    const clean = rawText
                        .replace(/<[^>]*>/g, '')
                        .replace(/\[[^\]]*\]/g, '')
                        .replace(/\([^\)]*\)/g, '')
                        .replace(/^[A-Z0-9\s_-]+:\s*/, '')
                        .replace(/^["'“”—\-\s]+/, '')
                        .replace(/["'”\s]+$/, '')
                        .replace(/\s+/g, ' ')
                        .trim();
                    if (clean && clean.length >= 2 && end > start) {
                        cues.push({ start, end, text: clean });
                    }
                }
            }
            return cues;
        }

        parseYouTubeTimedText(text) {
            const cues = [];
            const trimmed = text.trim();
            if (trimmed.startsWith('{')) {
                try {
                    const data = JSON.parse(trimmed);
                    if (data.events && Array.isArray(data.events)) {
                        for (const ev of data.events) {
                            if (ev.tStartMs != null && ev.segs) {
                                const start = ev.tStartMs / 1000.0;
                                const dur = (ev.dDurationMs || 2000) / 1000.0;
                                const txt = ev.segs.map(s => s.utf8 || '').join('').replace(/\n/g, ' ').trim();
                                if (txt && txt.length >= 2) {
                                    cues.push({ start, end: start + dur, text: txt });
                                }
                            }
                        }
                    }
                } catch (e) {}
            } else if (trimmed.includes('<transcript') || trimmed.includes('<timedtext') || trimmed.includes('<text') || trimmed.includes('<p ')) {
                const textTagRegex = /<text\s+start="([\d\.]+)"(?:\s+dur="([\d\.]+)")?[^>]*>([\s\S]*?)<\/text>/gi;
                let match;
                while ((match = textTagRegex.exec(trimmed)) !== null) {
                    const start = parseFloat(match[1]) || 0;
                    const dur = parseFloat(match[2]) || 2.0;
                    const txt = match[3].replace(/<[^>]*>/g, '').replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'").trim();
                    if (txt && txt.length >= 2) {
                        cues.push({ start, end: start + dur, text: txt });
                    }
                }
                if (cues.length === 0) {
                    const pTagRegex = /<p\s+t="(\d+)"(?:\s+d="(\d+)")?[^>]*>([\s\S]*?)<\/p>/gi;
                    while ((match = pTagRegex.exec(trimmed)) !== null) {
                        const start = (parseInt(match[1], 10) || 0) / 1000.0;
                        const dur = (parseInt(match[2], 10) || 2000) / 1000.0;
                        const txt = match[3].replace(/<[^>]*>/g, '').replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'").trim();
                        if (txt && txt.length >= 2) {
                            cues.push({ start, end: start + dur, text: txt });
                        }
                    }
                }
            }
            return cues;
        }

        ingestSubtitleContent(text, sourceUrl) {
            if (!text || typeof text !== 'string' || text.length < 20 || text.length > 2 * 1024 * 1024) return;
            let parsed = [];
            if (text.includes('WEBVTT') || /-->/.test(text)) {
                parsed = this.parseVTTorSRT(text);
            } else if (text.startsWith('{') || text.includes('<transcript') || text.includes('<timedtext')) {
                parsed = this.parseYouTubeTimedText(text);
            }
            if (!parsed || parsed.length === 0) return;

            const existingStarts = new Set(this.timelineCues.map(c => c.start.toFixed(2)));
            for (const c of parsed) {
                const key = c.start.toFixed(2);
                if (!existingStarts.has(key)) {
                    existingStarts.add(key);
                    this.timelineCues.push({
                        start: c.start,
                        end: c.end,
                        text: c.text,
                        viText: null,
                        prefetched: false,
                        spoken: false
                    });
                }
            }

            this.timelineCues.sort((a, b) => a.start - b.start);
            this.pollChunkAhead();
        }

        scanDomTracks() {
            if (!this.targetVideo) return;
            const selected = this.selectedTextTrack(this.targetVideo);
            const tracks = this.targetVideo.querySelectorAll?.('track[src]') || [];
            for (const track of tracks) {
                if (track.track !== selected) continue;
                const src = track.src;
                if (src && !this.ingestedUrls.has(src)) {
                    this.ingestedUrls.add(src);
                    fetch(src).then(res => {
                        if (!res.ok || Number(res.headers.get('content-length')) > 2 * 1024 * 1024) return '';
                        return res.text();
                    }).then(txt => {
                        this.ingestSubtitleContent(txt, src);
                    }).catch(() => {});
                }
            }
        }

        extractTextTrackCues(video) {
            const v = video || this.targetVideo;
            if (!v || !v.textTracks) return;
            const selected = this.selectedTextTrack(v);
            if (!selected) return;
            let addedAny = false;
            for (let i = 0; i < v.textTracks.length; i++) {
                const track = v.textTracks[i];
                if (track !== selected) continue;
                if (!track.cues || track.cues.length === 0) continue;
                for (let j = 0; j < track.cues.length; j++) {
                    const cue = track.cues[j];
                    const txt = cue.text || cue.getCueAsHTML?.()?.textContent || '';
                    const clean = txt
                        .replace(/<[^>]*>/g, '')
                        .replace(/\[[^\]]*\]/g, '')
                        .replace(/\([^\)]*\)/g, '')
                        .replace(/^[A-Z0-9\s_-]+:\s*/, '')
                        .replace(/^["'“”—\-\s]+/, '')
                        .replace(/["'”\s]+$/, '')
                        .replace(/\s+/g, ' ')
                        .trim();
                    if (clean && clean.length >= 2) {
                        const start = cue.startTime;
                        const end = cue.endTime || (start + 2.5);
                        const exists = this.timelineCues.some(c => Math.abs(c.start - start) < 0.25);
                        if (!exists) {
                            this.timelineCues.push({
                                start,
                                end,
                                text: clean,
                                viText: null,
                                prefetched: false,
                                spoken: false
                            });
                            addedAny = true;
                        }
                    }
                }
            }
            if (addedAny) {
                this.timelineCues.sort((a, b) => a.start - b.start);
                this.pollChunkAhead(v);
            }
        }

        async translateToVi(text) {
            // Chrome content scripts cannot reliably fetch this cross-origin endpoint.
            // The native host translates both prefetch and speech using one shared cache.
            return text || '';
        }

        async translateBatchToVi(texts) {
            return Object.fromEntries((texts || []).map(text => [text, text]));
        }

        async pollChunkAhead(video) {
            if (!this.enabled) return;
            const v = video || this.targetVideo;
            if (!v) return;
            const cur = v.currentTime || 0;
            const lookAheadLimit = cur + 12.0;

            const uncachedCues = [];
            let considered = 0;
            for (const cue of this.timelineCues) {
                if (cue.start >= (cur - 0.5) && cue.start <= lookAheadLimit) {
                    if (++considered > 8) break;
                    if (!cue.prefetched) {
                        cue.prefetched = true;
                        if (isLikelyVietnameseDialogue(cue.text)) {
                            cue.viText = cue.text;
                            this.prefetch(cue.text);
                        } else if (this.translationCache.has(cue.text)) {
                            cue.viText = this.translationCache.get(cue.text);
                            this.prefetch(cue.viText);
                        } else {
                            uncachedCues.push(cue);
                        }
                    }
                } else if (cue.start > lookAheadLimit) {
                    break;
                }
            }

            if (uncachedCues.length > 0) {
                // Keep a small ahead window so current speech is not queued behind distant cues.
                for (let i = 0; i < uncachedCues.length; i += 20) {
                    const batch = uncachedCues.slice(i, i + 20);
                    const texts = batch.map(c => c.text);
                    const generation = this.playbackGeneration;
                    const timeline = this.timelineCues;
                    const translation = this.translateBatchToVi(texts);
                    for (const cue of batch) cue.translationPromise = translation;
                    translation.then(mapping => {
                        if (generation !== this.playbackGeneration || timeline !== this.timelineCues) return;
                        const viTexts = [];
                        for (const c of batch) {
                            const vi = mapping[c.text] || c.text;
                            c.viText = vi;
                            viTexts.push(vi);
                        }
                        this.prefetchBatch(viTexts);
                    });
                }
            }
        }

        checkTimeline(video) {
            if (!this.enabled) return;
            const v = video || this.targetVideo;
            if (!v || v.paused || v.seeking) return;
            const cur = v.currentTime || 0;

            for (const cue of this.timelineCues) {
                if (cur >= (cue.start - 0.15) && cur < cue.end) {
                    if (!cue.spoken && !cue.speaking) {
                        cue.speaking = true;
                        const generation = this.playbackGeneration;
                        const timeline = this.timelineCues;
                        const translation = cue.translationPromise || (cue.viText ? Promise.resolve() : this.translateToVi(cue.text).then(vi => { cue.viText = vi; }));
                        translation.then(() => {
                            if (generation !== this.playbackGeneration || timeline !== this.timelineCues || !this.enabled || v !== this.targetVideo || v.paused || v.seeking || v.currentTime >= cue.end || v.currentTime < cue.start - 0.15) return;
                            cue.spoken = true;
                            this.lastTimelineSpokenTime = Date.now();
                            this.speak(cue.viText || cue.text, { duration: Math.max(0.6, cue.end - v.currentTime) });
                        }).finally(() => { cue.speaking = false; });
                    }
                } else if (cue.start > cur + 1.2) {
                    break;
                }
            }
        }

        hookTextTracks(video) {
            if (!video.textTracks) return;

            const checkTracks = () => {
                const selected = this.selectedTextTrack(video);
                for (let i = 0; i < video.textTracks.length; i++) {
                    const track = video.textTracks[i];
                    track.removeEventListener('cuechange', this.boundCueListener);
                    if (track === selected) track.addEventListener('cuechange', this.boundCueListener);
                }
            };

            checkTracks();
            this.extractTextTrackCues(video);
            this.pollChunkAhead(video);
            if (this.boundTrackAdded) video.textTracks.removeEventListener('addtrack', this.boundTrackAdded);
            this.boundTrackAdded = () => {
                checkTracks();
                this.extractTextTrackCues(video);
                this.pollChunkAhead(video);
            };
            video.textTracks.addEventListener('addtrack', this.boundTrackAdded);
            if (this.boundTrackChanged) video.textTracks.removeEventListener('change', this.boundTrackChanged);
            this.boundTrackChanged = () => {
                this.playbackGeneration++;
                this.stopSpeech();
                this.timelineCues = [];
                checkTracks();
                this.extractTextTrackCues(video);
            };
            video.textTracks.addEventListener('change', this.boundTrackChanged);
        }

        selectedTextTrack(video) {
            const tracks = Array.from(video?.textTracks || []).filter(track => track.kind === 'subtitles' || track.kind === 'captions');
            const selected = tracks.find(track => track.mode === 'showing')
                || tracks.find(track => track.mode === 'hidden')
                || tracks.find(track => /^vi(-|$)/i.test(track.language || ''))
                || tracks.find(track => /^en(-|$)/i.test(track.language || ''))
                || tracks[0];
            if (selected?.mode === 'disabled') selected.mode = 'hidden';
            return selected || null;
        }

        normalizeText(s) {
            if (!s) return '';
            return s.toLowerCase()
                .replace(/[^\p{L}\p{N}\s]/gu, '')
                .replace(/\s+/g, ' ')
                .trim();
        }

        similarity(s1, s2) {
            if (s1 === s2) return 1.0;
            const n = s1.length, m = s2.length;
            if (n === 0 || m === 0) return 0.0;
            if (Math.abs(n - m) > Math.max(n, m) / 2) return 0.0;
            let prev = [];
            for (let j = 0; j <= m; j++) prev[j] = j;
            for (let i = 1; i <= n; i++) {
                let curr = [i];
                const c1 = s1.charAt(i - 1);
                for (let j = 1; j <= m; j++) {
                    const cost = (c1 === s2.charAt(j - 1)) ? 0 : 1;
                    curr[j] = Math.min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost);
                }
                prev = curr;
            }
            const dist = prev[m];
            const maxLen = Math.max(n, m);
            return Math.max(0.0, 1.0 - (dist / maxLen));
        }

        isNearDuplicate(newText, prevText, threshold = 0.82) {
            const n1 = this.normalizeText(newText);
            const n2 = this.normalizeText(prevText);
            if (!n1 || !n2) return false;
            if (n1 === n2) return true;
            if (n1.includes(n2) || n2.includes(n1)) {
                const minLen = Math.min(n1.length, n2.length);
                const maxLen = Math.max(n1.length, n2.length);
                if (minLen / maxLen >= 0.75) return true;
            }
            return this.similarity(n1, n2) >= threshold;
        }

        shouldSpeak(cleanText) {
            const now = Date.now();
            const norm = this.normalizeText(cleanText);
            if (!norm) return false;

            // Prune history older than 12s
            this.recentHistory = this.recentHistory.filter(item => (now - item.time) < 12000);

            for (const item of this.recentHistory) {
                const age = now - item.time;
                // Exact or normalized match within 12s
                if (cleanText === item.text || norm === item.norm) return false;
                // Near duplicate or substring within 7.5s
                if (age < 7500) {
                    if (this.isNearDuplicate(cleanText, item.text, 0.80)) return false;
                    if (item.norm.includes(norm) && norm.length <= item.norm.length) return false;
                }
            }

            this.recentHistory.push({ text: cleanText, norm: norm, time: now });
            return true;
        }

        observeSubtitleDOM() {
            if (typeof document === 'undefined') return;
            if (this.observer) this.observer.disconnect();

            const subtitleSelectors = [
                '.ytp-caption-window-container',
                '.ytp-caption-segment',
                '.caption-window',
                '.caption-visual-line',
                '.player-timedtext',
                '.player-timedtext-text-container',
                '.jw-text-track-cue',
                '.jw-text-track-display',
                '.art-subtitle',
                '.dplayer-subtitle',
                '.vjs-text-track-display',
                '.vjs-text-track-cue',
                '.subtitle-overlay',
                '.player-subtitle',
                '.player-subtitles',
                '.shaka-text-container',
                '[class*="caption-window"]',
                '[class*="caption-segment"]',
                '[class*="timedtext"]',
                '[class*="subtitle"]'
            ];

            const selectorQuery = subtitleSelectors.join(',');
            const pendingElements = new Set();

            const handleMutation = (mutations) => {
                if (!this.enabled) return;
                if (this.hasActiveTextTracks && (Date.now() - this.lastTextTrackTime < 4500)) return;
                if (this.timelineCues.length > 0 && (Date.now() - this.lastTimelineSpokenTime < 4500)) return;

                for (const mutation of mutations) {
                    let el = null;
                    if (mutation.type === 'childList') {
                        el = mutation.target;
                    } else if (mutation.type === 'characterData') {
                        el = mutation.target.parentElement;
                    }
                    if (el) {
                        const matched = el.matches?.(selectorQuery) ? el : el.closest?.(selectorQuery);
                        if (matched) {
                            pendingElements.add(matched);
                        } else {
                            const inner = el.querySelector?.(selectorQuery);
                            if (inner) pendingElements.add(inner);
                        }
                    }
                }

                clearTimeout(this.domDebounceTimer);
                this.domDebounceTimer = setTimeout(() => {
                    if (!this.enabled) {
                        pendingElements.clear();
                        return;
                    }
                    if (this.hasActiveTextTracks && (Date.now() - this.lastTextTrackTime < 4500)) {
                        pendingElements.clear();
                        return;
                    }
                    for (const el of pendingElements) {
                        if (el && el.isConnected) {
                            const text = el.textContent?.trim();
                            if (text && text.length >= 2) {
                                this.handleNewSubtitleText(text);
                            }
                        }
                    }
                    pendingElements.clear();
                }, 40);
            };

            this.observer = new MutationObserver(handleMutation);
            this.observer.observe(document.body || document.documentElement, {
                childList: true,
                subtree: true,
                characterData: true
            });
        }

        onCueChange(event) {
            if (!this.enabled) return;
            const track = event.target;
            const activeCues = track.activeCues;
            if (!activeCues || activeCues.length === 0) return;

            this.hasActiveTextTracks = true;
            this.lastTextTrackTime = Date.now();
            this.extractTextTrackCues(this.targetVideo);

            for (let i = 0; i < activeCues.length; i++) {
                const cue = activeCues[i];
                const text = cue.text || cue.getCueAsHTML?.()?.textContent || '';
                const duration = (cue.endTime && cue.startTime) ? Math.max(0.6, cue.endTime - cue.startTime) : 0;
                const inTimeline = this.timelineCues.some(item => Math.abs(item.start - cue.startTime) < 0.25 && this.normalizeText(item.text) === this.normalizeText(text));
                if (inTimeline) this.checkTimeline(this.targetVideo);
                else this.handleNewSubtitleText(text, duration);
            }

            this.pollChunkAhead(this.targetVideo);
        }

        async prefetch(rawText) {
            if (!this.enabled || !rawText) return;

            const cleanText = rawText
                .replace(/<[^>]*>/g, '')
                .replace(/\[[^\]]*\]/g, '')
                .replace(/\([^\)]*\)/g, '')
                .replace(/^[A-Z0-9\s_-]+:\s*/, '')
                .replace(/^["'“”—\-\s]+/, '')
                .replace(/["'”\s]+$/, '')
                .replace(/\s+/g, ' ')
                .trim();

            if (!cleanText || cleanText.length < 2) return;

            let textToPrefetch = cleanText;
            if (!isLikelyVietnameseDialogue(cleanText)) {
                textToPrefetch = await this.translateToVi(cleanText);
            }

            // Priority 1: Native FloatWindow WKWebView bridge
            if (typeof window !== 'undefined' && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.aiDub) {
                window.webkit.messageHandlers.aiDub.postMessage({
                    action: 'prefetch',
                    text: textToPrefetch
                });
                return;
            }

            // Priority 2: Chrome Extension runtime (Native Host Edge TTS)
            if (typeof chrome !== 'undefined' && chrome.runtime && chrome.runtime.sendMessage) {
                try {
                    chrome.runtime.sendMessage({
                        type: 'PREFETCH_AI_DUB',
                        text: textToPrefetch
                    }).catch(() => {});
                } catch (e) {}
                return;
            }

            // Cross-frame relay: post to parent window
            if (typeof window !== 'undefined' && window.parent && window.parent !== window) {
                try {
                    window.parent.postMessage({
                        type: '__floatAIDubRelay',
                        action: 'prefetch',
                        text: textToPrefetch
                    }, '*');
                } catch (e) {}
            }
        }

        prefetchBatch(texts) {
            if (!this.enabled || !texts || texts.length === 0) return;
            const valid = texts.filter(t => t && t.length >= 2);
            if (valid.length === 0) return;

            // Priority 1: Native FloatWindow WKWebView bridge
            if (typeof window !== 'undefined' && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.aiDub) {
                window.webkit.messageHandlers.aiDub.postMessage({
                    action: 'prefetchBatch',
                    texts: valid
                });
                return;
            }

            // Priority 2: Chrome Extension runtime (Native Host Edge TTS)
            if (typeof chrome !== 'undefined' && chrome.runtime && chrome.runtime.sendMessage) {
                try {
                    chrome.runtime.sendMessage({
                        type: 'PREFETCH_BATCH_AI_DUB',
                        texts: valid
                    }).catch(() => {});
                } catch (e) {}
                return;
            }
        }

        async handleNewSubtitleText(rawText, duration = 0) {
            if (!this.enabled || !rawText) return;
            const generation = this.playbackGeneration;
            const video = this.targetVideo;

            const cleanText = rawText
                .replace(/<[^>]*>/g, '')
                .replace(/\[[^\]]*\]/g, '')
                .replace(/\([^\)]*\)/g, '')
                .replace(/^[A-Z0-9\s_-]+:\s*/, '')
                .replace(/^["'“”—\-\s]+/, '')
                .replace(/["'”\s]+$/, '')
                .replace(/\s+/g, ' ')
                .trim();

            if (!cleanText || cleanText.length < 2) return;

            let textToSpeak = cleanText;
            if (!isLikelyVietnameseDialogue(cleanText)) {
                textToSpeak = await this.translateToVi(cleanText);
            }

            if (!this.enabled || generation !== this.playbackGeneration || video !== this.targetVideo || video?.paused || video?.seeking) return;

            if (!this.shouldSpeak(textToSpeak)) return;

            this.lastSpokenText = textToSpeak;
            this.lastSpokenTime = Date.now();

            const effDuration = (duration && duration > 0) ? duration : Math.max(1.4, textToSpeak.length / 12.0);
            this.speak(textToSpeak, { duration: effDuration });
        }

        calculateDynamicRate(text, duration) {
            if (!duration || duration <= 0) {
                duration = Math.max(1.0, text.length / 14);
            }
            const charsPerSec = text.length / Math.max(0.5, duration);
            let rate = this.baseRate;
            if (charsPerSec > 10) {
                const excess = charsPerSec - 10;
                rate = this.baseRate + (excess * 0.04);
            }
            return Math.min(this.maxRate, Math.max(this.minRate, rate));
        }

        speak(text, options = {}) {
            if (!this.enabled || !text) return;

            const duration = (options.duration && options.duration > 0) ? options.duration : Math.max(1.4, text.length / 12.0);

            // Priority 1: Native FloatWindow WKWebView bridge
            if (typeof window !== 'undefined' && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.aiDub) {
                window.webkit.messageHandlers.aiDub.postMessage({
                    action: 'speak',
                    text: text,
                    duration: duration
                });
                return;
            }

            // Priority 2: Chrome Extension runtime (Native Host Edge TTS)
            if (typeof chrome !== 'undefined' && chrome.runtime && chrome.runtime.sendMessage) {
                this.duckVolume();
                try {
                    chrome.runtime.sendMessage({
                        type: 'SPEAK_AI_DUB',
                        text: text,
                        duration: duration,
                        gender: this.voiceGender
                    }, () => {
                        const restoreDelay = Math.max(1000, (duration || (text.length / 14)) * 1000 + 250);
                        clearTimeout(this.duckTimer);
                        this.duckTimer = setTimeout(() => {
                            this.restoreVolume();
                        }, restoreDelay);
                    });
                } catch (e) {
                    this.restoreVolume();
                }
                return;
            }

            // Cross-frame relay: post to parent window
            if (typeof window !== 'undefined' && window.parent && window.parent !== window) {
                try {
                    window.parent.postMessage({
                        type: '__floatAIDubRelay',
                        action: 'speak',
                        text: text,
                        duration: duration,
                        gender: this.voiceGender
                    }, '*');
                } catch (e) {}
            }
        }

        stopSpeech() {
            if (typeof window !== 'undefined' && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.aiDub) {
                window.webkit.messageHandlers.aiDub.postMessage({ action: 'stop' });
            }
            if (typeof chrome !== 'undefined' && chrome.runtime && chrome.runtime.sendMessage) {
                chrome.runtime.sendMessage({ type: 'STOP_AI_DUB' }).catch(() => {});
            }
            if (typeof window !== 'undefined' && window.parent && window.parent !== window) {
                try {
                    window.parent.postMessage({ type: '__floatAIDubRelay', action: 'stop' }, '*');
                } catch (e) {}
            }
        }

        duckVolume() {
            clearTimeout(this.duckTimer);
            if (!this.targetVideo) {
                this.scanForVideoElement();
            }
            if (!this.targetVideo) return;

            if (!this.isDucked) {
                this.preDuckVolume = this.targetVideo.volume !== undefined ? this.targetVideo.volume : 1.0;
                const duckedVol = Math.max(0.08, this.preDuckVolume * this.duckingRatio);
                this.targetVideo.volume = duckedVol;
                this.isDucked = true;
            }
        }

        scheduleRestoreVolume() {
            clearTimeout(this.duckTimer);
            this.duckTimer = setTimeout(() => {
                this.restoreVolume();
            }, this.duckingRestoreDelay);
        }

        restoreVolume() {
            if (this.isDucked && this.targetVideo) {
                this.targetVideo.volume = this.preDuckVolume;
                this.isDucked = false;
            }
        }

        onVideoPlay() {
            for (const cue of this.timelineCues) {
                cue.speaking = false;
                if (!cue.viText) {
                    cue.prefetched = false;
                    cue.translationPromise = null;
                }
            }
            if (this.targetVideo) this.hookTextTracks(this.targetVideo);
        }

        onVideoPause() {
            this.playbackGeneration++;
            this.stopSpeech();
            this.restoreVolume();
        }

        onVideoSeeking() {
            this.playbackGeneration++;
            this.stopSpeech();
            this.restoreVolume();
            this.lastSpokenText = '';
            this.recentHistory = [];
            if (this.targetVideo) {
                const cur = this.targetVideo.currentTime || 0;
                for (const cue of this.timelineCues) {
                    cue.speaking = false;
                    if (!cue.viText) {
                        cue.prefetched = false;
                        cue.translationPromise = null;
                    }
                    if (cue.start >= cur - 0.5) {
                        cue.spoken = false;
                    }
                }
                this.pollChunkAhead(this.targetVideo);
            }
        }
    }

    return AIDubbingEngine;
}));
