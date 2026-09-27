// The catalogue grid is a feed now: it loads page 1 and keeps appending while
// the reader scrolls, instead of showing page buttons. That behaviour lives in
// catalog.js, which is a plain script with globals, so this runs it in a `vm`
// with the few DOM nodes it touches and drives the feed directly.
//
//   node extension/tests/catalog-feed.test.js
//
// It covers the parts that are easy to get wrong and hard to see by scrolling:
// deduplicating overlapping pages, dropping a response for a view the user has
// already left, stopping when the source runs out, and stopping after two pages
// that the audio pill filtered away.

const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert');

const root = path.join(__dirname, '..');

// --- minimal DOM ------------------------------------------------------------

function makeElement(id) {
  const el = {
    id,
    textContent: '',
    className: '',
    dataset: {},
    children: [],
    firstChild: null,
    style: {},
    // The grid opens with `.skeleton-card` covers. They are markup in the real
    // page, so here the assignment models the nodes it creates — removing them
    // is the behaviour under test.
    placeholders: [],
    extra: {},
    classList: {
      _set: new Set(),
      add(...c) { c.forEach(x => this._set.add(x)); },
      remove(...c) { c.forEach(x => this._set.delete(x)); },
      contains(c) { return this._set.has(c); },
      toggle(c, force) {
        const on = force === undefined ? !this._set.has(c) : force;
        if (on) this._set.add(c); else this._set.delete(c);
        return on;
      }
    },
    appendChild(node) { this.children.push(node); return node; },
    querySelectorAll(selector) {
      if (selector === '.skeleton-card') return el.placeholders;
      return el.extra[selector] || [];
    },
    querySelector() { return null; },
    getBoundingClientRect() { return { top: 0, left: 0, width: 100, height: 1 }; },
    scrollIntoView() {},
    addEventListener() {},
    closest() { return null; }
  };
  let html = '';
  Object.defineProperty(el, 'innerHTML', {
    get() { return html; },
    set(value) {
      html = String(value);
      el.children = [];
      el.placeholders = [];
      el.extra = {};
      const cover = /class="skeleton-card"/g;
      while (cover.exec(html)) {
        el.placeholders.push({ removed: false, remove() { this.removed = true; } });
      }
    }
  });
  return el;
}

const ids = ['movie-grid', 'section-title', 'result-count', 'feed-footer', 'feed-status',
  'feed-end', 'feed-retry-btn', 'feed-sentinel', 'catalog-audit'];
const elements = {};
ids.forEach(id => { elements[id] = makeElement(id); });

const document = {
  addEventListener() {},
  createElement() { return makeElement('stage'); },
  createDocumentFragment() { return { children: [], appendChild(n) { this.children.push(n); } }; },
  getElementById(id) { return elements[id] || null; },
  querySelector() { return null; },
  querySelectorAll() { return []; }
};

const window = { addEventListener() {}, scrollY: 0 };

// The catalogue audits itself after each load and reports leftovers through the
// console; capture those warnings so the test can assert on them.
const warnings = [];
const sandboxConsole = {
  log() {},
  error() {},
  warn(...args) { warnings.push(args.map(String).join(' ')); }
};

const sandbox = {
  document,
  window,
  console: sandboxConsole,
  setTimeout,
  clearTimeout,
  Promise,
  Date,
  Set,
  Math,
  CSS: { escape: (s) => s },
  MovieImages: { attr: () => '', apply() {}, install() {}, pick: () => ({ src: '', alt: '' }) },
  chrome: { runtime: { sendMessage: () => Promise.resolve({}), onMessage: { addListener() {} } }, storage: { local: { get: (k, cb) => cb({}), set: (o, cb) => cb && cb() } } },
  IntersectionObserver: class { observe() {} disconnect() {} }
};

// A catalogue whose pages the test controls.
const pages = {};
const movieService = {
  SOURCES: [{ id: 'all', name: 'Đa nguồn' }, { id: 'thuyetminh', name: 'Kho Thuyết Minh' }],
  GENRES: [{ id: 'hanh-dong', name: 'Hành động' }],
  COUNTRIES: [{ id: 'han-viet', name: 'Hàn Việt' }],
  getFavorites: async () => [],
  search: async () => [],
  getByGenre: async () => [],
  getByCountry: async () => [],
  getLatest: async (source, category, page) => pages[page] || [],
  getFavoriteSlugSet: async () => new Set(),
  toggleFavorite: async () => true,
  addRecentSearch() {}
};
sandbox.MovieService = movieService;

