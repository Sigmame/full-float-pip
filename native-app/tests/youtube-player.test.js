const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '../Sources/FloatWindow.swift'), 'utf8');
const start = source.indexOf('private func loadPreferredYouTubeEmbed');
const scriptStart = source.indexOf('<script>', start) + '<script>'.length;
const scriptEnd = source.indexOf('</script>', scriptStart);
const script = source.slice(scriptStart, scriptEnd)
    .replaceAll('\\(videoId)', '4bjvj11fdV4').replaceAll('\\(origin)', 'https://com.aspect.floatvideo')
    .replaceAll('\\(start)', '0');
const calls = [];
let options;
const window = {};
let state = 1;
const player = {
    getCurrentTime: () => 12, getDuration: () => 6300, getVolume: () => 0,
    isMuted: () => true, getPlayerState: () => state,
    playVideo: () => calls.push(['play']), pauseVideo: () => calls.push(['pause']),
    seekTo: (...args) => calls.push(['seek', ...args]), setVolume: value => calls.push(['volume', value]),
    mute: () => calls.push(['mute']), unMute: () => calls.push(['unmute'])
};
const context = vm.createContext({window, document: {createElement: () => ({}), head: {appendChild() {}}},
    YT: {PlayerState: {PLAYING: 1, ENDED: 0}, Player: function(id, config) {options = config; return player;}}});
vm.runInContext(script, context);
assert.equal(window.getPlayerState(), null, 'polling before readiness must be safe');
window.playerCommand('play');
assert.equal(calls.length, 0);
vm.runInContext('onYouTubeIframeAPIReady()', context);
assert.equal(window.player, player, 'retain API player so native controls can reach it');
options.events.onReady({target: player});
assert.equal(window.__floatYt, 'ready');
const status = window.getPlayerState();
assert.equal(status.ct, 12);
assert.equal(status.dur, 6300);
assert.equal(status.vol, 0, 'preserve zero volume');
assert.equal(status.paused, false);
state = 2;
assert.equal(window.getPlayerState().paused, true);
state = 0;
assert.equal(window.getPlayerState().ended, true);
window.playerCommand('pause');
window.playerCommand('seek', 30);
window.playerCommand('volume', .5);
window.playerCommand('mute');
window.playerCommand('unmute');
assert.deepEqual(calls, [['play'], ['pause'], ['seek', 30, true], ['volume', 50], ['mute'], ['unmute']]);
options.events.onError({data: 153});
assert.equal(window.__floatYt, 'error:153');
console.log('youtube-player: readiness, progress, native controls, mute, and error reporting passed');
