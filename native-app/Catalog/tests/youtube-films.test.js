const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');

const policy = require('../site-access.js');
const context = vm.createContext({
    VibeSiteAccess: policy, console: { log() {}, warn() {}, error() {} }, URL, Date, setTimeout, clearTimeout,
    chrome: { storage: { local: { async get() { return {}; }, async set() {} } } }
});
vm.runInContext(fs.readFileSync(path.join(__dirname, '../movie-service.js'), 'utf8') + '\nthis.service = MovieService;', context);
const service = context.service;

// Every curated film becomes a float request that can only be the embed of that exact film.
for (const movie of service.getYouTubeMovies()) {
    assert.equal(policy.allowsPage(movie.url), false, 'never grant inspection of YouTube pages');
    assert.equal(policy.allowsPlayback(movie.url), true);
    const payload = service.buildYouTubeMovieFloatInfo(movie);
    assert.equal(policy.youtubeMovieID(payload.embedUrl), movie.id);
    assert.equal(payload.preferEmbed, true);
    assert.equal(payload.focusSession, false);
    assert.equal(payload.aiDubEnabled, false);
    assert.match(movie.thumb, /^https:\/\/i\.ytimg\.com\/vi\/[A-Za-z0-9_-]{11}\//);
}

// Filters and search.
const hongKong = service.getYouTubeMovies('', 'hongkong');
assert.ok(hongKong.length >= 5, 'offer a useful Hong Kong cast selection');
assert.ok(hongKong.every(movie => movie.hongKongCast));
assert.equal(service.getYouTubeMovies('ngo tran vu')[0].id, '4bjvj11fdV4', 'search Vietnamese cast without accents');
assert.equal(service.getYouTubeMovies('目中无人2')[0].id, 'Z40GTe-gsNo', 'search original titles');
assert.ok(service.getYouTubeMovies('', 'vietnamese').every(movie => movie.audio.includes('Việt')));
assert.equal(service.getYouTubeMovies('khong-co-phim-nay').length, 0);
assert.equal(service.getYouTubeMovies('').length, policy.youtubeMovies.length, 'no keyword and no filter lists everything');

// Retired or unlisted videos cannot come back through stored links or crafted requests.
for (const id of ['kf-zU-Y1vLc', '30iZ-gLFU3A', '12YtcfVWdY4']) {
    assert.equal(policy.allowsPlayback(`https://www.youtube.com/watch?v=${id}`), false, 'retired movies stay out');
    assert.throws(() => service.buildYouTubeMovieFloatInfo({ id }));
}
for (const url of ['https://www.youtube.com/watch?v=rFZHOHl-L8A', 'https://evil.com/watch?v=erso59uFW-0',
    'https://www.youtube.com/embed/erso59uFW-0/other', 'https://www.youtube.com/results?search_query=phim', 'https://www.youtube.com/@channel']) {
    assert.equal(policy.allowsPlayback(url), false, url);
}
assert.throws(() => service.buildYouTubeMovieFloatInfo({ id: 'rFZHOHl-L8A' }));
assert.throws(() => service.buildYouTubeMovieFloatInfo(null));
console.log('youtube-films: float requests, filters, search and retired / unlisted videos passed');
