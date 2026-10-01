const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

// --- youtubeIdFromUrl (movie-service) ---
const context = vm.createContext({
    VibeSiteAccess: require('../site-access.js'), console, URL, Date, setTimeout, clearTimeout,
    chrome: { storage: { local: { async get() { return {}; }, async set() {} } } }
});
vm.runInContext(fs.readFileSync(path.join(__dirname, '../movie-service.js'), 'utf8') + '\nthis.service = MovieService;', context);
const id = url => context.service.youtubeIdFromUrl(url);
assert.equal(id('https://www.youtube.com/watch?v=wXzhEhCOlnM'), 'wXzhEhCOlnM');
assert.equal(id('https://www.youtube.com/watch?v=-StZwoYw2fg'), '-StZwoYw2fg', 'ids may start with a dash');
assert.equal(id('https://www.youtube.com/watch?feature=share&v=OiNxXvG3Wj8&t=3'), 'OiNxXvG3Wj8');
assert.equal(id('https://youtu.be/5Z8oBbmkgXo?si=abc'), '5Z8oBbmkgXo');
assert.equal(id('https://www.youtube.com/embed/5Z8oBbmkgXo'), '5Z8oBbmkgXo');
assert.equal(id('https://m.youtube.com/shorts/5Z8oBbmkgXo'), '5Z8oBbmkgXo');
assert.equal(id('https://www.youtube-nocookie.com/embed/5Z8oBbmkgXo'), '5Z8oBbmkgXo');
for (const bad of ['', null, undefined, 'http://www.youtube.com/watch?v=wXzhEhCOlnM', 'https://evil.com/watch?v=wXzhEhCOlnM',
    'https://www.youtube.com.evil.com/watch?v=wXzhEhCOlnM', 'https://www.youtube.com/watch?v=short', 'https://www.youtube.com/watch?v=wXzhEhCOlnMextra',
    'https://www.youtube.com/watch?v="><script>', 'javascript:alert(1)', 'https://www.youtube.com/watch']) {
    assert.equal(id(bad), '', `must reject ${bad}`);
}

// --- heroTrailerAllowed (catalog) ---
const source = fs.readFileSync(path.join(__dirname, '../catalog.js'), 'utf8');
const start = source.indexOf('function heroTrailerAllowed');
const end = source.indexOf('function heroTrailerState');
assert(start >= 0 && end > start, 'heroTrailerAllowed must exist in catalog.js');
const rules = vm.createContext({});
vm.runInContext(source.slice(start, end) + '\nthis.allowed = heroTrailerAllowed;', rules);
const ok = { native: true, enabled: true, reducedMotion: false, hidden: false, dialogOpen: false, trailerId: 'wXzhEhCOlnM' };
assert.equal(rules.allowed(ok), true, 'all conditions met');
for (const [name, patch] of Object.entries({
    'not the native app': { native: false }, 'switched off': { enabled: false }, 'reduced motion': { reducedMotion: true },
    'window hidden': { hidden: true }, 'a dialog is open': { dialogOpen: true }, 'no trailer': { trailerId: '' },
    'missing trailer': { trailerId: undefined }, 'malformed id': { trailerId: 'abc' }, 'id with markup': { trailerId: 'a"b><script>' }
})) {
    assert.equal(rules.allowed({ ...ok, ...patch }), false, `blocked when ${name}`);
}
console.log('hero-trailer: YouTube id parsing (hosts, formats, rejects) and playback rules passed');
