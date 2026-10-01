const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');

const KB = 1024;
function load({ fetchImpl, store = {} }) {
    const context = vm.createContext({
        console: { log() {}, warn() {}, error() {} }, URL, Date, setTimeout, clearTimeout, AbortController, Map, Object, Number, Promise,
        VibeSiteAccess: require('../site-access.js'),
        fetch: fetchImpl,
        chrome: { storage: { local: {
            async get(key) { return { [key]: store[key] }; },
            async set(value) { Object.assign(store, value); }
        } } }
    });
    vm.runInContext(fs.readFileSync(path.join(__dirname, '../movie-service.js'), 'utf8') + '\nthis.images = MovieImages;', context);
    return { images: context.images, store };
}
const sizesFor = table => async (url, init) => {
    if (init.signal?.aborted) throw new Error('aborted');
    if (!(url in table)) return { ok: false, headers: { get: () => null } };
    return { ok: true, headers: { get: name => (name.toLowerCase() === 'content-length' ? String(table[url]) : null) } };
};
const movie = (slug, poster, thumb) => ({ slug, poster: `https://phimimg.com/${poster}.webp`, thumb: `https://phimimg.com/${thumb}.webp` });
const url = name => `https://phimimg.com/${name}.webp`;

(async () => {
    // A heavy poster with a much lighter thumb switches to the thumb; ordinary titles are untouched.
    const calls = [];
    const table = { [url('heavy-p')]: 600 * KB, [url('heavy-t')]: 40 * KB, [url('ok-p')]: 60 * KB, [url('ok-t')]: 70 * KB };
    let { images, store } = load({ fetchImpl: async (u, i) => { calls.push(u); return sizesFor(table)(u, i); } });
    const heavy = movie('heavy', 'heavy-p', 'heavy-t'), ok = movie('ok', 'ok-p', 'ok-t');
    await images.preflight([heavy, ok], 'poster');
    assert.equal(images.pick(heavy, 'poster').src, url('heavy-t'), 'Heavy poster is replaced by the lighter thumb');
    assert.equal(images.pick(heavy, 'poster').alt, url('heavy-p'), 'The original stays as the error fallback');
    assert.equal(images.pick(ok, 'poster').src, url('ok-p'), 'A normal poster is untouched');
    assert(!calls.includes(url('ok-t')), 'Only heavy titles get their alternative measured');
    assert.equal(calls.length, 3);

    // Sizes are remembered: a second pass (and a fresh page load from storage) makes no requests.
    const before = calls.length;
    await images.preflight([heavy, ok], 'poster');
    assert.equal(calls.length, before, 'Known sizes are not probed again');
    const reloaded = load({ fetchImpl: async () => { throw new Error('must not probe'); }, store });
    const again = movie('heavy', 'heavy-p', 'heavy-t');
    await reloaded.images.preflight([again], 'poster');
    assert.equal(reloaded.images.pick(again, 'poster').src, url('heavy-t'), 'The decision survives a reload without any request');

    // The decision belongs to the kind it was measured for: Cinema view must not inherit Poster's swap.
    assert.equal(images.pick(heavy, 'wide').src, url('heavy-t'), 'Wide artwork keeps its own (thumb) choice');
    assert.equal(images.pick(heavy, 'wide').alt, url('heavy-p'));

    // An alternative that is not clearly lighter is not used.
    ({ images } = load({ fetchImpl: sizesFor({ [url('a-p')]: 300 * KB, [url('a-t')]: 290 * KB }) }));
    const similar = movie('a', 'a-p', 'a-t');
    await images.preflight([similar], 'poster');
    assert.equal(images.pick(similar, 'poster').src, url('a-p'), 'Needs at least 20% saving');

    // Wide artwork uses the same rule.
    ({ images } = load({ fetchImpl: sizesFor({ [url('w-t')]: 500 * KB, [url('w-p')]: 50 * KB }) }));
    const wide = movie('w', 'w-p', 'w-t');
    await images.preflight([wide], 'wide');
    assert.equal(images.pick(wide, 'wide').src, url('w-p'));

    // Failures change nothing: offline, blocked, and no Content-Length.
    for (const impl of [async () => { throw new Error('offline'); }, async () => ({ ok: false, headers: { get: () => null } }), async () => ({ ok: true, headers: { get: () => null } })]) {
        ({ images } = load({ fetchImpl: impl }));
        const m = movie('x', 'x-p', 'x-t');
        await images.preflight([m], 'poster');
        assert.equal(images.pick(m, 'poster').src, url('x-p'), 'Unmeasurable artwork is shown as before');
    }

    // A server that never answers is abandoned within the budget.
    ({ images } = load({ fetchImpl: (u, init) => new Promise((_, reject) => init.signal.addEventListener('abort', () => reject(new Error('aborted')))) }));
    const slow = movie('s', 's-p', 's-t');
    const t0 = Date.now();
    await images.preflight([slow], 'poster', 80);
    assert(Date.now() - t0 < 400, `Preflight honours its budget (${Date.now() - t0}ms)`);
    assert.equal(images.pick(slow, 'poster').src, url('s-p'));

    // The built-in placeholder is never requested, and probing is limited to the unknown.
    const seen = [];
    ({ images } = load({ fetchImpl: async u => { seen.push(u); return { ok: true, headers: { get: () => '1000' } }; } }));
    await images.preflight([{ slug: 'none' }, movie('p', 'p-p', 'p-t'), movie('p', 'p-p', 'p-t')], 'poster');
    assert(!seen.some(u => u.startsWith('data:')), 'The fallback image is not probed');
    assert.equal(seen.length, 1, 'The same URL is probed once');

    // The remembered table is bounded.
    ({ images, store } = load({ fetchImpl: async () => ({ ok: true, headers: { get: () => '1000' } }) }));
    images._sizesMax = 5;
    await images.preflight(Array.from({ length: 12 }, (_, i) => movie(`m${i}`, `p${i}`, `t${i}`)), 'poster');
    assert.equal(Object.keys(store[images._sizesKey]).length, 5, 'Only the most recent sizes are persisted');

    // No fetch at all (older context): nothing happens, nothing throws.
    ({ images } = load({ fetchImpl: undefined }));
    await images.preflight([movie('n', 'n-p', 'n-t')], 'poster');
    console.log('image-preflight: heavy-art swap, memory, failure, timeout, placeholder and bound passed');
})().catch(e => { console.error(e); process.exitCode = 1; });
