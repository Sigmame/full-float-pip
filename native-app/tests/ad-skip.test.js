const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert');
const swift = fs.readFileSync(path.join(__dirname, '..', 'Sources', 'FloatWindow.swift'), 'utf8');
const guardStart = swift.indexOf('    private func injectAdSkip() {');
assert(guardStart >= 0, 'ad guard exists');
const scriptStart = swift.indexOf('        let js = """', guardStart) + '        let js = """'.length;
const scriptEnd = swift.indexOf('        """', scriptStart);
assert(scriptEnd > scriptStart, 'embedded JavaScript exists');
const source = swift.slice(scriptStart, scriptEnd);
function scenario({ ad, button, duration = 30 }) {
  let now = 10000;
  let tick;
  let clicks = 0;
  const body = {};
  const style = { setProperty() {}, removeProperty() {} };
  const skip = button ? {
    disabled: false, style,
    getAttribute() { return null; },
    getBoundingClientRect() { return { left: 20, top: 20, width: 50, height: 20 }; },
    click() { clicks++; }
  } : null;
  const video = { currentTime: 0, duration };
  const player = {
    classList: { contains(name) { return ad && name === 'ad-showing'; } },
    style: { setProperty() { throw new Error('must not hide player root'); } },
    parentElement: body,
    querySelector(sel) { return sel === 'video' ? video : null; }
  };
  if (skip) skip.parentElement = player;
  const document = {
    body,
    querySelector(sel) {
      if (sel === '#movie_player, .html5-video-player') return player;
      if (sel === 'video') return video;
      return skip;
    }
  };
  const window = { innerWidth: 300, innerHeight: 200 };
  const clock = class extends Date { static now() { return now; } };
  vm.runInNewContext(source, {
    window, document, Date: clock,
    setInterval(fn, interval) { assert.equal(interval, 200); tick = fn; }
  });
  return { window, video, run(time, currentTime) { now = time; video.currentTime = currentTime; tick(); }, get clicks() { return clicks; } };
}
const content = scenario({ ad: false, button: true });
content.run(10000, 2);
assert.equal(content.window.__floatVideoAdFFCount, 0, 'content never seeks');
const noButton = scenario({ ad: true, button: false });
noButton.run(10000, 0);
noButton.run(11400, 1.4);
assert.equal(noButton.window.__floatVideoAdFFCount, 1, 'active ad without Skip seeks promptly');
assert(noButton.video.currentTime > 29);
const longVideo = scenario({ ad: true, button: false, duration: 3600 });
longVideo.run(10000, 0);
longVideo.run(11400, 1.4);
assert.equal(longVideo.window.__floatVideoAdFFCount, 0, 'long content is not sought as an ad');
const skippable = scenario({ ad: true, button: true });
skippable.run(10000, 0);
assert.equal(skippable.window.__floatVideoAdSkipCount, 1, 'first skip attempt immediate');
assert(skippable.window.__floatVideoPendingTrustedClick);
skippable.window.__floatVideoPendingTrustedClick = null;
skippable.run(10800, 0.8);
assert.equal(skippable.window.__floatVideoAdFFCount, 0);
skippable.run(12000, 2);
assert.equal(skippable.window.__floatVideoAdFFCount, 1, 'ignored clicks seek after two attempts');
console.log('ad guard scenarios passed');
