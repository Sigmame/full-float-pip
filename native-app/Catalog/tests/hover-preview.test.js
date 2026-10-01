const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, '../catalog.js'), 'utf8');
const start = source.indexOf('function placePreview');
const end = source.indexOf('function previewDetail');
assert(start >= 0 && end > start, 'placePreview must exist in catalog.js');
const context = vm.createContext({});
vm.runInContext(source.slice(start, end) + '\nthis.place = placePreview;', context);
const view = { width: 1280, height: 800 };
const card = (left, top, width = 218, height = 215) => ({ left, top, width, height });

// Wider than the card, centred on it.
let spot = context.place(card(400, 300), view, 340);
assert.equal(spot.width, 300, 'a 218px card opens a 300px preview (min width)');
assert.equal(spot.left, Math.round(400 + 109 - 150), 'centred horizontally on the card');
assert.equal(spot.top, 276, 'starts slightly above the card so the art covers it');

// Big cards (grid, poster mode) get a proportional preview, capped.
assert.equal(context.place(card(400, 300, 260), view, 340).width, 351, '1.35x for a 260px card');
assert.equal(context.place(card(400, 300, 500), view, 340).width, 360, 'capped at 360px');

// Kept inside the window.
assert.equal(context.place(card(0, 300), view, 340).left, 12, 'left edge keeps a 12px margin');
spot = context.place(card(1200, 300), view, 340);
assert.equal(spot.left + spot.width, 1280 - 12, 'right edge keeps a 12px margin');
assert.equal(context.place(card(400, 100), view, 340, 70).top, 76, 'near the top it still clears the header');
assert.equal(context.place(card(400, 0), view, 340, 70).top, 70, 'never under the sticky header');
assert.equal(context.place(card(400, 700), view, 340).top, 800 - 340 - 12, 'near the bottom it moves up to fit');
assert.equal(context.place(card(400, 700), view, 900, 70).top, 70, 'taller than the window: top wins over bottom');
console.log('hover-preview: width rule, centring, window margins and header clearance passed');
