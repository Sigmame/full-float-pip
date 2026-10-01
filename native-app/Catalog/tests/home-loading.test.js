const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const policy = require('../site-access.js');

function load(fetchImpl, store = {}) {
    const context = vm.createContext({
        VibeSiteAccess: policy, console: { log() {}, warn() {}, error() {} }, URL, Date, setTimeout, clearTimeout,
        fetch: fetchImpl,
        chrome: { storage: { local: {
            async get(key) { return { [key]: store[key] }; },
            async set(value) { Object.assign(store, value); }
        } } }
    });
    context.__store = store;
    vm.runInContext(fs.readFileSync(path.join(__dirname, '../movie-service.js'), 'utf8') + '\nthis.service = MovieService;', context);
    return context.service;
}
const sleep = ms => new Promise(r => setTimeout(r, ms));
const page = n => ({ items: [{ slug: `tm-${n}`, name: `Phim ${n}`, language: 'Vietsub + Thuyết Minh', thumb_url: 'a.jpg', poster_url: 'b.jpg' }] });

(async () => {
    // The dubbed and voiced rows share one ten-page scan, and it is cached afterwards.
    let scanCalls = 0;
    let service = load(async () => { scanCalls++; return { json: async () => page(scanCalls) }; });
    const [tm, lt] = await Promise.all([service._getNguonCAudioList('thuyetminh'), service._getNguonCAudioList('longtieng')]);
    assert.equal(scanCalls, 10, 'Concurrent dubbed rows must share a single ten-request scan');
    assert.equal(tm.length, 10);
    assert.equal(lt.length, 0);
    await service._getNguonCAudioList('thuyetminh');
    assert.equal(scanCalls, 10, 'A completed scan is reused');

    // An outage (nothing scanned) is not cached for ten minutes.
    let down = true, outageCalls = 0;
    service = load(async () => { outageCalls++; if (down) throw new Error('offline'); return { json: async () => page(outageCalls) }; });
    assert.equal((await service._getNguonCAudioList('thuyetminh')).length, 0);
    down = false;
    assert.equal((await service._getNguonCAudioList('thuyetminh')).length, 10, 'Recovers on the next call after an outage');

    // Home rows survive a provider that never answers, and spotlight details start early.
    service = load(async () => { throw new Error('unused'); });
    service._requestTimeoutMs = 60;
    service._audioEnrichTimeoutMs = 30;
    const movie = slug => ({ slug, name: slug, thumb: 't.jpg', poster: 'p.jpg', source: 'kkphim', year: 2026, rating: 7 });
    let detailStartedAt = null, slowDone = false;
    const t0 = Date.now();
    service._getKKPhimList = async category => {
        if (category === 'hoathinh') { await sleep(400); slowDone = true; return [movie('never-waited-for')]; }
        if (category === 'thuyetminh' || category === 'longtieng') return [movie(`${category}-1`)];
        return [movie(`${category}-1`)];
    };
    service._getNguonCList = async () => [movie('nc-1')];
    service._getNguonCAudioList = async () => { await sleep(400); return [movie('late-audio')]; };
    service.getDetail = async slug => { detailStartedAt ??= Date.now() - t0; return { slug, content: 'Mô tả' }; };
    service.getFavorites = async () => [];
    service.getBecauseYouWatched = async () => ({ items: [] });
    let earlyAt = null, earlyCount = 0;
    const home = await service.getHomeSections('all', { onSpotlights: list => { earlyAt = Date.now() - t0; earlyCount = list.length; } });
    const elapsed = Date.now() - t0;
    assert(elapsed < 300, `Home must not wait for slow providers (took ${elapsed}ms)`);
    assert(!slowDone, 'The hung anime request was abandoned');
    assert(detailStartedAt !== null && detailStartedAt < 40, `Spotlight details start right after the billboard lists (${detailStartedAt}ms)`);
    assert(earlyAt !== null && earlyAt < 60, `Billboard is delivered before the slow rows finish (${earlyAt}ms)`);
    assert.equal(earlyCount, 4);
    assert.equal(home.spotlights.length, 4, 'Distinct chieurap/nc/bo/le titles become spotlights');
    assert(home.spotlights[0].content === 'Mô tả', 'Spotlight keeps its detail data');
    const ids = home.sections.map(s => s.id);
    assert(ids.includes('thuyetminh') && ids.includes('chieurap') && !ids.includes('anime'), `Rows: ${ids}`);
    const tmRow = home.sections.find(s => s.id === 'thuyetminh');
    assert.equal(tmRow.items[0].slug, 'thuyetminh-1', 'Dubbed row falls back to KKPhim items when the scan is slow');
    // Cache: saved after a good load, reused instantly, rebuilt "My list" from live favourites.
    const store = {};
    service = load(async () => { throw new Error('unused'); }, store);
    service._requestTimeoutMs = 60; service._audioEnrichTimeoutMs = 30;
    let favorites = [movie('fav-1')];
    service._getKKPhimList = async category => [movie(`${category}-1`), movie(`${category}-2`)];
    service._getNguonCList = async () => [movie('nc-1')];
    service._getNguonCAudioList = async () => [];
    service.getDetail = async slug => ({ slug, content: 'Mô tả' });
    service.getFavorites = async () => favorites;
    service.getBecauseYouWatched = async () => ({ items: [] });
    assert.equal(await service.getCachedHome('all'), null, 'Nothing cached before the first load');
    const fresh = await service.getHomeSections('all');
    assert(fresh.sections.some(s => s.id === 'mylist'), 'Fresh page includes My list');
    const saved = Object.values(store)[0];
    assert(saved && saved.sections.length && !saved.sections.some(s => s.id === 'mylist'), 'My list is never stored in the cache');
    favorites = [];
    const cached = await service.getCachedHome('all');
    assert(cached && cached.sections.length === fresh.sections.length - 1, 'Cached page rebuilds My list from live favourites (now empty)');
    assert.equal(cached.spotlights.length, fresh.spotlights.length);
    favorites = [movie('fav-2')];
    assert.equal((await service.getCachedHome('all')).sections[0].items[0].slug, 'fav-2', 'New favourite shows on a cached page');
    assert.equal(service.homeSignature(cached), service.homeSignature(fresh), 'My list does not change the signature');
    service._getKKPhimList = async category => [movie(`${category}-changed`)];
    assert.notEqual(service.homeSignature(await service.getHomeSections('all')), service.homeSignature(cached), 'New titles change the signature');
    Object.values(store)[0].at = Date.now() - 13 * 60 * 60 * 1000;
    assert.equal(await service.getCachedHome('all'), null, 'A cache older than twelve hours is ignored');
    service._getKKPhimList = async () => []; service._getNguonCList = async () => [];
    store[Object.keys(store)[0]] = { at: Date.now(), spotlights: [], sections: [] };
    assert.equal(await service.getCachedHome('all'), null, 'An empty cache entry is ignored');
    const before = JSON.stringify(store); // favourites still exist, so the outage page is not empty
    await service.getHomeSections('all');
    assert.equal(JSON.stringify(store), before, 'An empty result (provider outage) never overwrites the cache');
    // A partial outage (fewer rows, no error) must not replace a fuller valid cache.
    service._getKKPhimList = async category => [movie(`${category}-1`)];
    Object.values(store)[0].at = Date.now();
    store[Object.keys(store)[0]] = { at: Date.now(), spotlights: [movie('s')], sections: [1, 2, 3, 4].map(i => ({ id: `row${i}`, items: [movie(`r${i}`)] })) };
    service._getKKPhimList = async () => { throw new Error('down'); };
    service._getNguonCList = async () => [movie('nc-1')];
    await service.getHomeSections('all');
    assert.equal(Object.values(store)[0].sections.length, 4, 'A degraded page does not overwrite a fuller cache');
    assert.equal(service.homeRowCount({ sections: [{ id: 'mylist' }, { id: 'a' }] }), 1, 'My list is not counted as a row');
    console.log('home-loading: shared scan, outage recovery, timeouts, early spotlight details and early billboard and home cache passed');
})().catch(error => { console.error(error); process.exitCode = 1; });