const source = fs.readFileSync(path.join(root, 'catalog.js'), 'utf8')
  + `\n;globalThis.__feed = {
      newFeed, fetchFeedPage, appendToGrid, loadMoreMovies, loadFeedView, setFeedFooter, feedKeyFor,
      auditTransientNodes, leftoverTransientNodes,
      current: () => feed,
      setSource: (s) => { currentSource = s; },
      setCategory: (c) => { currentCategory = c; },
      setFilter: (f) => { currentAudioFilter = f; },
      setKeyword: (k) => { currentSearchKeyword = k; }
    };`;
vm.runInNewContext(source, sandbox, { filename: 'catalog.js' });
const feedApi = sandbox.__feed;

function item(n) {
  return { slug: `phim-${n}`, name: `Phim ${n}`, source: 'kkphim', thumb: 't', poster: 'p', year: '2026' };
}

const results = [];
function check(label, fn) {
  try {
    fn();
    results.push(`  ok   ${label}`);
  } catch (error) {
    results.push(`  FAIL ${label}: ${error.message}`);
    process.exitCode = 1;
  }
}

async function run() {
  console.log('catalogue feed; scroll to load more');

  // 1. Page 1 is not appended twice, and keys match the view on screen.
  Object.keys(pages).forEach(k => delete pages[k]);
  pages[1] = [item(1), item(2), item(3)];
  pages[2] = [item(4), item(5), item(6)];
  feedApi.setSource('all');
  feedApi.setCategory('bo');
  feedApi.setFilter('all');
  feedApi.setKeyword('');
  const feed = feedApi.newFeed();

  await feedApi.loadMoreMovies();
  check('page 1 appends its items', () => {
    assert.strictEqual(feed.count, 3);
    assert.strictEqual(feed.page, 1);
    assert.strictEqual(feed.done, false);
  });

  // 2. A page that repeats what is already on screen adds nothing but still
  //    advances, and two such pages end the feed.
  pages[2] = [item(1), item(2)];
  pages[3] = [item(2), item(3)];
  await feedApi.loadMoreMovies();
  await feedApi.loadMoreMovies();
  check('overlapping pages are deduplicated', () => {
    assert.strictEqual(feed.count, 3, 'no card may appear twice');
    assert.strictEqual(feed.page, 3);
  });
  check('two pages that add nothing end the feed', () => {
    assert.strictEqual(feed.done, true);
    assert.strictEqual(elements['feed-footer'].dataset.state, 'end');
  });

  // 3. A response for a view the reader has left must not be appended. The
  //    feed object is replaced on every view change, so identity is the guard.
  const stale = feedApi.current();
  pages[1] = [item(10), item(11)];
  await feedApi.loadMoreMovies();
  check('a finished feed does not load again', () => {
    assert.strictEqual(stale.count, 3);
  });

  const feed2 = feedApi.newFeed();
  pages[1] = [item(20), item(21)];
  const inFlight = feedApi.loadMoreMovies();
  feedApi.newFeed(); // the user switched view while the request was in flight
  await inFlight;
  check('a response for the previous view is dropped', () => {
    assert.strictEqual(feed2.count, 0, 'the old feed must not grow');
    assert.strictEqual(feedApi.current().count, 0);
  });

  // 4. An empty page ends the feed: that is how "out of titles" is detected
  //    without the API publishing totals.
  const feed3 = feedApi.newFeed();
  pages[1] = [];
  await feedApi.loadMoreMovies();
  check('an empty page ends the feed', () => {
    assert.strictEqual(feed3.done, true);
    assert.strictEqual(elements['feed-footer'].dataset.state, 'end');
  });

  // 5. The audio pill can filter a whole page away; two of those in a row end
  //    the feed rather than fetching for ever.
  // The filter is part of the feed key, so it is set before the feed exists:
  // changing it afterwards is what the view-change guard is for.
  feedApi.setFilter('thuyetminh');
  const feed4 = feedApi.newFeed();
  pages[1] = [{ ...item(30), hasThuyetMinh: false }];
  pages[2] = [{ ...item(31), hasThuyetMinh: false }];
  await feedApi.loadMoreMovies();
  await feedApi.loadMoreMovies();
  check('two pages filtered away end the feed', () => {
    assert.strictEqual(feed4.count, 0);
    assert.strictEqual(feed4.done, true);
  });

  // 6. A dubbed item survives the same filter.
  const feed5 = feedApi.newFeed();
  pages[1] = [{ ...item(40), hasThuyetMinh: true }];
  await feedApi.loadMoreMovies();
  check('a dubbed item survives the dubbed filter', () => {
    assert.strictEqual(feed5.count, 1);
  });

  // 7. Search answers a single page, so the feed stops after it.
  feedApi.setFilter('all');
  feedApi.setKeyword('phù sa');
  const feed6 = feedApi.newFeed();
  await feedApi.loadMoreMovies();
  check('search is a one-page feed', () => {
    assert.strictEqual(feed6.mode, 'search');
    assert.strictEqual(feed6.done, true);
  });

  // 8. The grid's loading covers are not part of the list. Appending next to
  //    them was the bug: twelve blank poster boxes stayed above the cards.
  feedApi.setFilter('all');
  feedApi.setKeyword('');
  feedApi.setCategory('bo');
  pages[1] = [item(50), item(51)];
  const grid = elements['movie-grid'];
  await feedApi.loadFeedView();
  check('the first page takes the loading covers away', () => {
    assert.ok(grid.placeholders.length > 0, 'the grid did open with covers');
    assert.strictEqual(grid.placeholders.filter(p => !p.removed).length, 0,
      'no cover may stay on screen once cards are there');
    assert.strictEqual(feedApi.current().count, 2);
  });

  // 9. A list with no cards at all says so instead of leaving the covers up.
  pages[1] = [];
  await feedApi.loadFeedView();
  check('an empty list swaps its covers for a message', () => {
    assert.strictEqual(grid.placeholders.filter(p => !p.removed).length, 0, 'no cover stays');
    assert.ok(grid.innerHTML.includes('feed-empty'), 'the grid says why it is empty');
  });

  // 10. The filter is named, because that is what usually emptied the list.
  feedApi.setFilter('thuyetminh');
  pages[1] = [{ ...item(60), hasThuyetMinh: false }];
  pages[2] = [{ ...item(61), hasThuyetMinh: false }];
  await feedApi.loadFeedView();
  check('an empty dubbed list names the filter', () => {
    assert.ok(grid.innerHTML.includes('thuyết minh'), grid.innerHTML);
  });

  // 11. A healthy load leaves nothing transient behind, and says nothing.
  feedApi.setFilter('all');
  feedApi.setKeyword('');
  feedApi.setCategory('bo');
  warnings.length = 0;
  pages[1] = [item(70)];
  await feedApi.loadFeedView();
  check('a clean load reports no leftovers', () => {
    const noisy = warnings.filter(w => w.includes('leftover'));
    assert.deepStrictEqual(noisy, [], `unexpected leftover warnings: ${noisy.join(' | ')}`);
  });

  // 12. A cover the load fails to take away is not silently left on screen:
  //     the self-check names it in the console. Re-breaking clearLoadingCovers
  //     (a cover whose removal does nothing) is how the original bug felt.
  warnings.length = 0;
  grid.innerHTML = '<div class="skeleton-card"></div>';
  grid.placeholders.forEach(p => { p.remove = function () {}; });
  pages[1] = [item(80)];
  const feed7 = feedApi.newFeed();
  await feedApi.loadMoreMovies();
  check('a cover that survives the load is reported', () => {
    assert.strictEqual(feed7.count, 1, 'the page still loads its card');
    assert.ok(
      warnings.some(w => w.includes('leftover') && w.includes('skeleton-card')),
      `expected a leftover warning, got: ${JSON.stringify(warnings)}`
    );
  });

  // 13. The same self-check covers the home page's section skeletons, and
  //     returns the issues it found so a caller can act on them.
  grid.placeholders = [];
  warnings.length = 0;
  grid.extra['.home-section-skeleton'] = [{ removed: false, closest: () => null }];
  const issues = feedApi.auditTransientNodes(grid, 'loading the home sections', true);
  check('a leftover home skeleton is reported', () => {
    assert.strictEqual(issues.length, 1, `expected one issue, got ${JSON.stringify(issues)}`);
    assert.strictEqual(issues[0].what, 'home section skeleton');
    assert.ok(warnings.some(w => w.includes('home section skeleton')));
  });
  grid.extra = {};

  // 14. The banner is a debug aid, so it stays off unless switched on.
  const banner = elements['catalog-audit'];
  grid.placeholders = [{ removed: false, closest: () => null }];
  window.CATALOG_AUDIT_DEBUG = false;
  feedApi.auditTransientNodes(grid, 'debug off', true);
  check('with the debug flag off the banner stays hidden', () => {
    assert.ok(banner.classList.contains('hidden'), 'the banner must not show by itself');
  });

  // 15. Switched on, the same leftover is shown on the page, not only logged.
  window.CATALOG_AUDIT_DEBUG = true;
  feedApi.auditTransientNodes(grid, 'debug on', true);
  check('with debug on the banner names the leftover', () => {
    assert.ok(!banner.classList.contains('hidden'), 'the banner must show');
    assert.ok(banner.innerHTML.includes('skeleton-card'), banner.innerHTML);
    assert.ok(banner.innerHTML.includes('Node tạm'), banner.innerHTML);
  });
  window.CATALOG_AUDIT_DEBUG = false;
  grid.placeholders = [];

  console.log(results.join('\n'));
  console.log(process.exitCode ? 'catalogue feed: checks failed' : 'catalogue feed scenarios passed');
}

run().catch(err => {
  console.error('catalogue feed test crashed:', err);
  process.exit(1);
});
