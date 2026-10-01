const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert');

const swift = fs.readFileSync(path.join(__dirname, '..', 'Sources', 'FloatWindow.swift'), 'utf8');
const marker = '    private static let embeddedMediaControlJavaScript = #"""';
const start = swift.indexOf(marker);
const bodyStart = start + marker.length;
const end = swift.indexOf('    """#', bodyStart);
assert(start >= 0 && end > bodyStart);
const source = swift.slice(bodyStart, end);

function frame(parent) {
  const handlers = {};
  const media = {
    playing: false,
    play() { this.playing = true; return Promise.resolve(); },
    pause() { this.playing = false; }
  };
  const children = [];
  const win = { parent, addEventListener(name, fn) { handlers[name] = fn; } };
  const document = { querySelectorAll(selector) {
    return selector === 'video' ? [media] : selector === 'iframe' ? children : [];
  } };
  vm.runInNewContext(source, { window: win, document });
  return { win, media, children, handlers };
}

const top = frame(null);
top.win.parent = top.win;
const child = frame(top.win);
const grandchild = frame(child.win);
top.children.push({ contentWindow: { postMessage(message) {
  child.handlers.message({ source: top.win, data: message });
} } });
child.children.push({ contentWindow: { postMessage(message) {
  grandchild.handlers.message({ source: child.win, data: message });
} } });

top.win.__floatControlEmbeddedMedia('pause');
assert(!top.media.playing && !child.media.playing && !grandchild.media.playing);
top.win.__floatControlEmbeddedMedia('play');
assert(top.media.playing && child.media.playing && grandchild.media.playing,
  'resuming Offline Dub reaches a player in nested cross-origin frames');
assert.equal(grandchild.win.__floatOfflineDubHold, false);
child.handlers.message({ source: {}, data: { __floatMediaControl: 'pause' } });
assert(child.media.playing, 'unrelated frames cannot control playback');
top.win.__floatControlEmbeddedMedia('pause');
assert(!top.media.playing && !child.media.playing && !grandchild.media.playing);
console.log('embedded media control scenarios passed');
