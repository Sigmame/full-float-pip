const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert');

// Pull the real player script out of the app source, exactly as the other
// player tests do, so these checks run against shipped code rather than a copy.
const swift = fs.readFileSync(path.join(__dirname, '..', 'Sources', 'FloatWindow.swift'), 'utf8');
const marker = '    private static let audioBoostJavaScript = #"""';
const start = swift.indexOf(marker);
assert(start >= 0, 'the shared audio boost script exists');
const bodyStart = start + marker.length;
const end = swift.indexOf('    """#', bodyStart);
assert(end > bodyStart, 'the audio boost script is terminated');
const source = swift.slice(bodyStart, end);

// An AudioParam the gain writes land on. Only the value matters to the tests.
function makeParam() {
  let v = 0;
  return {
    get value() { return v; },
    set value(next) { v = next; },
    cancelScheduledValues() {},
    setTargetAtTime(next) { v = next; }
  };
}

function load(opts) {
  opts = opts || {};
  const state = { value: opts.initialState || 'running' };
  const calls = { capture: 0, resume: 0 };
  const gains = [];
  const iframes = [];
  const listeners = { document: {}, window: {} };
  const video = opts.noVideo ? null : { tagName: 'VIDEO' };

  const ctx = {
    get state() { return state.value; },
    currentTime: 0,
    destination: { connect() {} },
    resume() {
      calls.resume++;
      return {
        then(ok, err) {
          if (opts.resume === 'immediate') ok();
          else if (opts.resume === 'blocked') err();
        }
      };
    },
    createMediaElementSource() { calls.capture++; return { connect() {} }; },
    createGain() { const node = { gain: makeParam(), connect() {} }; gains.push(node); return node; },
    createDynamicsCompressor() {
      return { threshold: makeParam(), knee: makeParam(), ratio: makeParam(),
               attack: makeParam(), release: makeParam(), connect() {} };
    },
    createAnalyser() { return { fftSize: 0, connect() {} }; }
  };

  const document = {
    querySelector(sel) { return sel === 'video' ? video : null; },
    querySelectorAll(sel) { return sel === 'iframe' ? iframes : []; },
    addEventListener(type, fn) {
      (listeners.document[type] = listeners.document[type] || []).push(fn);
    }
  };
  const window = {
    __floatVideoMainVideo: video || undefined,
    AudioContext: function AudioContext() { return ctx; },
    addEventListener(type, fn) {
      (listeners.window[type] = listeners.window[type] || []).push(fn);
    }
  };

  vm.runInNewContext(source, { window, document, console });

  return {
    window, document, ctx, gains, iframes, calls,
    setState(v) { state.value = v; },
    playing() { (listeners.document['playing'] || []).forEach(fn => fn({ target: video })); },
    message(data) { (listeners.window['message'] || []).forEach(fn => fn({ data })); }
  };
}

// --- running context: the graph is captured once and the gain tracks the level
const a = load();
assert.equal(typeof a.window.__floatSetAudioBoost, 'function', 'the setter is published');
assert.equal(a.window.__floatAudioBoostStatus, 'off', 'the script starts off');

assert.equal(a.window.__floatSetAudioBoost(1), 'off', 'unity is off, not a boost');
assert.equal(a.calls.capture, 0, 'unity never captures the element into a graph');
assert.equal(a.window.__floatSetAudioBoost(0.5), 'off', 'a factor below one is not a boost');
assert.equal(a.window.__floatSetAudioBoost(NaN), 'off', 'a non-finite factor is ignored');
assert.equal(a.calls.capture, 0, 'still nothing captured');

assert.equal(a.window.__floatSetAudioBoost(2), 'on', 'a running context applies the lift');
assert.equal(a.calls.capture, 1, 'createMediaElementSource runs exactly once');
assert.equal(a.gains[0].gain.value, 2, 'the gain target is the requested factor');
assert.equal(a.window.__floatAudioBoostLevel, 2);

assert.equal(a.window.__floatSetAudioBoost(2), 'on', 're-applying is idempotent');
assert.equal(a.calls.capture, 1, 're-applying reuses the cached graph');
assert.equal(a.gains.length, 1, 'no second gain node is built');

assert.equal(a.window.__floatSetAudioBoost(2.8), 'on', 'the level can be raised');
assert.equal(a.gains[0].gain.value, 2.8, 'the same graph takes the new target');

// Dropping to unity keeps the graph wired (so the ad audio tap survives) but
// leaves the track at its own level, and a later boost does not re-capture.
assert.equal(a.window.__floatSetAudioBoost(1), 'off', 'unity turns the boost off');
assert.equal(a.gains[0].gain.value, 1, 'unity resets the gain');
assert.equal(a.calls.capture, 1, 'unity does not tear the graph down');
assert.equal(a.window.__floatSetAudioBoost(2), 'on');
assert.equal(a.calls.capture, 1, 'a second boost reuses the still-live graph');

// --- relay: the <video> can be a frame away from the one native can reach
a.iframes.push({ contentWindow: { postMessage(msg) { this.sent = msg; } } });
a.message({ __floatAudioBoost: 2.8 });
assert.equal(a.gains[0].gain.value, 2.8, 'a relayed level is applied in this frame');
assert.deepEqual(a.iframes[0].contentWindow.sent, { __floatAudioBoost: 2.8 },
  'the level is relayed down to child frames');
a.message({ some: 'other' });
assert.equal(a.gains[0].gain.value, 2.8, 'unrelated messages are ignored');

// --- a suspended context must never capture the element (that is permanent silence)
const b = load({ initialState: 'suspended', resume: 'never' });
assert.equal(b.window.__floatSetAudioBoost(2), 'pending', 'a suspended context defers the boost');
assert.equal(b.calls.capture, 0, 'the element is not captured into a suspended graph');
assert.equal(b.calls.resume, 1, 'the script asks the context to resume');
assert.equal(b.gains.length, 0, 'no graph is built while suspended');

// The first real playback both resumes the context and fires `playing`; the
// stored level is then applied without another user action.
b.setState('running');
b.playing();
assert.equal(b.calls.capture, 1, 'the playing event captures once the context is live');
assert.equal(b.gains[0].gain.value, 2, 'the remembered level is applied');
assert.equal(b.window.__floatAudioBoostStatus, 'on');

// A `playing` event while off must not build a graph.
const c = load();
c.playing();
assert.equal(c.calls.capture, 0, 'playing while off does not capture the element');

// --- no video yet: report and wait, rather than capturing the wrong element
const d = load({ noVideo: true });
assert.equal(d.window.__floatSetAudioBoost(2), 'no-video', 'a missing video is reported');
assert.equal(d.calls.capture, 0, 'nothing is captured when there is no video');

console.log('audio boost scenarios passed');
