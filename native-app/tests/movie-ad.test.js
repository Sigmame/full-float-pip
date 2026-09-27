const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert');

const swift = fs.readFileSync(path.join(__dirname, '..', 'Sources', 'FloatWindow.swift'), 'utf8');
const fillStart = swift.indexOf('    private static let smartFillJavaScript = #"""');
const fillJSStart = fillStart + '    private static let smartFillJavaScript = #"""'.length;
const fillJSEnd = swift.indexOf('    """#', fillJSStart);
assert(fillStart >= 0 && fillJSEnd > fillJSStart);
const smartFillJS = swift.slice(fillJSStart, fillJSEnd);
const blurMarker = '    private static let bannerBlurJavaScript = #"""';
const blurStart = swift.indexOf(blurMarker);
const blurJSStart = blurStart + blurMarker.length;
const blurJSEnd = swift.indexOf('    """#', blurJSStart);
assert(blurStart >= 0 && blurJSEnd > blurJSStart);
const bannerBlurJS = swift.slice(blurJSStart, blurJSEnd);
// The audio boost is exercised by its own test; inside these ad-sampling
// blocks it only needs to be evaluable (and the load-time seed must resolve).
const audioBoostStub =
  '(function(){ window.__floatSetAudioBoost = function() { return "off"; }; })();';
const adAudioTapStub =
  '(function(){ window.__floatInstallAdAudioTap = function() {}; })();';
const aiDubbingStub =
  '(function(){ window.__floatInstallAIDub = function() {}; })();';
const htmlStart = swift.indexOf('    private func buildVideoHTML(');
const scriptStart = swift.indexOf("            const v = document.getElementById('player');", htmlStart);
const scriptEnd = swift.indexOf('        </script>', scriptStart);
assert(htmlStart >= 0 && scriptStart > htmlStart && scriptEnd > scriptStart);
const source = swift.slice(scriptStart, scriptEnd)
  .replace('\\(escapedSrc)', 'https://example.com/movie.mp4')
  .replace('\\(currentTime)', '0')
  .replace('\\(Self.smartFillJavaScript)', smartFillJS)
  .replace('\\(Self.bannerBlurJavaScript)', bannerBlurJS)
  .replace('\\(Self.audioBoostJavaScript)', audioBoostStub)
  .replace('\\(Self.adAudioTapJavaScript)', adAudioTapStub)
  .replace('\\(Self.aiDubbingJavaScript)', aiDubbingStub)
  .replace('\\(Self.preferredAudioBoost.factor)', '1');

let now = 10000;
const intervals = [];
const delayed = [];
const messages = [];
const listeners = {};
const pixels = new Uint8ClampedArray(280 * 158 * 4);
const video = {
  videoWidth: 1920, videoHeight: 1080, readyState: 2, paused: false, isConnected: true,
  clientWidth: 640, clientHeight: 360,
  currentTime: 0, duration: 3600, style: { setProperty() {} },
  addEventListener(name, fn) { listeners[name] = fn; },
  removeEventListener() {},
  play() { return Promise.resolve(); },
  pause() {}
};
const canvas = {
  getContext() {
    return { drawImage() {}, getImageData() { return { data: pixels }; } };
  },
  toDataURL() { return 'data:image/jpeg;base64,AA=='; }
};
const document = {
  getElementById(id) { return id === 'player' ? video : { style: {} }; },
  createElement(name) { assert.equal(name, 'canvas'); return canvas; }
};
const window = {
  webkit: { messageHandlers: { adWatch: { postMessage(message) { messages.push(message); } } } }
};
const clock = class extends Date { static now() { return now; } };
vm.runInNewContext(source, {
  document, window, Date: clock, Uint8Array, Float32Array,
  setInterval(fn, ms) { intervals.push({ fn, ms }); },
  setTimeout(fn, ms) { delayed.push({ fn, ms, at: now + ms }); },
  console
});
function advance(ms) {
  now += ms;
  for (const item of delayed.splice(0)) {
    if (item.at <= now) item.fn();
    else delayed.push(item);
  }
}
const scanner = intervals.find(item => item.ms === 500);
assert(scanner, 'movie frame scanner runs every 500ms');
scanner.fn();
assert.equal(messages.length, 1, 'first frame is sampled without color prefilter');
assert.equal(messages[0].time, 0);
assert.equal(messages[0].hot, false);
advance(500);
scanner.fn();
assert.equal(messages.length, 1, 'routine OCR is throttled');
advance(1000);
scanner.fn();
assert.equal(messages.length, 2, 'non-colorful ads are sampled periodically');
window.__floatAdSkipping = true;
listeners.seeked();
assert.equal(window.__floatAdSkipping, false);
const rescan = delayed.find(item => item.ms === 450);
assert(rescan, 'seek schedules an early verification frame');
advance(450);
assert.equal(messages.length, 3, 'seek verification bypasses the routine throttle');
console.log('movie ad sampling scenarios passed');

