const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const policy = require('../site-access.js');
const read = name => fs.readFileSync(path.join(__dirname, '..', name), 'utf8');

async function run() {
    for (const domain of policy.movieDomains) {
        assert.equal(policy.allowsPage(`https://${domain}/watch`), true);
        assert.equal(policy.allowsPage(`https://player.${domain}/watch`), true);
        for (const raw of [`https://${domain}.evil.com/`, `https://evil${domain}/`,
            `https://evil.com/?next=https://${domain}`, `http://${domain}/`,
            `https://${domain}@evil.com/`, `https://evil@${domain}/`]) {
            assert.equal(policy.allowsPage(raw), false, raw);
        }
    }
    for (const raw of ['https://www.youtube.com/watch?v=x', 'https://mail.google.com/',
        'file:///private/data', 'javascript:alert(1)', 'not a URL']) {
        assert.equal(policy.allowsPage(raw), false);
    }
    const manifest = JSON.parse(read('manifest.json'));
    for (const permission of ['activeTab', 'tabs', 'cookies']) {
        assert.equal(manifest.permissions.includes(permission), false);
    }
    const expected = policy.movieDomains.map(domain => `https://*.${domain}/*`);
    for (const script of manifest.content_scripts) {
        assert.deepEqual(script.matches, expected);
        assert.equal(script.all_frames, false, 'do not inspect movie iframes on unrelated tabs');
        assert.equal(script.js[0], 'site-access.js');
    }
    assert.deepEqual(manifest.web_accessible_resources[0].matches, expected);
    assert.deepEqual(manifest.host_permissions, [...expected, 'https://phimimg.com/*']);

    // A stale or manually injected detector must return without reading the DOM.
    vm.runInNewContext(read('content.js'), {
        VibeSiteAccess: policy, window: { location: { href: 'https://mail.google.com/' } },
        document: new Proxy({}, { get() { throw new Error('unexpected DOM read'); } })
    });

    let listener, shortcut, scanned = false;
    const rootURL = 'chrome-extension://test/';
    const context = vm.createContext({
        URL, console, setTimeout, clearTimeout, VibeSiteAccess: policy,
        importScripts() {},
        chrome: {
            runtime: { getURL: () => rootURL, onMessage: { addListener(fn) { listener = fn; } } },
            tabs: {
                onRemoved: { addListener() {} }, onUpdated: { addListener() {} },
                sendMessage: async () => { scanned = true; }
            },
            commands: { onCommand: { addListener(fn) { shortcut = fn; } } },
            storage: { local: { get: async () => ({ vibe_ai_dubbing_enabled: true }) } }
        }
    });
    vm.runInContext(read('background.js'), context);
    vm.runInContext('manager.floatVideo = async info => ({ success: false, enabled: info.aiDubEnabled });', context);
    const request = sender => new Promise(resolve => listener({
        type: 'FLOAT_VIDEO_REQUEST', videoInfo: { src: 'https://cdn.kkphimplayer.com/movie.m3u8' }
    }, sender, resolve));
    assert.equal((await request({ url: 'https://mail.google.com/', tab: { id: 1, url: 'https://mail.google.com/' } })).success, false);
    await shortcut('float-current-video', { id: 1, url: 'https://mail.google.com/' });
    assert.equal(scanned, false, 'shortcut must not contact scripts on unrelated pages');
    const result = await request({ url: `${rootURL}catalog.html`, tab: { id: 2, url: `${rootURL}catalog.html` } });
    assert.equal(result.enabled, false, 'old default-ON preference cannot enable dubbing');
    context.chrome.storage.local.get = async () => { throw new Error('storage unavailable'); };
    assert.equal((await request({ url: `${rootURL}popup.html` })).enabled, false);
    context.chrome.storage.local.get = async () => ({ vibe_ai_dubbing_enabled_v2: true });
    assert.equal((await request({ url: `${rootURL}popup.html` })).enabled, true, 'fresh explicit opt-in is honored');
    vm.runInContext('manager.connectNative = () => false;', context);
    const selected = policy.youtubeMovies[0].id;
    context.payload = {
        pageUrl: `https://www.youtube.com/watch?v=${selected}`,
        embedUrl: `https://www.youtube.com/embed/${selected}`,
        site: 'youtube', preferEmbed: true
    };
    let open = await vm.runInContext('manager._doFloatVideo(payload, null)', context);
    assert.match(open.error, /Native app not connected/, 'curated movie reaches the player connection');
    context.payload.preferEmbed = false;
    open = await vm.runInContext('manager._doFloatVideo(payload, null)', context);
    assert.match(open.error, /Chỉ phát các phim YouTube/, 'watch-page fallback is denied');
    context.payload.preferEmbed = true;
    context.payload.embedUrl = `https://www.youtube.com/embed/${policy.youtubeMovies[1].id}`;
    open = await vm.runInContext('manager._doFloatVideo(payload, null)', context);
    assert.match(open.error, /Chỉ phát các phim YouTube/, 'mismatched movie IDs are denied');
    context.payload.pageUrl = 'https://www.youtube.com/watch?v=rFZHOHl-L8A';
    open = await vm.runInContext('manager._doFloatVideo(payload, null)', context);
    assert.match(open.error, /chỉ được đọc/, 'unlisted YouTube videos are denied');
    console.log('site-access: host boundaries, manifest scope, denied DOM reads, shortcut, and dubbing opt-in passed');
}
run().catch(error => { console.error(error); process.exitCode = 1; });
