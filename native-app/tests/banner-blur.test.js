const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert');

const swift = fs.readFileSync(path.join(__dirname, '..', 'Sources', 'FloatWindow.swift'), 'utf8');
const marker = '    private static let bannerBlurJavaScript = #"""';
const start = swift.indexOf(marker);
assert(start >= 0, 'the shared banner blur script exists');
const bodyStart = start + marker.length;
const end = swift.indexOf('    """#', bodyStart);
assert(end > bodyStart, 'the banner blur script is terminated');
const source = swift.slice(bodyStart, end);

const SW = 180;
const SH = 32;
// `banner` stands in for the burned-in sponsor line: white outlined type on a
// black band, which reads as alternating bright/dark with dark above the ink.
let banner = false;
function sampleContext() {
  return {
    drawImage() {},
    getImageData() {
      const data = new Uint8ClampedArray(SW * SH * 4);
      for (let y = 0; y < SH; y++) {
        for (let x = 0; x < SW; x++) {
          const p = (y * SW + x) * 4;
          const ink = banner && (x + y) % 2 === 0;
          const value = banner ? (ink ? 255 : 0) : 128;
          data[p] = data[p + 1] = data[p + 2] = value;
          data[p + 3] = 255;
        }
      }
      return { data };
    }
  };
}

const timers = [];
const elements = {};
const body = {
  lastElementChild: null,
  appendChild(node) {
    this.lastElementChild = node;
    node.parentNode = this;
  }
};
const document = {
  body,
  getElementById(id) { return elements[id] || null; },
  createElement(tag) {
    if (tag === 'canvas') return { width: 0, height: 0, getContext: () => sampleContext() };
    const element = { style: {}, setAttribute() {} };
    Object.defineProperty(element, 'id', {
      get() { return this._id; },
      set(value) { this._id = value; elements[value] = element; }
    });
    return element;
  },
  querySelector() { return video; }
};
const video = { videoWidth: 1920, videoHeight: 1080, readyState: 4, paused: false, isConnected: true };
const window = {};
// Controllable clock: the forced cover carries a deadline so a stopped scan
// cannot leave the frame covered forever.
let now = 100000;
const clock = class extends Date { static now() { return now; } };

vm.runInNewContext(source, {
  window, document, Date: clock,
  setInterval(fn, ms) { timers.push({ fn, ms }); return timers.length; }
});

assert.equal(typeof window.__floatInstallAdBlur, 'function', 'the installer is published');

window.__floatInstallAdBlur(video);
const overlay = document.getElementById('float-ad-blur');
assert(overlay, 'the overlay element is created');
assert.equal(overlay.style.position, 'fixed');
assert.equal(overlay.style.zIndex, '2147483647', 'the overlay ties the video z-index and wins by DOM order');
assert.equal(overlay.style.backdropFilter, 'blur(28px) saturate(0.75)');
assert.equal(body.lastElementChild, overlay, 'the overlay is painted after the video');
assert.equal(overlay.style.opacity, '0', 'the overlay starts hidden');
assert.equal(timers.length, 1, 'exactly one blur timer is installed');
assert.equal(timers[0].ms, 450);
const tick = timers[0].fn;

tick(); tick(); tick(); tick(); tick();
assert.equal(overlay.style.opacity, '0', 'a normal top band is never blurred');

banner = true;
tick();
assert.equal(overlay.style.opacity, '0', 'one banner frame does not flicker the blur on');
tick();
assert.equal(overlay.style.opacity, '1', 'two banner frames raise the blur');

banner = false;
tick(); tick(); tick();
assert.equal(overlay.style.opacity, '1', 'brief clear frames keep the blur');
tick();
assert.equal(overlay.style.opacity, '0', 'the blur clears once the line is gone');

// Page chrome inserted after the overlay would paint over it. Installing again
// must lift the overlay back to the end without stacking a second timer.
const extra = document.createElement('div');
body.appendChild(extra);
window.__floatInstallAdBlur(video);
assert.equal(timers.length, 1, 're-installing does not stack timers');
assert.equal(body.lastElementChild, overlay, 'the overlay is re-appended above later nodes');

// A paused or detached video must stop the sampler from acting.
banner = true;
video.paused = true;
tick(); tick();
assert.equal(overlay.style.opacity, '0', 'a paused video is not sampled');
video.paused = false;
video.isConnected = false;
tick(); tick();
assert.equal(overlay.style.opacity, '0', 'a detached video is not sampled');
video.isConnected = true;

// Native decides when the ad is not part of the video's own pixels — a spot
// drawn as page markup, or one inside a cross-origin player frame — because the
// in-page scanner cannot see those at all.
now += 10000;
tick();
assert.equal(overlay.style.opacity, '0', 'a clear frame before anything is forced');
window.__floatForceAdCover(true, true);
assert.equal(overlay.style.opacity, '1', 'a forced cover is painted at once');
assert.equal(overlay.style.height, '100%', 'a forced splash covers the whole frame');
assert.match(overlay.style.backdropFilter, /blur\(32px\)/, 'a forced splash blurs hard');
assert.equal(overlay.style.maskImage, 'none', 'a full cover is not faded out at the bottom');
tick();
assert.equal(overlay.style.opacity, '1', 'the forced cover survives the next tick');
banner = true;
tick(); tick();
assert.equal(overlay.style.height, '100%', 'the page scanner does not downgrade a forced cover');
window.__floatForceAdCover(true, false);
assert.equal(overlay.style.height, 'calc(38px + 16%)', 'band mode covers only the top');
window.__floatForceAdCover(false);
assert.equal(overlay.style.opacity, '0', 'the cover lifts when native reports the ad gone');
banner = false;

// Deadline safety net: scans stopping mid-ad must not leave the frame covered.
video.paused = true;
window.__floatForceAdCover(true, true);
now += 5000;
tick();
assert.equal(overlay.style.opacity, '0', 'an unrefreshed forced cover expires');
video.paused = false;

console.log('banner blur scenarios passed');
