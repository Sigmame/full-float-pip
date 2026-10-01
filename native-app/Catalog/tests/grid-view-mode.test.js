const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, '../catalog.js'), 'utf8');
const start = source.indexOf("const VIEW_MODE_STORAGE_KEY");
const end = source.indexOf('\n}\n', source.indexOf('function applyViewMode')) + 3;
assert(start >= 0 && end > start, 'applyViewMode must exist in catalog.js');

function el() {
    const classes = new Set(); const attrs = {};
    return { classes, attrs,
        classList: { toggle(c, on) { on ? classes.add(c) : classes.delete(c); }, add: c => classes.add(c), remove: c => classes.delete(c) },
        setAttribute(k, v) { attrs[k] = v; } };
}
function card(slug, sourceId) {
    const img = { kind: null };
    return { img, dataset: { slug, source: sourceId }, querySelector: () => img };
}

const grid = Object.assign(el(), { cards: [], querySelectorAll() { return this.cards; } });
const nodes = { 'movie-grid': grid, 'view-grid-btn': el(), 'view-cinema-btn': el() };
const stored = {};
const applied = [];
const context = vm.createContext({
    document: { getElementById: id => nodes[id] },
    localStorage: { setItem: (k, v) => { stored[k] = v; }, getItem: k => stored[k] },
    MovieImages: { apply(img, item, kind) { applied.push({ slug: item.slug, kind }); img.kind = kind; } },
    currentViewMode: 'view-poster', feed: null
});
vm.runInContext(source.slice(start, end) + '\nthis.applyViewMode = applyViewMode; this.setFeed = f => { feed = f; }; this.mode = () => currentViewMode;', context);

// Two loaded cards, remembered by source:slug.
grid.cards = [card('a', 'kkphim'), card('b', 'nguonc')];
context.setFeed({ items: new Map([['kkphim:a', { slug: 'a' }], ['nguonc:b', { slug: 'b' }]]) });

context.applyViewMode('view-cinema');
assert.equal(context.mode(), 'view-cinema');
assert(grid.classes.has('view-cinema') && !grid.classes.has('view-poster'));
assert.equal(nodes['view-cinema-btn'].attrs['aria-pressed'], 'true');
assert.equal(nodes['view-grid-btn'].attrs['aria-pressed'], 'false');
assert.deepEqual(applied, [{ slug: 'a', kind: 'wide' }, { slug: 'b', kind: 'wide' }], 'Loaded cards switch to wide artwork without refetching');
assert.equal(stored.vibe_catalog_view_mode, 'view-cinema', 'The choice is remembered');

context.applyViewMode('view-poster');
assert(grid.classes.has('view-poster') && !grid.classes.has('view-cinema'));
assert.equal(grid.cards[0].img.kind, 'poster');

// Restoring a saved choice at startup must not write it back or need a feed.
stored.vibe_catalog_view_mode = 'unchanged';
context.setFeed(null);
context.applyViewMode('view-cinema', { persist: false });
assert.equal(stored.vibe_catalog_view_mode, 'unchanged');
assert.equal(context.mode(), 'view-cinema');
console.log('grid-view-mode: no refetch, artwork swap, aria-pressed, persistence and startup restore passed');
