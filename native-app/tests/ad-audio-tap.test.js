const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert');

// Pull the shared tap out of the app source, as the other player tests do.
const swift = fs.readFileSync(path.join(__dirname, '..', 'Sources', 'FloatWindow.swift'), 'utf8');
const marker = '    private static let adAudioTapJavaScript = #"""';
const start = swift.indexOf(marker);
assert(start >= 0, 'the shared ad audio tap script exists');
const bodyStart = start + marker.length;
const end = swift.indexOf('    """#', bodyStart);
assert(end > bodyStart, 'the ad audio tap script is terminated');
const source = swift.slice(bodyStart, end);

function load(opts) {
  opts = opts || {};
  const posts = [];
  const timeouts = [];
  const intervals = [];
  const listeners = { video: {}, document: {} };
  let graphCalls = 0;

  const analyser = {
    fftSize: 2048,
    getFloatTimeDomainData(array) {
      for (let i = 0; i < array.length; i++) array[i] = opts.silent ? 0 : 0.1;
    }
  };
  const video = {
    tagName: 'VIDEO',
    paused: false,
    readyState: 4,
    addEventListener(name, fn) { listeners.video[name] = fn; }
  };
  const window = {
    webkit: { messageHandlers: { adAudio: { postMessage(message) { posts.push(message); } } } },
    __floatEnsureAudioGraph() {
      graphCalls++;
      return opts.noGraph ? null : { ctx: { state: 'running', sampleRate: 16000, resume() {} }, analyser };
    }
  };
  const state = { videoInDocument: !!opts.videoInDocument };
  const document = {
    querySelector(selector) { return state.videoInDocument && selector === 'video' ? video : null; },
    addEventListener(name, fn) { (listeners.document[name] = listeners.document[name] || []).push(fn); }
  };

  vm.runInNewContext(source, {
    window, document, Float32Array, Uint8Array, String, btoa,
    setTimeout(fn, ms) { timeouts.push(fn); },
    setInterval(fn, ms) { intervals.push(fn); return intervals.length; }
  });

  return {
    window, document, video, posts, timeouts, intervals, listeners, state,
    graphs() { return graphCalls; },
    // One pump callback at a time, the way the page's 45 ms timer drives it.
    pump() { const fn = timeouts.shift(); if (fn) fn(); }
  };
}

// --- installed in the app's own page: a chunk reaches native once a full second
const a = load();
a.window.__floatInstallAdAudioTap(a.video);
assert.equal(a.window.__floatAudioTap, true, 'installing sets the single-tap flag');
assert.equal(a.graphs(), 1, 'the shared graph is requested once');

// The install pumps once immediately, so six more stays just under a second.
for (let i = 0; i < 6; i++) a.pump();
assert.equal(a.posts.length, 0, 'a partial second is not posted');
a.pump();
assert.equal(a.posts.length, 1, 'one second of 16 kHz PCM is posted');

const bytes = Buffer.from(a.posts[0], 'base64');
assert.equal(bytes.length, 32768, 'the payload is 16 kHz Int16 mono');

// A second install must not build a second tap on the same element.
const pumpsBefore = a.timeouts.length;
a.window.__floatInstallAdAudioTap(a.video);
assert.equal(a.graphs(), 1, 're-installing reuses the running tap');
assert.equal(a.timeouts.length, pumpsBefore, 're-installing does not start another pump');

// --- a seek drops the partial chunk instead of splicing a seam into it
const b = load();
b.window.__floatInstallAdAudioTap(b.video);
for (let i = 0; i < 4; i++) b.pump();          // 8192 samples, under the threshold
b.listeners.video.seeked();
for (let i = 0; i < 4; i++) b.pump();          // would reach 16384 without the flush
assert.equal(b.posts.length, 0, 'the pre-seek half-second is discarded, not joined to the next');
for (let i = 0; i < 4; i++) b.pump();
assert.equal(b.posts.length, 1, 'the next full second is posted');

// --- a suspended context must never be tapped
const c = load({ noGraph: true });
c.window.__floatInstallAdAudioTap(c.video);
assert.notEqual(c.window.__floatAudioTap, true, 'no tap while the audio context may not run');
assert.equal(c.timeouts.length, 0, 'no pump is started without a graph');

// --- silence is not worth a round trip through the recogniser
const d = load({ silent: true });
d.window.__floatInstallAdAudioTap(d.video);
for (let i = 0; i < 12; i++) d.pump();
assert.equal(d.posts.length, 0, 'a silent chunk is not posted');

// --- a provider page that builds its player late is picked up
const e = load();
assert.notEqual(e.window.__floatAudioTap, true, 'no tap before a player exists');
assert.equal(e.timeouts.length, 0, 'nothing is pumped before a video appears');
e.state.videoInDocument = true;
e.intervals[0](); // the 2 s re-check
assert.equal(e.window.__floatAudioTap, true, 'the late player is tapped on the next look');
assert.equal(e.graphs(), 1);

// --- the relayed `playing` event taps whichever frame owns the video
const f = load();
f.window.__floatAudioTap = undefined;
f.listeners.document['playing'][0]({ target: f.video });
assert.equal(f.window.__floatAudioTap, true, 'a playing video installs the tap through the event');

console.log('ad audio tap scenarios passed');
