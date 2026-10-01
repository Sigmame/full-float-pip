// The playback poll reports *where* the episode length came from, because the
// end-credits window is measured from it. `dur` alone cannot tell "45 minutes of
// film" from "6 minutes buffered"; `WatchAssist` refuses to place the credits on
// the second one. This test runs the real script out of FloatWindow.swift
// against fake players and pins the label each path produces.

const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert');

const swift = fs.readFileSync(path.join(__dirname, '..', 'Sources', 'FloatWindow.swift'), 'utf8');
const marker = '    private func pollVideoState() {';
const markerAt = swift.indexOf(marker);
assert(markerAt >= 0, 'pollVideoState exists');
const jsOpen = swift.indexOf('let js = """', markerAt);
assert(jsOpen > markerAt, 'the poll script is a triple-quoted literal');
const bodyStart = jsOpen + 'let js = """'.length;
const end = swift.indexOf('        """', bodyStart);
assert(end > bodyStart, 'the poll script is terminated');
const source = swift.slice(bodyStart, end);

function run({ video, clock, jwplayer, iframes = [] }) {
  const window = {};
  if (clock) window.__floatClock = clock;
  if (jwplayer) window.jwplayer = () => jwplayer;
  const document = {
    querySelector(selector) {
      if (selector === 'video') return video || null;
      return null; // #movie_player / .html5-video-player: no player wrapper
    },
    querySelectorAll() { return iframes; }
  };
  return vm.runInNewContext(source, { window, document });
}

const checks = [];
function check(label, fn) {
  try {
    fn();
    checks.push(`  ok   ${label}`);
  } catch (error) {
    checks.push(`  FAIL ${label}: ${error.message}`);
    process.exitCode = 1;
  }
}

console.log('playback poll; episode length source');

// 1. A plain file length is what the credits are measured from.
check('a finite media duration is reported as media', () => {
  const out = run({ video: { duration: 2700, currentTime: 120, volume: 1, muted: false, paused: false, ended: false } });
  assert.strictEqual(out.durSrc, 'media');
  assert.strictEqual(out.dur, 2700);
  assert.strictEqual(out.ct, 120);
});

// 2. `seekable.end()` is a buffer edge, and says so.
check('an infinite duration falls back to seekable, not to a length', () => {
  const out = run({
    video: {
      duration: Infinity, currentTime: 30, volume: 1, muted: false, paused: false, ended: false,
      seekable: { length: 1, end: () => 300 }
    }
  });
  assert.strictEqual(out.durSrc, 'seekable');
  assert.strictEqual(out.dur, 300);
});

// 3. The provider's own length outranks both, matching the comment in the
//    script: HLS often publishes only the buffered window.
check('the provider clock outranks a short media duration', () => {
  const out = run({
    video: { duration: 200, currentTime: 100, volume: 1, muted: false, paused: false, ended: false },
    clock: { dur: 2700, ct: 100, paused: false, ad: false }
  });
  assert.strictEqual(out.durSrc, 'clock');
  assert.strictEqual(out.dur, 2700);
});

// 4. A smaller clock must not shrink a real file length.
check('a smaller clock does not shorten the media duration', () => {
  const out = run({
    video: { duration: 2700, currentTime: 100, volume: 1, muted: false, paused: false, ended: false },
    clock: { dur: 200, ct: 100, paused: false, ad: false }
  });
  assert.strictEqual(out.durSrc, 'media');
  assert.strictEqual(out.dur, 2700);
});

// 5. No <video> at all: the injected clock is still a usable report.
check('a clock-only frame reports a clock duration', () => {
  const out = run({ clock: { dur: 2700, ct: 1400, paused: false, ad: false } });
  assert.strictEqual(out.durSrc, 'clock');
  assert.strictEqual(out.dur, 2700);
  assert.strictEqual(out.ct, 1400);
});

// 6. The jwplayer path is the provider publishing its episode length.
check('the jwplayer fallback reports a clock duration', () => {
  const out = run({
    jwplayer: {
      getState: () => 'playing',
      getPosition: () => 1400,
      getDuration: () => 2700,
      getVolume: () => 100,
      getMute: () => false
    }
  });
  assert.strictEqual(out.durSrc, 'clock');
  assert.strictEqual(out.dur, 2700);
});

// 7. Every video path has to carry the label: a payload without it would be
//    trusted by the app's fallback instead of being measured.
check('every video payload carries durSrc', () => {
  const payloads = [
    run({ video: { duration: 2700, currentTime: 10, volume: 1, muted: false, paused: false, ended: false } }),
    run({ video: { duration: Infinity, currentTime: 10, volume: 1, muted: false, paused: false, ended: false, seekable: { length: 1, end: () => 120 } } }),
    run({ clock: { dur: 2700, ct: 10, paused: false, ad: false } }),
    run({ jwplayer: { getState: () => 'paused', getPosition: () => 10, getDuration: () => 2700, getVolume: () => 100, getMute: () => false } })
  ];
  payloads.forEach((payload, index) => {
    assert.ok(Object.prototype.hasOwnProperty.call(payload, 'durSrc'), `payload ${index} has durSrc`);
  });
});

// 8. A same-origin iframe's video is found, and is labelled like any other.
check('a video inside a same-origin frame is measured too', () => {
  const inner = { duration: 2700, currentTime: 900, volume: 1, muted: false, paused: false, ended: false };
  const out = run({
    video: null,
    iframes: [{ contentDocument: { querySelector: () => inner } }]
  });
  assert.ok(out, 'the frame video is found');
  assert.strictEqual(out.durSrc, 'media');
  assert.strictEqual(out.dur, 2700);
});

console.log(checks.join('\n'));
if (process.exitCode) {
  console.log('poll duration source: checks failed');
} else {
  console.log('poll duration source scenarios passed');
}
