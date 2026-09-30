const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const html = fs.readFileSync(path.join(__dirname, '../popup.html'), 'utf8');
const nodes = new Map([...html.matchAll(/id="([^"]+)"/g)].map(([_, id]) => [id, {
    events: {}, children: {}, dataset: {}, value: id.endsWith('-search') ? '' : 'all',
    classList: { add() {}, remove() {}, toggle() {}, contains() { return false; } },
    setAttribute() {}, querySelectorAll() { return []; },
    querySelector(selector) { return this.children[selector] ||= {}; },
    addEventListener(type, callback) { (this.events[type] ||= []).push(callback); }
}]));
let boot;
const created = [];
const document = {
    addEventListener(type, callback) { if (type === 'DOMContentLoaded') boot = callback; },
    getElementById(id) { assert(nodes.has(id), `Startup accessed removed popup element: ${id}`); return nodes.get(id); }
};
const context = vm.createContext({
    document, console, setTimeout, clearTimeout,
    MovieImages: { install() {} },
    MovieService: { getYouTubeMovies() { return []; } },
    chrome: {
        runtime: { async sendMessage() { return { success: true, isGhost: false, isAIDubEnabled: false }; },
            getURL(page) { return `chrome-extension://test/${page}`; }, onMessage: { addListener() {} } },
        storage: { local: { async get() { return {}; } } },
        tabs: { create(options) { created.push(options); } }
    }
});
for (const file of ['native-status.js', 'popup.js']) vm.runInContext(fs.readFileSync(path.join(__dirname, '../' + file), 'utf8'), context);
let movieLoads = 0, continueLoads = 0;
context.loadPopupMovies = async () => { movieLoads++; };
context.loadPopupContinueStrip = async () => { continueLoads++; };
(async () => {
    await boot();
    assert.equal(movieLoads, 1, 'Load hot movies on opening without a tab switch');
    assert.equal(continueLoads, 1);
    for (const callback of nodes.get('btn-open-catalog').events.click) await callback();
    assert.equal(created.length, 1, 'One click must open one catalogue tab');
    assert.equal(created[0].url, 'chrome-extension://test/catalog.html');
    nodes.get('popup-source-select').value = 'nguonc';
    await nodes.get('popup-source-select').events.change[0]({ target: nodes.get('popup-source-select') });
    await nodes.get('popup-refresh-hot').events.click[0]();
    assert.equal(movieLoads, 3, 'Source selection and refresh remain available');
    const youtubeSearch = nodes.get('popup-youtube-search');
    const youtubeFilter = nodes.get('popup-youtube-filter');
    await youtubeSearch.events.input[0]();
    await youtubeFilter.events.change[0]();
    assert.equal(youtubeSearch.events.input.length, 1, 'filter redraw must not duplicate search handlers');
    assert.equal(youtubeFilter.events.change.length, 1, 'filter redraw must not duplicate filter handlers');
    assert.match(nodes.get('popup-youtube-list').innerHTML, /Không có phim khớp/);
    for (const id of ['tab-web', 'tab-recent', 'panel-web', 'panel-recent', 'popup-movie-search']) {
        assert(!nodes.has(id));
    }
    assert(!html.includes('popup-filter-chips'));
    console.log('popup-startup: simplified startup, source/refresh, and one catalogue tab per click passed');
})().catch(error => { console.error(error); process.exitCode = 1; });
