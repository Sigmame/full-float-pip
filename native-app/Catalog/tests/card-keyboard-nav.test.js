const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, '../catalog.js'), 'utf8');
const start = source.indexOf('function pickNeighbourCard');
const end = source.indexOf('function installCardKeyboardNav');
assert(start >= 0 && end > start, 'pickNeighbourCard and ensureRovingTab must exist in catalog.js');
const context = vm.createContext({});
vm.runInContext(source.slice(start, end) + '\nthis.pick = pickNeighbourCard; this.rove = ensureRovingTab;', context);

// A fake card at a position, inside a fake row container.
const card = (name, parent, left, top, width = 200, height = 120) => ({
    name, parentElement: parent,
    getBoundingClientRect: () => ({ left, top, width, height, right: left + width, bottom: top + height })
});
const names = x => (x ? x.name : null);

// Two rails: rail A has 4 cards (a3, a4 scrolled off to the right), rail B has 3, rail C one.
const A = { id: 'A' }, B = { id: 'B' }, C = { id: 'C' };
const a1 = card('a1', A, 0, 0), a2 = card('a2', A, 210, 0), a3 = card('a3', A, 420, 0), a4 = card('a4', A, 1500, 0);
const b1 = card('b1', B, 0, 200), b2 = card('b2', B, 210, 200), b3 = card('b3', B, 420, 200);
const c1 = card('c1', C, 100, 400);
const all = [a1, a2, a3, a4, b1, b2, b3, c1];
const pick = (current, key) => names(context.pick(current, key, all));

// Left / right stay inside the rail and stop at its ends.
assert.equal(pick(a1, 'ArrowRight'), 'a2');
assert.equal(pick(a3, 'ArrowRight'), 'a4');
assert.equal(pick(a4, 'ArrowRight'), null, 'no wrap past the last card');
assert.equal(pick(a1, 'ArrowLeft'), null, 'no wrap before the first card');
assert.equal(pick(b2, 'ArrowLeft'), 'b1');
assert.equal(pick(a2, 'Home'), 'a1');
assert.equal(pick(a1, 'Home'), null);
assert.equal(pick(a1, 'End'), 'a4');
assert.equal(pick(a4, 'End'), null);

// Up / down jump to the nearest row and the card closest in horizontal position.
assert.equal(pick(a1, 'ArrowDown'), 'b1');
assert.equal(pick(a2, 'ArrowDown'), 'b2');
assert.equal(pick(a3, 'ArrowDown'), 'b3');
assert.equal(pick(b3, 'ArrowUp'), 'a3');
assert.equal(pick(a4, 'ArrowDown'), 'b3', 'a card scrolled far right lands on the closest card below');
assert.equal(pick(b2, 'ArrowDown'), 'c1', 'the nearest row below, even when it has one card');
assert.equal(pick(c1, 'ArrowUp'), 'b1', 'closest to x=100 in the row above (b1 at 0..200 or b2 at 210..410)');
assert.equal(pick(a1, 'ArrowUp'), null, 'nothing above the first row');
assert.equal(pick(c1, 'ArrowDown'), null, 'nothing below the last row');

// A grid is one container read left to right; down finds the card below, not the next in order.
const G = { id: 'G' };
const g = [0, 1, 2, 3, 4, 5].map(i => card(`g${i}`, G, (i % 3) * 210, Math.floor(i / 3) * 300));
const grid = key => from => names(context.pick(g[from], key, g));
assert.equal(grid('ArrowRight')(2), 'g3', 'right at the end of a row continues on the next row');
assert.equal(grid('ArrowLeft')(3), 'g2');
assert.equal(grid('ArrowDown')(1), 'g4');
assert.equal(grid('ArrowUp')(5), 'g2');
assert.equal(grid('ArrowDown')(4), null);

// Cards that are almost level (sub-pixel layout differences) count as one row.
const H = { id: 'H' };
const level = [card('l1', H, 0, 500.0), card('l2', H, 210, 500.4), card('l3', H, 420, 499.7)];
const below = card('m1', { id: 'M' }, 215, 700);
assert.equal(names(context.pick(below, 'ArrowUp', [...level, below])), 'l2', 'picks by horizontal position inside the nearest row');

// Roving tab stop: one card per rail or grid has tabindex 0.
function el(attrs = {}) {
    const a = { ...attrs };
    return { getAttribute: k => a[k] ?? null, setAttribute: (k, v) => { a[k] = v; }, a };
}
function group(cardCount, tabStop) {
    const cards = Array.from({ length: cardCount }, (_, i) => el({ tabindex: i === tabStop ? '0' : '-1' }));
    return { cards, matches: () => true, querySelectorAll: () => cards };
}
let rail = group(4, -1);
context.rove(rail);
assert.deepEqual(rail.cards.map(c => c.a.tabindex), ['0', '-1', '-1', '-1'], 'the first card is the stop by default');
rail = group(4, 2);
context.rove(rail);
assert.deepEqual(rail.cards.map(c => c.a.tabindex), ['-1', '-1', '0', '-1'], 'an existing stop is kept when more cards are added');
rail = group(3, 1);
rail.cards[0].a.tabindex = '0';
context.rove(rail);
assert.equal(rail.cards.filter(c => c.a.tabindex === '0').length, 1, 'never more than one stop');
context.rove(null);
context.rove(group(0, 0));
console.log('card-keyboard-nav: rows, grid reading order, vertical jumps, ends, rows within rounding and roving tab stop passed');
