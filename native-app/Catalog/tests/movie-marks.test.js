const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');

const store = {};
const context = vm.createContext({
    VibeSiteAccess: require('../site-access.js'), console: { log() {}, warn() {}, error() {} }, URL, Date, setTimeout, clearTimeout,
    chrome: { storage: { local: {
        async get(key) { return { [key]: store[key] }; },
        async set(value) { Object.assign(store, JSON.parse(JSON.stringify(value))); }
    } } }
});
vm.runInContext(fs.readFileSync(path.join(__dirname, '../movie-service.js'), 'utf8') + '\nthis.service = MovieService;', context);
const service = context.service;
const movie = (n, extra = {}) => ({ slug: `m-${n}`, name: `Phim ${n}`, source: 'kkphim', year: 2026, quality: 'FHD', rating: '8.1', hasThuyetMinh: n % 2 === 0, ...extra });

(async () => {
    // Watched: mark, unmark, newest first, no duplicates, remembers what a card needs.
    assert.deepEqual([...(await service.getWatchedSlugSet())], [], 'nothing watched to begin with');
    assert.equal(await service.setWatched(movie(1), true), true);
    assert.equal(await service.setWatched(movie(2), true), true);
    assert.equal(await service.setWatched(movie(1), true), true, 'marking twice is harmless');
    let watched = await service.getWatched();
    assert.deepEqual([...watched.map(m => m.slug)], ['m-1', 'm-2'], 'most recent mark first, no duplicate');
    assert.equal(watched[0].name, 'Phim 1');
    assert.equal(watched[1].hasThuyetMinh, true);
    assert.equal(watched[0].quality, 'FHD');
    assert(watched[0].markedAt > 0, 'remembers when');
    assert.equal(await service.setWatched(movie(2), false), false, 'unmarking resolves false');
    assert.deepEqual([...(await service.getWatchedSlugSet())], ['m-1']);

    // Hidden is a separate list.
    assert.equal(await service.setHidden(movie(3), true), true);
    assert.deepEqual([...(await service.getHiddenSlugSet())], ['m-3']);
    assert.deepEqual([...(await service.getWatchedSlugSet())], ['m-1'], 'hiding does not mark as watched');
    assert.equal(await service.setHidden(movie(3), false), false);
    assert.equal((await service.getHidden()).length, 0, 'unhide empties the list');

    // Bad input and the size cap.
    assert.equal(await service.setHidden(null, true), false);
    assert.equal(await service.setHidden({ name: 'no slug' }, true), false);
    for (let i = 0; i < service._marksMax + 25; i++) await service.setWatched(movie(1000 + i), true);
    assert.equal((await service.getWatched()).length, service._marksMax, 'the list is bounded');
    assert.equal((await service.getWatched())[0].slug, `m-${1000 + service._marksMax + 24}`, 'newest kept');

    // Stored data that is not a list is ignored.
    store.vibe_hidden = { not: 'a list' };
    assert.equal((await service.getHidden()).length, 0, 'data that is not a list reads as empty');
    delete store.vibe_hidden;

    // withoutHidden: pure filter.
    const items = [movie(1), movie(2), movie(3), null];
    assert.deepEqual([...service.withoutHidden(items, new Set(['m-2'])).filter(Boolean).map(m => m.slug)], ['m-1', 'm-3']);
    assert.equal(service.withoutHidden(items, new Set()).length, 4, 'an empty set keeps everything');
    assert.equal(service.withoutHidden(undefined, new Set(['m-1'])).length, 0);

    console.log('movie-marks: watched and hidden lists, order, cap, bad input and filtering passed');
})().catch(e => { console.error(e); process.exitCode = 1; });