const embedStart = swift.indexOf('    private func injectEmbedPlayerAutomation()');
const embedJSStart = swift.indexOf('        let js = """', embedStart) + '        let js = """'.length;
const embedJSEnd = swift.indexOf('        """', embedJSStart);
assert(embedStart >= 0 && embedJSEnd > embedJSStart);
const embedTimers = [];
let embedClicks = 0;
const skipButton = {
  offsetParent: {}, disabled: false,
  getAttribute() { return null; },
  click() { embedClicks++; }
};
const embedDocument = {
  documentElement: { style: {} }, body: { style: {} },
  querySelector(selector) {
    return selector.includes('.jw-skip') ? skipButton : null;
  }
};
vm.runInNewContext(swift.slice(embedJSStart, embedJSEnd)
  .replace('\\(isOfflineDubEnabled && !offlineDubPlaybackAuthorized ? "true" : "false")', 'false'), {
  window: { jwplayer() { return { getState() { return 'playing'; } }; } },
  document: embedDocument, Date: clock,
  setInterval(fn, ms) { embedTimers.push({ fn, ms }); return embedTimers.length; },
  clearInterval() {}
});
assert.equal(embedTimers.length, 2, 'ad guard is independent of autoplay timer');
embedTimers[1].fn(); // autoplay timer sees playback and stops
embedTimers[0].fn(); // mid-roll guard still runs
assert.equal(embedClicks, 1, 'embed ad can be skipped after playback starts');
console.log('embed ad skip scenario passed');

const frameStart = swift.indexOf('    private func installMovieEmbedAdScript()');
const frameJSStart = swift.indexOf('        let source = """', frameStart) + '        let source = """'.length;
const frameJSEnd = swift.indexOf('        """', frameJSStart);
assert(frameStart >= 0 && frameJSEnd > frameJSStart);
const frameIntervals = [];
let frameClicks = 0;
let controlsRemoved = 0;
let controlsObserver;
let injectedStyle;
const frameVideo = {
  videoWidth: 0, controls: true, currentTime: 0, duration: 3600, paused: true,
  removeAttribute(name) { if (name === 'controls') controlsRemoved++; },
  play() { throw new Error('a paused video must stay paused'); }
};
const frameButton = {
  disabled: false,
  getAttribute() { return null; },
  getBoundingClientRect() { return { width: 32, height: 16 }; },
  click() { frameClicks++; }
};
const frameContext = {
  window: { addEventListener() {} }, Date: clock,
  MutationObserver: class {
    constructor(callback) { controlsObserver = callback; }
    observe() {}
  },
  document: {
    head: { appendChild(element) { injectedStyle = element; } },
    body: {
      lastElementChild: null,
      appendChild(node) { this.lastElementChild = node; }
    },
    getElementById() { return null; },
    querySelector(selector) { return selector === 'video' ? frameVideo : frameButton; },
    querySelectorAll() { return []; },
    createElement(name) {
      if (name === 'style') return { textContent: '' };
      if (name === 'canvas') return canvas;
      return { style: {}, setAttribute() {} };
    }
  },
  setInterval(fn, ms) { frameIntervals.push({ fn, ms }); }
};
const bypassMarker = 'private static let gamblingAdBypassJavaScript = #"""';
const bypassBodyStart = swift.indexOf(bypassMarker) + bypassMarker.length;
const bypassBodyEnd = swift.indexOf('"""#', bypassBodyStart);
assert(bypassBodyStart > bypassMarker.length && bypassBodyEnd > bypassBodyStart);
const bypassJS = swift.slice(bypassBodyStart, bypassBodyEnd);
const frameScript = swift.slice(frameJSStart, frameJSEnd);
const expandedFrameScript = frameScript
  .replace('\\(Self.smartFillJavaScript)', smartFillJS)
  .replace('\\(Self.gamblingAdBypassJavaScript)', bypassJS)
  .replace('\\(Self.bannerBlurJavaScript)', bannerBlurJS)
  .replace('\\(Self.audioBoostJavaScript)', audioBoostStub)
  .replace('\\(Self.adAudioTapJavaScript)', adAudioTapStub)
  .replace('\\(Self.aiDubbingJavaScript)', aiDubbingStub)
  .replace('\\(Self.preferredAudioBoost.factor)', '1');
