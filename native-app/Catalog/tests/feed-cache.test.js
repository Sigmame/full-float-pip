const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const policy = require('../site-access.js');

const store = {};
const context = vm.createContext({
    VibeSiteAccess: policy, console: { log() {}, warn() {}, error() {} }, URL, Date, setTimeout, clearTimeout,
    chrome: { storage: { local: {
        async get(key) { return { [key]: store[key] }; },
        async set(value) { Object.assign(store, value); }
    } } }
});
vm.runInContext(fs.readFileSync(path.join(__dirname, '../movie-service.js'), 'utf8') + '\nthis.service = MovieService;', context);
const service = context.service;
const items = n => Array.from({ length: n }, (_, i) => ({ slug: `m-${i}`, source: 'kkphim', name: `M ${i}` }));

(async () => {
    assert.equal(await service.getCachedFeed('a'), null, 'Nothing cached yet');
    await service.saveFeedPage('a', []);
    assert.equal(await service.getCachedFeed('a'), null, 'An empty page is never stored');
    await service.saveFeedPage('a', items(6));
    assert.equal((await service.getCachedFeed('a')).items.length, 6);

    // A sliver of a page (partial outage) does not replace a fuller one; a comparable one does.
    await service.saveFeedPage('a', items(2));
    assert.equal((await service.getCachedFeed('a')).items.length, 6, 'Fewer than half the items is treated as an outage');
    await service.saveFeedPage('a', items(4));
    assert.equal((await service.getCachedFeed('a')).items.length, 4, 'A normal refresh replaces the entry');

    // Age limit: six hours.
    store[service._feedCacheKey].entries.a.at = Date.now() - 7 * 60 * 60 * 1000;
    assert.equal(await service.getCachedFeed('a'), null, 'An entry older than six hours is ignored');
    await service.saveFeedPage('a', items(1));
    assert.equal((await service.getCachedFeed('a')).items.length, 1, 'An expired entry can be replaced by anything');

    // Bounded size: the least recently stored list is evicted.
    for (let i = 0; i < service._feedCacheMaxEntries + 3; i++) await service.saveFeedPage(`k${i}`, items(3));
    const cache = store[service._feedCacheKey];
    assert.equal(Object.keys(cache.entries).length, service._feedCacheMaxEntries);
    assert.equal(cache.order.length, service._feedCacheMaxEntries);
    assert.equal(await service.getCachedFeed('k0'), null, 'Oldest entries are evicted first');
    assert((await service.getCachedFeed(`k${service._feedCacheMaxEntries + 2}`)).items.length === 3, 'Newest entry is kept');

    // Re-saving moves a key to the most recent position.
    await service.saveFeedPage('k5', items(3));
    assert.equal(store[service._feedCacheKey].order.at(-1), 'k5');

    assert.equal(service.feedSignature(items(2)), 'kkphim:m-0,kkphim:m-1');
    assert.equal(service.feedSignature(null), '');
    console.log('feed-cache: store, empty and sliver guards, six-hour age limit and LRU bound passed');
})().catch(e => { console.error(e); process.exitCode = 1; });
