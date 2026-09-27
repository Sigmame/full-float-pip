const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert');

const swift = fs.readFileSync(path.join(__dirname, '..', 'Sources', 'FloatWindow.swift'), 'utf8');
const start = swift.indexOf('    private static let smartFillJavaScript = #"""');
const bodyStart = start + '    private static let smartFillJavaScript = #"""'.length;
const end = swift.indexOf('    """#', bodyStart);
assert(start >= 0 && end > bodyStart);

let bars = 0;
let darkPicture = false;
// Rows of the top bar that a sponsor line / channel logo is burned into. The
// ink covers roughly a third of the row, so the row is still mostly black.
let banner = 0;
// A bright row at the very top edge, the way the reported capture starts: one
// non-black row before the bar is enough to stop a leading-run scan.
let edgeGap = false;
// A band across the top only, with picture running to the last row. This is the
// reported stream: no bottom bar for the "both edges" test to pair it with.
let topOnly = false;
// A *dim* band (above the near-black threshold) is not a bar and must not crop.
let dimBar = false;
const styles = {};
const listeners = {};
const timers = [];
const video = {
  videoWidth: 1920, videoHeight: 1080, clientWidth: 640, clientHeight: 360,
  readyState: 2, paused: false, isConnected: true,
  style: { setProperty(name, value) { styles[name] = value; } },
  addEventListener(name, fn) { listeners[name] = fn; }
};
const canvas = {
  getContext() {
    return {
      drawImage() {},
      getImageData() {
        const pixels = new Uint8ClampedArray(96 * 72 * 4);
        for (let y = 0; y < 72; y++) {
          const inPicture = !darkPicture && y >= bars && (topOnly || y < 72 - bars);
          for (let x = 0; x < 96; x++) {
            const p = (y * 96 + x) * 4;
            const gap = edgeGap && y === 0;
            const ink = y < banner && x % 3 === 0;
            const light = gap ? 200 : (ink ? 230 : (inPicture ? 150 : (dimBar ? 60 : 0)));
            pixels[p] = pixels[p + 1] = pixels[p + 2] = light;
            pixels[p + 3] = 255;
          }
        }
        return { data: pixels };
      }
    };
  }
};
const window = {};
vm.runInNewContext(swift.slice(bodyStart, end), {
  window, document: { createElement() { return canvas; } },
  setInterval(fn, ms) { timers.push({ fn, ms }); return timers.length; },
  clearInterval() {}
});
window.__floatInstallSmartFill(video);
const scan = timers.find(item => item.ms === 800);
assert(scan, 'scanner remains active during playback');
scan.fn(); scan.fn();
assert.match(styles.transform, /scale\(1\.0000\)/, 'normal image stays unzoomed');

bars = 9;
scan.fn(); scan.fn();
assert.match(styles.transform, /scale\(1\.0000\)/, 'one or two frames do not cause flicker');
scan.fn();
assert.match(styles.transform, /scale\(1\.3333\)/, 'persistent internal bars are removed');
styles.transform = 'none'; // the embed player rewrites the video style
scan.fn();
assert.match(styles.transform, /scale\(1\.3333\)/, 'scanner restores crop after player CSS changes');

darkPicture = true;
scan.fn(); scan.fn(); scan.fn();
assert.match(styles.transform, /scale\(1\.3333\)/, 'a dark scene does not undo the crop');
darkPicture = false;
bars = 6;
listeners.seeked(); scan.fn(); scan.fn();
assert.match(styles.transform, /scale\(1\.2000\)/, 'crop follows a changed source');

bars = 0;
scan.fn(); scan.fn(); scan.fn();
assert.match(styles.transform, /scale\(1\.0000\)/, 'crop clears after bars disappear');
video.clientHeight = 400;
window.__floatInstallSmartFill(video);
assert.match(styles.transform, /scale\(1\.1111\)/, 'resize recomputes the fit');
video.currentSrc = 'https://example.com/episode-2.mp4';
window.__floatInstallSmartFill(video);
assert.equal(styles.transform, 'none', 'a new source clears the previous crop immediately');

// The real-world case: the sponsor line (the `9922.com` banner) and the channel
// logo are burned into the top black bar, so a strict "every sampled pixel must
// be black" row test never reached the required bar height and nothing was
// cropped. The bars must still be found — which also crops the banner with them.
bars = 9;
banner = 4;
video.clientHeight = 360;
video.currentSrc = 'https://example.com/episode-3.mp4';
window.__floatInstallSmartFill(video);
scan.fn(); scan.fn(); scan.fn();
assert.match(styles.transform, /scale\(1\.3333\)/, 'a banner burned into the top bar does not block the crop');

// Two text lines instead of one, and a bottom-bar watermark as well.
banner = 7;
styles.transform = 'none';
scan.fn(); scan.fn();
assert.match(styles.transform, /scale\(1\.3333\)/, 'the crop is restored while the banner is still on screen');

// The reported capture as measured: the sampled frame starts with one bright
// row (a window/video edge) and then the black bar with the sponsor line burned
// into it. A leading-run scan stops on row 0 and never crops; the run search has
// to look past it. Old code: scale(1.0000). New code: scale(1.3333).
bars = 9;
banner = 4;
edgeGap = true;
styles.transform = 'none';
video.currentSrc = 'https://example.com/episode-4.mp4';
window.__floatInstallSmartFill(video);
scan.fn(); scan.fn(); scan.fn();
assert.match(styles.transform, /scale\(1\.3333\)/, 'a bright first row does not stop the crop');

// The reported episode, as measured: a black band across the top and picture to
// the last row. Requiring a matching bottom bar left it on screen. Old code:
// scale(1.0000). New code: scale(1.0588).
edgeGap = false;
topOnly = true;
bars = 4;
styles.transform = 'none';
video.currentSrc = 'https://example.com/episode-5.mp4';
window.__floatInstallSmartFill(video);
scan.fn(); scan.fn(); scan.fn();
assert.match(styles.transform, /scale\(1\.0588\)/, 'a top-only bar is cropped');

// A dim band (not near-black) is not a bar: it must not zoom the picture.
topOnly = false;
dimBar = true;
bars = 4;
styles.transform = 'none';
video.currentSrc = 'https://example.com/episode-6.mp4';
window.__floatInstallSmartFill(video);
scan.fn(); scan.fn(); scan.fn();
assert.match(styles.transform, /scale\(1\.0000\)/, 'a merely dim band is not cropped');

dimBar = false;
console.log('black bar detection scenarios passed');
