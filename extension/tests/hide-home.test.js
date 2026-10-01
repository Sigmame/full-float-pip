const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, '../catalog.js'), 'utf8');
const start = source.indexOf('function dropHiddenFromHome');
const end = source.indexOf('\n}\n', start) + 3;
assert(start >= 0 && end > start, 'dropHiddenFromHome must exist in catalog.js');
const context = vm.createContext({});
vm.runInContext(source.slice(start, end) + '\nthis.drop = dropHiddenFromHome;', context);

const movie = (slug, rank) => ({ slug, name: slug, ...(rank ? { rank } : {}) });
const data = {
    spotlight: movie('a'),
    spotlights: [movie('a'), movie('b'), movie('c')],
    sections: [
        { id: 'top10', isTop10: true, items: [movie('a', 1), movie('b', 2), movie('c', 3), movie('d', 4)] },
        { id: 'only-a', items: [movie('a')] },
        { id: 'rest', items: [movie('e'), movie('b'), movie('f')] }
    ]
};
const before = JSON.stringify(data);
const slugs = list => [...list.map(m => m.slug)];

assert.equal(context.drop(data, new Set()), data, 'nothing hidden: the same object comes back');
assert.equal(context.drop(data, undefined), data);
assert.equal(context.drop(null, new Set(['a'])), null);

const result = context.drop(data, new Set(['a', 'b']));
assert.deepEqual(slugs(result.spotlights), ['c'], 'hidden movies leave the billboard');
assert.equal(result.spotlight.slug, 'c', 'the first billboard is the first one left');
assert.deepEqual([...result.sections.map(s => s.id)], ['top10', 'rest'], 'a row left empty disappears');
assert.deepEqual(slugs(result.sections[0].items), ['c', 'd']);
assert.deepEqual([...result.sections[0].items.map(m => m.rank)], [1, 2], 'the Top 10 is numbered again without gaps');
assert.deepEqual(slugs(result.sections[1].items), ['e', 'f'], 'ordinary rows just lose the movie');
assert.equal(result.sections[1].items[0].rank, undefined, 'ordinary rows get no rank');
assert.equal(JSON.stringify(data), before, 'the input (possibly cached data) is never changed');

const none = context.drop(data, new Set(['a', 'b', 'c', 'd', 'e', 'f']));
assert.equal(none.sections.length, 0, 'no rows left');
assert.equal(none.spotlight, null, 'no billboard when every spotlight is hidden');
assert.deepEqual(context.drop({ sections: [{ id: 'x', items: [movie('a')] }] }, new Set(['z'])).sections[0].items.length, 1);
console.log('hide-home: billboard, empty rows, Top 10 renumbering and immutability passed');