vm.runInNewContext(expandedFrameScript, frameContext);
vm.runInNewContext(expandedFrameScript, frameContext);
assert.equal(frameIntervals.length, 2, 'each iframe installs the video timer and the ad timer');
assert.equal(typeof frameContext.window.__floatBypassGamblingAd, 'function', 'player-side gambling bypass is installed');
assert(injectedStyle.textContent.includes('.jwplayer .jw-controlbar'), 'JW Player transport bar is hidden');
assert(injectedStyle.textContent.includes('.jw-slider-time'), 'provider progress bar is hidden');
assert(injectedStyle.textContent.includes('::-webkit-media-controls'), 'native video controls are hidden');
assert(!injectedStyle.textContent.includes('.jw-controls,'), 'ad and caption overlays remain available');
frameIntervals.find(item => item.ms === 1000).fn();
assert.equal(frameVideo.controls, false, 'embed video native controls are disabled');
assert.equal(controlsRemoved, 1);
frameVideo.controls = true;
controlsObserver();
assert.equal(frameVideo.controls, false, 'provider cannot re-enable duplicate controls');
frameIntervals.find(item => item.ms === 250).fn();
assert.equal(frameClicks, 1, 'iframe Skip button is clicked');
assert.equal(frameContext.window.__floatSkipEmbedAd(), true, 'detected embed ad seeks immediately');
assert.equal(frameVideo.currentTime, 10);
for (let i = 0; i < 14; i++) {
  now += 500;
  frameContext.window.__floatSkipEmbedAd();
}
assert.equal(frameVideo.currentTime, 150, 'opening ad seek stops after 150 seconds');
now += 500;
assert.equal(frameContext.window.__floatSkipEmbedAd(), false, 'seek stops after the opening budget');
now += 4000;
frameVideo.currentTime = 100;
frameVideo.duration = Infinity;
frameVideo.seekable = { length: 1, end() { return 1800; } };
assert.equal(frameContext.window.__floatSkipEmbedAd(), true, 'HLS with infinite duration remains seekable');
assert.equal(frameVideo.currentTime, 110);
now += 4000;
frameVideo.currentTime = 200;
frameVideo.duration = Infinity;
frameVideo.seekable = { length: 0, end() { return NaN; } };
assert.equal(frameContext.window.__floatSkipEmbedAd(), true, 'infinite duration without a seekable range still steps forward');
assert.equal(frameVideo.currentTime, 210);
const preroll = { duration: 22, currentTime: 0.4 };
let apiSkips = 0;
frameContext.document.querySelector = (selector) => selector === 'video' ? preroll : null;
frameContext.window.jwplayer = () => ({
  skipAd() { apiSkips++; },
  on() {},
  setup() {}
});
assert.equal(frameContext.window.__floatBypassGamblingAd(), true, 'a short preroll is skipped to its end');
assert.equal(preroll.currentTime, 21.7);
assert.equal(apiSkips, 0, 'a short file does not need the JW ad API');
const movie = { duration: 2400, currentTime: 30 };
frameContext.document.querySelector = (selector) => {
  if (selector === 'video') return movie;
  if (String(selector).includes('jw-ad')) return { getBoundingClientRect() { return { width: 120, height: 40 }; } };
  return null;
};
frameContext.window.__floatBypassGamblingAd();
assert.equal(apiSkips, 1, 'JW ad mode calls skipAd');
assert.equal(movie.currentTime, 30, 'the episode itself is not seeked');
console.log('iframe ad skip scenario passed');
