/**
 * VibeFloat Subtitle Network Interceptor (Main World)
 * Runs in the page's MAIN execution world at document_start.
 * Intercepts all fetch & XMLHttpRequest calls for subtitle/caption streams (.vtt, .srt, timedtext),
 * and posts the raw subtitle content to the extension's isolated world via window.postMessage.
 */
(function() {
    'use strict';
    if (typeof window === 'undefined' || window.__vibeSubInterceptorMainInstalled) return;
    window.__vibeSubInterceptorMainInstalled = true;

    var ingestedUrls = new Set();
    var MAX_SUBTITLE_BYTES = 2 * 1024 * 1024;

    function isSubtitleUrl(url) {
        if (!url || typeof url !== 'string') return false;
        if (/\.(m3u8|ts|m4s|mp4|webm|mp3|aac|png|jpg|jpeg|gif|webp|woff2?)(\?|$)/i.test(url)) return false;
        return /\.(vtt|srt|ass)(\?|$)|timedtext|subtitle|caption|\/sub\//i.test(url);
    }

    function looksLikeSubtitlePayload(text, contentType) {
        if (!text || typeof text !== 'string' || text.length < 20 || text.length > MAX_SUBTITLE_BYTES) return false;
        var type = String(contentType || '').toLowerCase();
        if (/text\/vtt|subrip|subtitle|caption/.test(type)) return true;
        var head = text.slice(0, 1200).trim();
        if (/^webvtt\b/i.test(head) || /\d{1,2}:\d{2}(?::\d{2})?[,.]\d{3}\s+-->/.test(text)) return true;
        if (/\b(timedtext|transcript|events|segs|start|dur)\b/i.test(head) &&
            (/^\s*[<{[]/.test(head))) return true;
        return false;
    }

    function dispatchSubtitleData(url, text) {
        if (!text || typeof text !== 'string' || text.length < 20 || text.length > MAX_SUBTITLE_BYTES) return;
        if (ingestedUrls.has(url)) return;
        ingestedUrls.add(url);

        try {
            window.postMessage({
                type: '__floatVibeSubtitleData',
                url: url,
                content: text
            }, '*');
        } catch (e) {}
    }

    // Intercept window.fetch
    if (typeof window.fetch === 'function') {
        var origFetch = window.fetch;
        window.fetch = function() {
            var args = Array.prototype.slice.call(arguments);
            var promise = origFetch.apply(this, args);
            try {
                var url = '';
                if (typeof args[0] === 'string') {
                    url = args[0];
                } else if (args[0] && args[0].url) {
                    url = args[0].url;
                }
                if (!ingestedUrls.has(url)) {
                    promise.then(function(res) {
                        try {
                            if (!res.ok || Number(res.headers.get('content-length')) > MAX_SUBTITLE_BYTES) return;
                            var contentType = res.headers.get('content-type') || '';
                            res.clone().text().then(function(txt) {
                                if (isSubtitleUrl(url) || looksLikeSubtitlePayload(txt, contentType)) {
                                    dispatchSubtitleData(url, txt);
                                }
                            }).catch(function() {});
                        } catch (e) {}
                    }).catch(function() {});
                }
            } catch (e) {}
            return promise;
        };
    }

    // Intercept XMLHttpRequest
    if (typeof window.XMLHttpRequest === 'function') {
        var origOpen = XMLHttpRequest.prototype.open;
        var origSend = XMLHttpRequest.prototype.send;

        XMLHttpRequest.prototype.open = function(method, url) {
            this.__vibeSubUrl = url;
            return origOpen.apply(this, arguments);
        };

        XMLHttpRequest.prototype.send = function() {
            var self = this;
            var subUrl = this.__vibeSubUrl;
            if (subUrl && !ingestedUrls.has(subUrl)) {
                this.addEventListener('load', function() {
                    try {
                        var contentType = self.getResponseHeader ? self.getResponseHeader('content-type') : '';
                        if (isSubtitleUrl(subUrl) || looksLikeSubtitlePayload(self.responseText, contentType)) {
                            dispatchSubtitleData(subUrl, self.responseText);
                        }
                    } catch (e) {}
                });
            }
            return origSend.apply(this, arguments);
        };
    }
})();
